///|
pub(all) suberror SupervisorError {
  UnknownApp(String)
  Conflict(String)
  ConfigChanged
  IoError(String)
}

///|
pub impl Show for SupervisorError with fn output(self, logger) {
  match self {
    UnknownApp(name) => {
      logger.write_string("unknown app: ")
      logger.write_string(name)
    }
    Conflict(name) => {
      logger.write_string("operation already in progress for app: ")
      logger.write_string(name)
    }
    ConfigChanged =>
      logger.write_string("config structure changed; run bm2 kill <app> first")
    IoError(message) => {
      logger.write_string("io error: ")
      logger.write_string(message)
    }
  }
}

///|
pub struct Supervisor {
  mut apps : Map[String, @config.AppConfig]
  mut instances : Map[String, Array[Instance]]
  mut pending_restart : Map[String, Bool]
  state_dir : String
  bun_path : String
  memory_interval_ms : Int
  mut last_memory_check_ms : UInt64
}

///|
pub fn Supervisor::new(
  config : @config.Config,
  state_dir~ : String,
  bun_path~ : String,
  memory_interval_ms? : Int = 5000,
) -> Supervisor raise {
  @process.mkdir_p(state_dir, mode=0o700)
  let apps : Map[String, @config.AppConfig] = Map([])
  let instances : Map[String, Array[Instance]] = Map([])
  for app in config.apps {
    @process.mkdir_p("\{state_dir}/\{app.name}/logs", mode=0o700)
    apps[app.name] = app
    let arr = []
    for id in 0..<app.instances {
      arr.push(Instance::new(app, id))
    }
    instances[app.name] = arr
  }
  {
    apps,
    instances,
    pending_restart: Map([]),
    state_dir,
    bun_path,
    memory_interval_ms,
    last_memory_check_ms: 0UL,
  }
}

///|
pub fn Supervisor::instance(
  self : Supervisor,
  app_name : String,
  instance_id : Int,
) -> Instance raise SupervisorError {
  match self.instances.get(app_name) {
    Some(arr) => arr[instance_id]
    None => raise UnknownApp(app_name)
  }
}

///|
pub fn Supervisor::app_instances(
  self : Supervisor,
  app_name : String,
) -> Array[Instance] raise SupervisorError {
  match self.instances.get(app_name) {
    Some(arr) => arr
    None => raise UnknownApp(app_name)
  }
}

///|
pub fn Supervisor::snapshot(self : Supervisor) -> Array[Instance] {
  let result = []
  for pair in self.instances.iter() {
    let (_, arr) = pair
    for inst in arr {
      result.push(inst)
    }
  }
  result
}

///|
pub fn Supervisor::app_names(self : Supervisor) -> Array[String] {
  let names = []
  for pair in self.apps.iter() {
    let (name, _) = pair
    names.push(name)
  }
  names
}

///|
/// True when the app has no operation in flight: no pending full restart
/// and every instance reached a visible terminal state.
pub fn Supervisor::settled(self : Supervisor, app_name : String) -> Bool {
  if self.pending_restart.contains(app_name) {
    return false
  }
  match self.instances.get(app_name) {
    Some(arr) => {
      for inst in arr {
        match inst.status {
          Online | Stopped | Errored => ()
          _ => return false
        }
      }
      true
    }
    None => true
  }
}

///|
/// Drive the supervisor until every target app settles or the SIGKILL
/// escalation deadline (max stop_timeout of the targets + margin) passes.
pub fn Supervisor::wait_settled(
  self : Supervisor,
  names : Array[String],
) -> Bool {
  let mut timeout = 0
  for name in names {
    match self.apps.get(name) {
      Some(app) =>
        if app.stop_timeout_ms > timeout {
          timeout = app.stop_timeout_ms
        }
      None => ()
    }
  }
  let deadline = now_ms() + (timeout + 2000).to_uint64()
  while true {
    self.tick()
    let mut ok = true
    for name in names {
      if !self.settled(name) {
        ok = false
        break
      }
    }
    if ok {
      return true
    }
    if now_ms() > deadline {
      return false
    }
    @process.sleep_ms(50)
  } nobreak {
    false
  }
}

