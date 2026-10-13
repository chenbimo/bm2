///|
/// The periodic side of notifications: threshold conditions and report
/// schedules, evaluated once a minute from `Supervisor::tick`. Both gates live
/// here, so the "every periodic check carries its own gate" rule is visible in
/// one place. Everything here only composes and publishes messages; delivery
/// belongs to the notify task.

///|
/// How often thresholds and report schedules are evaluated. Cheap enough to run
/// on a timer rather than on every tick.
const NOTIFY_CHECK_INTERVAL_MS : UInt64 = 60000UL

///|
/// Threshold alerts and the periodic report, evaluated once a minute per
/// project. Each condition is deduplicated by the engine, so something that
/// persists alerts once per dedupe window instead of on every pass.
pub fn Supervisor::check_notify(self : Supervisor, now_mono : UInt64) -> Unit {
  if now_mono >= self.last_notify_check_ms &&
    now_mono - self.last_notify_check_ms < NOTIFY_CHECK_INTERVAL_MS {
    return
  }
  self.last_notify_check_ms = now_mono
  for app_name in self.app_names() {
    let policy = self.project_policy(app_name)
    match self.instances.get(app_name) {
      Some(arr) =>
        for inst in arr {
          let key = app_name + "/" + inst.instance_id.to_string()
          if policy.threshold_restarts > 0 &&
            inst.restart_count >= policy.threshold_restarts {
            let (title, body) = render_msg(
              policy.lang,
              ThresholdRestarts(inst.restart_count, policy.threshold_restarts),
            )
            self.notify_instance(inst, "threshold", "warn", title, body)
          }
          if policy.start_timeout_ms > 0 && inst.status is Online {
            let probe_key = app_name + "/" + inst.instance_id.to_string()
            let probed = match self.start_probe_done.get(probe_key) {
              Some(generation) => generation
              None => 0UL
            }
            if probed != inst.started_mono_ms &&
              now_mono >=
              inst.started_mono_ms + policy.start_timeout_ms.to_uint64() {
              let rc = @proc.probe_reuseport(inst.port)
              if rc == 0 {
                self.start_probe_done[probe_key] = inst.started_mono_ms
                let (title, body) = render_msg(
                  policy.lang,
                  StartTimeout(inst.port, policy.start_timeout_ms),
                )
                self.notify_instance(inst, "start_timeout", "warn", title, body)
              } else if rc > 0 {
                // Listening (shared or exclusive) — settled for this spawn.
                self.start_probe_done[probe_key] = inst.started_mono_ms
              }
              // rc < 0: probe itself failed; retry on the next pass.
            }
          }
          if inst.status is Online || inst.status is Stopped {
            self.notify.forget_offline(key)
          } else if policy.threshold_offline_min > 0 {
            let since = self.notify.offline_since(key, now_mono)
            let limit = (policy.threshold_offline_min * 60000).to_uint64()
            if now_mono >= since && now_mono - since >= limit {
              let (title, body) = render_msg(
                policy.lang,
                ThresholdOffline(
                  inst.status.as_string(),
                  policy.threshold_offline_min,
                ),
              )
              self.notify_instance(inst, "threshold", "warn", title, body)
            }
          }
        }
      None => ()
    }
    if policy.enabled && policy.threshold_disk_mb > 0 {
      match @proc.disk_free_kb(self.state_dir) {
        Some(kb) =>
          if kb < (policy.threshold_disk_mb * 1024).to_int64() {
            let (title, body) = render_msg(
              policy.lang,
              DiskPressure(policy.threshold_disk_mb, (kb / 1048576).to_int()),
            )
            self.notify_project(
              app_name,
              "disk_pressure",
              "warn",
              title,
              body,
              "disk_pressure|" + app_name,
            )
          }
        None => ()
      }
    }
    if policy.enabled && policy.threshold_storm > 0 {
      let hits = match self.storm_hits.get(app_name) {
        Some(hits) => hits
        None => []
      }
      let count = storm_hit_count(hits, now_mono, STORM_WINDOW_MS)
      if count >= policy.threshold_storm {
        let (title, body) = render_msg(
          policy.lang,
          RestartStorm(count, policy.threshold_storm),
        )
        self.notify_project(
          app_name,
          "threshold",
          "warn",
          title,
          body,
          "storm|" + app_name,
        )
      }
    }
  }
}

///|
/// Periodic reports: every `[[notify.report]]` with a `cron` gets its content
/// rendered on its own schedule and published to the notify task, which
/// delivers it straight through — no event queue, no dedupe, no rate limit.
/// Rendering happens here because supervised state lives here; delivery is the
/// notify task's job. Nothing in this function waits on the network.
pub fn Supervisor::check_schedules(
  self : Supervisor,
  now_mono : UInt64,
  now_wall : UInt64,
) -> Unit {
  // Cron granularity is minutes; evaluate once per minute, not on every
  // 50 ms tick — otherwise a matching minute fires once per tick. The gate is
  // a duration (monotonic), the cron fields are local wall-clock time.
  if now_mono >= self.last_schedule_check_ms &&
    now_mono - self.last_schedule_check_ms < NOTIFY_CHECK_INTERVAL_MS {
    return
  }
  self.last_schedule_check_ms = now_mono
  for app_name in self.app_names() {
    let policy = self.project_policy(app_name)
    if !policy.enabled {
      continue
    }
    for report in policy.reports {
      let cron = match report.cron {
        Some(cron) => cron
        None => continue
      }
      let parts = match @proc.local_parts(now_wall) {
        Some(parts) => parts
        None => continue
      }
      if !cron_matches(cron, parts) {
        continue
      }
      let stats = report.template == Some("stats")
      let message = self.build_report(app_name, policy, now_mono, stats~)
      self.notify.publish_schedule(app_name, policy, report.targets, message)
    }
  }
}

///|
/// Cron match against local-time parts: (year, month, day, weekday, hour,
/// minute). Every restricted field must contain the current value; the
/// parser guarantees day-of-month and day-of-week are not both restricted.
fn cron_matches(
  spec : @config.CronSpec,
  parts : (Int32, Int32, Int32, Int32, Int32, Int32),
) -> Bool {
  let (_, month, day, weekday, hour, minute) = parts
  spec.minutes.contains(minute) &&
  spec.hours.contains(hour) &&
  spec.days_of_month.contains(day) &&
  spec.months.contains(month) &&
  spec.days_of_week.contains(weekday)
}

///|
/// Memory approaching the limit is worth knowing before the kill: the sampling
/// already happened in check_memory, so this costs nothing extra.
pub fn Supervisor::notify_memory_pressure(
  self : Supervisor,
  inst : Instance,
  rss_kb : Int32,
) -> Unit {
  let policy = self.project_policy(inst.app_name)
  if policy.threshold_rss_percent <= 0 {
    return
  }
  let limit_kb = match self.config_of(inst.app_name) {
    Some(app) => app.max_memory_mb.to_int64() * 1024L
    None => 0L
  }
  if limit_kb > 0L &&
    rss_kb.to_int64() * 100L >=
    limit_kb * policy.threshold_rss_percent.to_int64() {
    let (title, body) = render_msg(
      policy.lang,
      ThresholdMemory(
        rss_kb / 1024,
        policy.threshold_rss_percent,
        (limit_kb / 1024L).to_int(),
      ),
    )
    self.notify_instance(inst, "threshold", "warn", title, body)
  }
}
