///|
/// The bridge between supervision and notifications: it turns supervisor state
/// (instances, configs, sampled metrics) into messages. Delivery policy lives in
/// the engine, the once-a-minute evaluation in `alert_schedule.mbt`, and the
/// policy for each message comes from the project that produced it.

///|
/// The `[notify]` policy of one project. A project that never configured
/// notifications gets the disabled policy, so callers stay unconditional.
fn Supervisor::project_policy(
  self : Supervisor,
  app_name : String,
) -> @config.NotifyConfig {
  match self.config_of(app_name) {
    Some(app) => app.notify
    None => @config.NotifyConfig::disabled()
  }
}

///|
/// The field list of one instance for a message. `now_mono` is monotonic
/// milliseconds, so the uptime line is a real duration rather than a number
/// a system time change could distort.
fn instance_fields(
  inst : Instance,
  now_mono : UInt64,
) -> Array[(String, String)] {
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
  if inst.started_mono_ms > 0UL && now_mono > inst.started_mono_ms {
    fields.push(
      ("uptime", @utils.human_duration(now_mono - inst.started_mono_ms)),
    )
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
  // Two clocks, two jobs: the message timestamp is wall-clock time (it is what
  // the recipient reads and what platform signatures are computed over), while
  // the uptime field is a duration, measured on the monotonic clock.
  let now_mono = @proc.monotonic_ms()
  self.notify.emit(
    self.project_policy(inst.app_name),
    inst.app_name,
    @notify.Message::new(
      event,
      level,
      "\{inst.app_name} · \{title}",
      body,
      instance_signature(event, inst),
      @utils.now_ms(),
      fields=instance_fields(inst, now_mono),
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
  let now = @utils.now_ms()
  let instances = match self.instances_of(app_name) {
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
  match self.instances_of(app_name) {
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
  now_mono : UInt64,
  lang~ : String,
  peak~ : Int32?,
) -> String {
  // Matched on `Lang` rather than tested for being Chinese: a language added later
  // has to answer with its own field labels, instead of silently taking the English
  // ones. The machine keys inside events stay neutral either way.
  let language = @i18n.Lang::from_name(lang).unwrap_or(@i18n.Lang::En)
  let (lb_port, lb_rss, lb_peak, lb_cpu, lb_uptime, lb_restarts) = match
    language {
    @i18n.Lang::En => ("port", "RSS", "peak", "CPU", "uptime", "restarts")
    @i18n.Lang::Zh => ("端口", "内存", "峰值", "CPU", "运行", "重启")
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
        now_mono,
      ) {
      Some(percent) =>
        line = line + " · " + lb_cpu + " " + format_percent(percent) + "%"
      None => ()
    }
    if inst.started_mono_ms > 0UL && now_mono > inst.started_mono_ms {
      line = line +
        " · " +
        lb_uptime +
        " " +
        @utils.human_duration(now_mono - inst.started_mono_ms)
    }
  } else if inst.last_reason is Some(reason) {
    line = line + " · " + reason
  }
  if inst.restart_count > 0 {
    match self.config_of(inst.app_name) {
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
  now_mono : UInt64,
  stats~ : Bool,
) -> @notify.Message {
  let lines = []
  let mut online = 0
  let mut other = 0
  match self.instances_of(app_name) {
    Some(arr) =>
      for inst in arr {
        if inst.status is Online {
          online += 1
        } else if !(inst.status is Stopped) {
          other += 1
        }
        let key = inst.app_name + "/" + inst.instance_id.to_string()
        let peak = self.notify.take_report_peak(key)
        lines.push(self.report_line(inst, now_mono, lang=policy.lang, peak~))
      }
    None => ()
  }
  // Reports always carry the full picture: counts, shape, load, disk.
  let fields : Array[(String, String)] = [("host", self.notify.host)]
  fields.push(("online", online.to_string()))
  fields.push(("abnormal", other.to_string()))
  match self.config_of(app_name) {
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
    // The message timestamp is wall-clock time: it is what the recipient
    // sees, and what platform signatures are computed over.
    @utils.now_ms(),
    fields~,
  )
}

/// Threshold conditions and report schedules live in `alert_schedule.mbt`.
