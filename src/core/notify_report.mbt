///|
/// The bridge between supervision and notifications: it turns supervisor state
/// (instances, configs, sampled metrics) into messages, and decides when a
/// periodic health report or a threshold alert is due. Delivery policy itself
/// lives in the engine, and the policy for each message comes from the project
/// that produced it.

///|
/// How often thresholds and report schedules are evaluated. Cheap enough to run
/// on a timer rather than on every tick.
const NOTIFY_CHECK_INTERVAL_MS : UInt64 = 60000UL

///|
/// How far back restart-storm detection looks.
const STORM_WINDOW_MS : UInt64 = 600000UL

///|
/// The `[notify]` policy of one project. A project that never configured
/// notifications gets the disabled policy, so callers stay unconditional.
fn Supervisor::project_policy(
  self : Supervisor,
  app_name : String,
) -> @config.NotifyConfig {
  match self.apps.get(app_name) {
    Some(app) => app.notify
    None => @config.NotifyConfig::disabled()
  }
}

///|
fn human_duration(ms : UInt64) -> String {
  let seconds = (ms / 1000UL).to_int()
  if seconds < 60 {
    return "\{seconds}s"
  }
  let minutes = seconds / 60
  if minutes < 60 {
    return "\{minutes}m \{seconds % 60}s"
  }
  let hours = minutes / 60
  if hours < 24 {
    return "\{hours}h \{minutes % 60}m"
  }
  "\{hours / 24}d \{hours % 24}h"
}

///|
fn instance_fields(inst : Instance, now : UInt64) -> Array[(String, String)] {
  let fields : Array[(String, String)] = [
    ("app", inst.app_name),
    ("instance", inst.instance_id.to_string()),
    ("mode", inst.exec_mode),
    ("port", inst.port.to_string()),
    ("PID", inst.pid.to_string()),
    ("status", inst.status.as_string()),
    ("starts", inst.times.to_string()),
    ("crashes", inst.restart_count.to_string()),
  ]
  if inst.started_at_ms > 0UL && now > inst.started_at_ms {
    fields.push(("uptime", human_duration(now - inst.started_at_ms)))
  }
  fields
}

///|
fn instance_signature(event : String, inst : Instance) -> String {
  event +
  "|" +
  inst.app_name +
  "|" +
  inst.instance_id.to_string() +
  "|" +
  inst.last_reason.unwrap_or("")
}

///|
/// Report one instance-level event. The caller supplies the wording; policy
/// (subscription, dedupe, rate limit, delivery) is the engine's.
pub fn Supervisor::notify_instance(
  self : Supervisor,
  inst : Instance,
  event : String,
  level : String,
  title : String,
  body : String,
) -> Unit {
  let now = @util.now_ms()
  self.notify.emit(
    self.project_policy(inst.app_name),
    inst.app_name,
    @notify.Message::new(
      event,
      level,
      "\{inst.app_name} · \{title}",
      body,
      instance_signature(event, inst),
      now,
      fields=instance_fields(inst, now),
    ),
  )
}

///|
/// Report something about a whole project (a restart, a stop, a stopped project
/// after a reusePort violation) where no single instance is the subject.
pub fn Supervisor::notify_project(
  self : Supervisor,
  app_name : String,
  event : String,
  level : String,
  title : String,
  body : String,
  signature : String,
) -> Unit {
  let now = @util.now_ms()
  let instances = match self.instances.get(app_name) {
    Some(arr) => arr.length()
    None => 0
  }
  self.notify.emit(
    self.project_policy(app_name),
    app_name,
    @notify.Message::new(
      event,
      level,
      "\{app_name} · \{title}",
      body,
      signature,
      now,
      fields=[
        ("host", self.notify.host),
        ("project", app_name),
        ("instances", instances.to_string()),
      ],
    ),
  )
}

///|
/// Daemon started / reloaded: tell each project's own targets.
pub fn Supervisor::notify_daemon_started(
  self : Supervisor,
  app_name : String,
) -> Unit {
  let policy = self.project_policy(app_name)
  let (title, body) = render_msg(
    policy.lang,
    DaemonAdopted(self.online_count(app_name)),
  )
  self.notify_project(
    app_name,
    "daemon",
    "info",
    title,
    body,
    "daemon_started|" + app_name,
  )
}

