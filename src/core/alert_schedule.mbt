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
    match self.instances_of(app_name) {
      Some(arr) =>
        for inst in arr {
          let key = inst.key()
          if policy.threshold_restarts > 0 &&
            inst.restart_count >= policy.threshold_restarts {
            let (title, body) = render_msg(
              policy.lang,
              ThresholdRestarts(inst.restart_count, policy.threshold_restarts),
            )
            self.notify_instance(inst, "threshold", "warn", title, body)
          }
          if policy.start_timeout_ms > 0 && inst.status is Online {
            let probed = self.probed_generation(app_name, inst.instance_id)
            if probed != inst.started_mono_ms &&
              now_mono >=
              inst.started_mono_ms + policy.start_timeout_ms.to_uint64() {
              let rc = @proc.probe_reuseport(inst.port)
              if rc == 0 {
                self.note_probed(
                  app_name,
                  inst.instance_id,
                  inst.started_mono_ms,
                )
                let (title, body) = render_msg(
                  policy.lang,
                  StartTimeout(inst.port, policy.start_timeout_ms),
                )
                self.notify_instance(inst, "start_timeout", "warn", title, body)
              } else if rc > 0 {
                // Listening (shared or exclusive) — settled for this spawn.
                self.note_probed(
                  app_name,
                  inst.instance_id,
                  inst.started_mono_ms,
                )
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
      let hits = match self.projects.get(app_name) {
        Some(project) => project.storm_hits
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
/// The daily stats report: one render per day, at `daily_report_hour`, published
/// to every target that subscribes to `daily_stats`. Delivery is the notify
/// task's job; nothing here waits on the network.
///
/// 它不再有 cron：只有"每天整点"这一种周期，多一个 cron 解析器就多一套需要
/// 解释的边界。
pub fn Supervisor::check_schedules(
  self : Supervisor,
  now_mono : UInt64,
  now_wall : UInt64,
) -> Unit {
  // 每分钟评估一次，而不是每个 50ms tick：否则命中的那一分钟里会重复触发。
  if now_mono >= self.last_schedule_check_ms &&
    now_mono - self.last_schedule_check_ms < NOTIFY_CHECK_INTERVAL_MS {
    return
  }
  self.last_schedule_check_ms = now_mono
  let parts = match @proc.local_parts(now_wall) {
    Some(parts) => parts
    None => return
  }
  let (_, _, _, _, hour, minute) = parts
  if minute != 0 {
    return
  }
  for app_name in self.app_names() {
    let policy = self.project_policy(app_name)
    if !policy.enabled {
      continue
    }
    if hour != policy.daily_report_hour {
      continue
    }
    let subscribers = policy.targets.filter(fn(target) {
      target.filter.accepts("daily_stats")
    })
    if subscribers.length() == 0 {
      continue
    }
    let message = self.build_report(app_name, policy, now_mono)
    self.notify.publish_schedule(app_name, policy, subscribers, message)
  }
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