///|
/// Full restart semantics: SIGTERM old instances, wait for every old
/// instance to exit, then spawn fresh from the current config with the
/// restart count reset. First start has no old instances, so it spawns
/// directly without sending stop signals.
pub fn Supervisor::start_app(
  self : Supervisor,
  app_name : String,
) -> Unit raise {
  let insts = self.app_instances(app_name)
  if self.pending_restart.contains(app_name) {
    raise Conflict(app_name)
  }
  let app = self.app_config(app_name)
  let mut any_running = false
  for inst in insts {
    inst.restart_at_ms = 0UL
    if inst.alive() {
      any_running = true
      inst.exit_intent = RestartFresh
      inst.status = Stopping
      inst.last_reason = Some("restart_requested")
      terminate(app, inst)
    }
  }
  if any_running {
    self.pending_restart[app_name] = true
  } else {
    self.spawn_fresh(app_name)
  }
}

///|
/// Graceful stop; explicitly stopped instances never auto-restart.
pub fn Supervisor::stop_app(self : Supervisor, app_name : String) -> Unit raise {
  let app = self.app_config(app_name)
  for inst in self.app_instances(app_name) {
    inst.restart_at_ms = 0UL
    if inst.alive() {
      inst.exit_intent = Stop
      inst.status = Stopping
      inst.last_reason = Some("stop_requested")
      terminate(app, inst)
    } else if !(inst.status is Errored) {
      inst.status = Stopped
      inst.exit_intent = Stop
      discard(() => save_state(self.state_dir, inst))
    }
  }
}

///|
/// Immediate SIGKILL; marked manual and never auto-restarted.
pub fn Supervisor::kill_app(self : Supervisor, app_name : String) -> Unit raise {
  for inst in self.app_instances(app_name) {
    inst.restart_at_ms = 0UL
    if inst.alive() {
      inst.exit_intent = Stop
      inst.status = Stopping
      inst.last_reason = Some("manual_kill")
      inst.kill_deadline_ms = 0UL
      discard(() => @process.kill_group(inst.pid, @process.SIGKILL))
    } else if !(inst.status is Errored) {
      inst.status = Stopped
      inst.exit_intent = Stop
      discard(() => save_state(self.state_dir, inst))
    }
  }
}

///|
/// One supervisor pass: reap children, enforce memory limits, escalate
/// overdue SIGTERMs, run delayed restarts, finish pending full restarts
/// and reset restart counts of stable instances.
pub fn Supervisor::tick(self : Supervisor) -> Unit {
  self.reap()
  let now = now_ms()
  if now - self.last_memory_check_ms >= self.memory_interval_ms.to_uint64() {
    self.last_memory_check_ms = now
    self.check_memory()
  }
  self.check_deadlines(now)
  self.check_restarts(now)
  self.check_pending()
  self.check_uptime_resets(now)
}

///|
fn Supervisor::app_config(
  self : Supervisor,
  app_name : String,
) -> @config.AppConfig raise SupervisorError {
  match self.apps.get(app_name) {
    Some(app) => app
    None => raise UnknownApp(app_name)
  }
}

///|
fn Supervisor::find_by_pid(self : Supervisor, pid : Int) -> Instance? {
  for pair in self.instances.iter() {
    let (_, arr) = pair
    for inst in arr {
      if inst.pid == pid {
        return Some(inst)
      }
    }
  }
  None
}

///|
fn Supervisor::reap(self : Supervisor) -> Unit {
  while true {
    let result = try @process.wait_child(-1, nohang=true) catch {
      _ => None
    } noraise {
      reaped => reaped
    }
    match result {
      Some((pid, exit)) => self.handle_exit(pid, exit)
      None => break
    }
  }
}