///|
/// Online instance count of one project, for the daemon start notice.
pub fn Supervisor::online_count(self : Supervisor, app_name : String) -> Int32 {
  match self.instances.get(app_name) {
    Some(arr) => arr.filter(fn(inst) { inst.status is Online }).length()
    None => 0
  }
}

///|
/// One line per instance: status, memory, cpu, uptime, restarts, port. This is
/// what makes a periodic report worth reading — it shows load per process.
/// `peak` is the RSS high-water mark of the reporting window, shown when the
/// caller asked for it.
fn Supervisor::report_line(
  self : Supervisor,
  inst : Instance,
  now : UInt64,
  lang~ : String = "en",
  peak~ : Int32? = None,
) -> String {
  let zh = lang == "zh"
  // Per-language field labels; the machine keys inside events stay neutral.
  let (lb_port, lb_rss, lb_peak, lb_cpu, lb_uptime, lb_restarts) = if zh {
    ("端口", "内存", "峰值", "CPU", "运行", "重启")
  } else {
    ("port", "RSS", "peak", "CPU", "uptime", "restarts")
  }
  let mut line = inst.app_name +
    "/" +
    inst.instance_id.to_string() +
    " " +
    inst.status.as_string()
  line = line + " · " + lb_port + " " + inst.port.to_string()
  if inst.status is Online {
    match @proc.read_rss_kb(inst.pid) {
      Some(kb) =>
        line = line + " · " + lb_rss + " " + (kb / 1024).to_string() + "MB"
      None => ()
    }
    match peak {
      Some(kb) =>
        line = line + " · " + lb_peak + " " + (kb / 1024).to_string() + "MB"
      None => ()
    }
    match
      self.notify.cpu_percent(
        inst.app_name + "/" + inst.instance_id.to_string(),
        inst.pid,
        now,
      ) {
      Some(percent) =>
        line = line + " · " + lb_cpu + " " + format_percent(percent) + "%"
      None => ()
    }
    if inst.started_at_ms > 0UL && now > inst.started_at_ms {
      line = line +
        " · " +
        lb_uptime +
        " " +
        human_duration(now - inst.started_at_ms)
    }
  } else if inst.last_reason is Some(reason) {
    line = line + " · " + reason
  }
  if inst.restart_count > 0 {
    match self.apps.get(inst.app_name) {
      Some(app) =>
        line = line +
          " · " +
          lb_restarts +
          " " +
          inst.restart_count.to_string() +
          "/" +
          app.max_restarts.to_string()
      None => ()
    }
  }
  line
}

///|
fn format_percent(percent : Double) -> String {
  let scaled = (percent * 10.0 + 0.5).to_int()
  (scaled / 10).to_string() + "." + (scaled % 10).to_string()
}

///|
/// The periodic report for one project: every instance on one line, plus the
/// project's own shape. Reports always carry the full picture.
fn Supervisor::build_report(
  self : Supervisor,
  app_name : String,
  policy : @config.NotifyConfig,
  now : UInt64,
  stats~ : Bool = false,
) -> @notify.Message {
  let lines = []
  let mut online = 0
  let mut other = 0
  match self.instances.get(app_name) {
    Some(arr) =>
      for inst in arr {
        if inst.status is Online {
          online += 1
        } else if !(inst.status is Stopped) {
          other += 1
        }
        let key = inst.app_name + "/" + inst.instance_id.to_string()
        let peak = self.notify.take_report_peak(key)
        lines.push(self.report_line(inst, now, lang=policy.lang, peak~))
      }
    None => ()
  }
  // Reports always carry the full picture: counts, shape, load, disk.
  let fields : Array[(String, String)] = [("host", self.notify.host)]
  fields.push(("online", online.to_string()))
  fields.push(("abnormal", other.to_string()))
  match self.apps.get(app_name) {
    Some(config) => {
      fields.push(("mode", config.exec_mode))
      fields.push(("port", config.port.to_string()))
    }
    None => ()
  }
  match @proc.load_1m() {
    Some(value) => fields.push(("load1", format_percent(value)))
    None => ()
  }
  match @proc.disk_free_kb(self.state_dir) {
    Some(kb) => fields.push(("disk_free", (kb / 1048576).to_string() + "GB"))
    None => ()
  }
  let stats_window = if stats {
    Some(self.take_stats_window(app_name))
  } else {
    None
  }
  if stats {
    match stats_window {
      Some(w) => {
        fields.push(("peak_mb", (w.peak_kb / 1024).to_string()))
        fields.push(("restarts", w.restarts.to_string()))
      }
      None => ()
    }
  }
  let (title, rendered_body) = render_msg(
    policy.lang,
    if stats {
      StatsReport(app_name)
    } else {
      HealthReport(app_name, lines.length() == 0)
    },
  )
  @notify.Message::new(
    "report",
    if other > 0 {
      "warn"
    } else {
      "info"
    },
    title,
    if lines.length() == 0 {
      rendered_body
    } else {
      lines.join("\n")
    },
    if stats {
      "stats|" + app_name
    } else {
      "report|" + app_name
    },
    now,
    fields~,
  )
}