///|
fn Supervisor::handle_exit(
  self : Supervisor,
  pid : Int,
  exit : @process.ChildExit,
) -> Unit {
  let inst = match self.find_by_pid(pid) {
    Some(found) => found
    None => return
  }
  let app = self.apps[inst.app_name]
  let now = now_ms()
  match exit {
    Exited(code) => {
      inst.last_exit_code = Some(code)
      inst.last_signal = None
    }
    Signaled(sig) => {
      inst.last_exit_code = None
      inst.last_signal = Some(sig)
    }
  }
  let exit_detail = match exit {
    Exited(code) => "exit_code=" + code.to_string()
    Signaled(sig) => "signal=" + signal_name(sig)
  }
  log_event(
    self.state_dir,
    "bm2d.events.jsonl",
    "instance_exited",
    app=Some(inst.app_name),
    instance=inst.instance_id,
    pid~,
    detail=exit_detail,
  )
  match inst.exit_intent {
    Stop | RestartFresh => {
      inst.status = Stopped
      inst.pid = 0
      discard(() => save_state(self.state_dir, inst))
    }
    RestartCounted => {
      let reason = match inst.last_reason {
        Some(r) => r
        None => "terminated"
      }
      self.counted_exit(app, inst, now, reason)
    }
    Idle => {
      let uptime = now - inst.started_at_ms
      let abnormal = match exit {
        Exited(0) => uptime < app.min_uptime_ms.to_uint64()
        _ => true
      }
      if abnormal {
        let reason = match exit {
          Exited(0) => "quick_exit"
          Exited(_) => "exit_code"
          Signaled(_) => "signal"
        }
        self.counted_exit(app, inst, now, reason)
      } else {
        // Clean self-exit after min_uptime: keep the service alive per
        // plan, but do not burn the consecutive-restart budget.
        inst.status = Restarting
        inst.pid = 0
        inst.restart_at_ms = now + app.restart_delay_ms.to_uint64()
        discard(() => save_state(self.state_dir, inst))
      }
    }
  }
  inst.exit_intent = Idle
}

///|
fn Supervisor::counted_exit(
  self : Supervisor,
  app : @config.AppConfig,
  inst : Instance,
  now : UInt64,
  reason : String,
) -> Unit {
  inst.restart_count += 1
  inst.last_reason = Some(reason)
  self.write_crash(inst, reason)
  if inst.restart_count > app.max_restarts {
    inst.status = Errored
    inst.pid = 0
    inst.restart_at_ms = 0UL
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "instance_errored",
      app=Some(inst.app_name),
      instance=inst.instance_id,
      detail=reason,
    )
  } else {
    inst.status = Restarting
    inst.pid = 0
    inst.restart_at_ms = now + app.restart_delay_ms.to_uint64()
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "instance_restart_scheduled",
      app=Some(inst.app_name),
      instance=inst.instance_id,
      detail=reason,
    )
  }
  discard(() => save_state(self.state_dir, inst))
}

///|
fn Supervisor::check_memory(self : Supervisor) -> Unit {
  for pair in self.instances.iter() {
    let (name, arr) = pair
    let app = self.apps[name]
    for inst in arr {
      if inst.status is Online {
        match @process.read_rss_kb(inst.pid) {
          Some(kb) =>
            if kb > app.max_memory_mb * 1024 {
              inst.last_rss_kb = kb
              inst.exit_intent = RestartCounted
              inst.status = Stopping
              inst.last_reason = Some("memory_limit")
              log_event(
                self.state_dir,
                "bm2d.events.jsonl",
                "memory_limit",
                app=Some(inst.app_name),
                instance=inst.instance_id,
                pid=inst.pid,
                detail="rss_kb=" + kb.to_string(),
              )
              terminate(app, inst)
            }
          None => ()
        }
      }
    }
  }
}

///|
fn Supervisor::check_deadlines(self : Supervisor, now : UInt64) -> Unit {
  for pair in self.instances.iter() {
    let (_, arr) = pair
    for inst in arr {
      if inst.kill_deadline_ms != 0UL && now >= inst.kill_deadline_ms {
        inst.kill_deadline_ms = 0UL
        if inst.alive() {
          discard(() => @process.kill_group(inst.pid, @process.SIGKILL))
        }
      }
    }
  }
}

///|
fn Supervisor::check_restarts(self : Supervisor, now : UInt64) -> Unit {
  for pair in self.instances.iter() {
    let (name, arr) = pair
    for inst in arr {
      if inst.status is Restarting &&
        inst.restart_at_ms != 0UL &&
        now >= inst.restart_at_ms {
        inst.restart_at_ms = 0UL
        try self.spawn_instance(self.apps[name], inst) catch {
          _ => self.mark_spawn_failed(inst)
        } noraise {
          _ => ()
        }
      }
    }
  }
}

///|
fn Supervisor::check_pending(self : Supervisor) -> Unit {
  let ready = []
  for pair in self.pending_restart.iter() {
    let (name, _) = pair
    let mut all_stopped = true
    for inst in self.instances[name] {
      if inst.pid != 0 {
        all_stopped = false
        break
      }
    }
    if all_stopped {
      ready.push(name)
    }
  }
  for name in ready {
    self.pending_restart.remove(name)
    try self.spawn_fresh(name) catch {
      _ =>
        for inst in self.instances[name] {
          self.mark_spawn_failed(inst)
        }
    } noraise {
      _ => ()
    }
  }
}

///|
fn Supervisor::check_uptime_resets(self : Supervisor, now : UInt64) -> Unit {
  for pair in self.instances.iter() {
    let (name, arr) = pair
    let app = self.apps[name]
    for inst in arr {
      if inst.status is Online &&
        inst.restart_count > 0 &&
        !inst.uptime_reset_done &&
        now - inst.started_at_ms >= app.min_uptime_ms.to_uint64() {
        inst.uptime_reset_done = true
        inst.restart_count = 0
        discard(() => save_state(self.state_dir, inst))
      }
    }
  }
}

///|
fn Supervisor::spawn_fresh(self : Supervisor, app_name : String) -> Unit raise {
  let app = self.app_config(app_name)
  for inst in self.instances[app_name] {
    inst.restart_count = 0
    self.spawn_instance(app, inst)
  }
}

///|
fn Supervisor::spawn_instance(
  self : Supervisor,
  app : @config.AppConfig,
  inst : Instance,
) -> Unit raise {
  let logs = "\{self.state_dir}/\{app.name}/logs"
  @process.mkdir_p(logs, mode=0o700)
  let base = "\{logs}/\{app.name}-\{inst.instance_id}"
  inst.status = Starting
  let pid = @process.spawn({
    bun_path: self.bun_path,
    script: app.script,
    cwd: app.cwd,
    out_log: base + ".out.log",
    err_log: base + ".error.log",
    env_blob: @process.instance_env_blob(
      app.name,
      inst.instance_id,
      inst.port,
      app.env,
    ),
  })
  inst.pid = pid
  inst.status = Online
  inst.started_at_ms = now_ms()
  inst.exit_intent = Idle
  inst.kill_deadline_ms = 0UL
  inst.restart_at_ms = 0UL
  inst.uptime_reset_done = false
  inst.last_reason = None
  save_state(self.state_dir, inst)
  log_event(
    self.state_dir,
    "bm2d.events.jsonl",
    "instance_started",
    app=Some(inst.app_name),
    instance=inst.instance_id,
    pid~,
  )
}

///|
fn Supervisor::mark_spawn_failed(self : Supervisor, inst : Instance) -> Unit {
  if !(inst.status is Online) {
    inst.status = Errored
    inst.last_reason = Some("spawn_failed")
    self.write_crash(inst, "spawn_failed")
    discard(() => save_state(self.state_dir, inst))
  }
}

///|
fn Supervisor::write_crash(
  self : Supervisor,
  inst : Instance,
  reason : String,
) -> Unit {
  let buf = StringBuilder::new()
  buf.write_string(iso8601(now_ms()))
  buf.write_string(" app=" + inst.app_name)
  buf.write_string(" instance=" + inst.instance_id.to_string())
  buf.write_string(" pid=" + inst.pid.to_string())
  buf.write_string(" reason=" + reason)
  match inst.last_exit_code {
    Some(code) => buf.write_string(" exitCode=" + code.to_string())
    None => ()
  }
  match inst.last_signal {
    Some(sig) => buf.write_string(" signal=" + signal_name(sig))
    None => ()
  }
  if reason == "memory_limit" {
    buf.write_string(" rssMb=" + (inst.last_rss_kb / 1024).to_string())
    buf.write_string(
      " limitMb=" + self.apps[inst.app_name].max_memory_mb.to_string(),
    )
  }
  buf.write_string(" restartCount=" + inst.restart_count.to_string())
  buf.write_string("\n")
  let path = "\{self.state_dir}/\{inst.app_name}/logs/\{inst.app_name}-\{inst.instance_id}.crash.log"
  discard(() => @process.append_file(path, @utf8.encode(buf.to_string())))
}

///|
fn terminate(app : @config.AppConfig, inst : Instance) -> Unit {
  discard(() => @process.kill_group(inst.pid, @process.SIGTERM))
  inst.kill_deadline_ms = now_ms() + app.stop_timeout_ms.to_uint64()
}

///|
fn signal_name(sig : Int) -> String {
  match sig {
    15 => "SIGTERM"
    9 => "SIGKILL"
    6 => "SIGABRT"
    11 => "SIGSEGV"
    _ => "SIG\{sig}"
  }
}

///|
/// Run a side effect whose failure must not abort a supervisor tick.
fn discard(f : () -> Unit raise) -> Unit {
  try f() catch {
    _ => ()
  } noraise {
    _ => ()
  }
}