///|
/// Threshold alerts and the periodic report, evaluated once a minute per
/// project. Each condition is deduplicated by the engine, so something that
/// persists alerts once per dedupe window instead of on every pass.
pub fn Supervisor::check_notify(self : Supervisor, now : UInt64) -> Unit {
  if now >= self.last_notify_check_ms &&
    now - self.last_notify_check_ms < NOTIFY_CHECK_INTERVAL_MS {
    return
  }
  self.last_notify_check_ms = now
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
            if probed != inst.started_at_ms &&
              now >= inst.started_at_ms + policy.start_timeout_ms.to_uint64() {
              let rc = @proc.probe_reuseport(inst.port)
              if rc == 0 {
                self.start_probe_done[probe_key] = inst.started_at_ms
                let (title, body) = render_msg(
                  policy.lang,
                  StartTimeout(inst.port, policy.start_timeout_ms),
                )
                self.notify_instance(inst, "start_timeout", "warn", title, body)
              } else if rc > 0 {
                // Listening (shared or exclusive) — settled for this spawn.
                self.start_probe_done[probe_key] = inst.started_at_ms
              }
              // rc < 0: probe itself failed; retry on the next pass.
            }
          }
          if inst.status is Online || inst.status is Stopped {
            self.notify.forget_offline(key)
          } else if policy.threshold_offline_min > 0 {
            let since = self.notify.offline_since(key, now)
            let limit = (policy.threshold_offline_min * 60000).to_uint64()
            if now >= since && now - since >= limit {
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
      let count = storm_hit_count(hits, now, STORM_WINDOW_MS)
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
/// Periodic targets: every `[[notify.target]]` with an `interval` gets its
/// content rendered and delivered on its own schedule, straight through
/// deliver_all — no event queue, no dedupe, no rate limit.
pub async fn Supervisor::check_schedules(
  self : Supervisor,
  now : UInt64,
) -> Unit {
  // Cron granularity is minutes; evaluate once per minute, not on every
  // 50 ms tick — otherwise a matching minute fires once per tick.
  if now >= self.last_schedule_check_ms &&
    now - self.last_schedule_check_ms < NOTIFY_CHECK_INTERVAL_MS {
    return
  }
  self.last_schedule_check_ms = now
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
      let parts = match @proc.local_parts(now) {
        Some(parts) => parts
        None => continue
      }
      if !cron_matches(cron, parts) {
        continue
      }
      let stats = report.template == Some("stats")
      let message = self.build_report(app_name, policy, now, stats~)
      let results = @notify.deliver_all(
        lib_endpoints(report.targets, policy),
        message,
        policy.timeout_ms,
        self.notify.ctx,
      )
      for pair in results {
        let (name, failure) = pair
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          match failure {
            None => "notify_sent"
            Some(_) => "notify_target_failed"
          },
          app=Some(name),
          detail=match failure {
            None => "schedule"
            Some(reason) => "schedule: " + reason
          },
        )
      }
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
  let limit_kb = match self.apps.get(inst.app_name) {
    Some(app) => app.max_memory_mb * 1024
    None => 0
  }
  if limit_kb > 0 && rss_kb * 100 >= limit_kb * policy.threshold_rss_percent {
    let (title, body) = render_msg(
      policy.lang,
      ThresholdMemory(
        rss_kb / 1024,
        policy.threshold_rss_percent,
        limit_kb / 1024,
      ),
    )
    self.notify_instance(inst, "threshold", "warn", title, body)
  }
}
