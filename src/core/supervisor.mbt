///|
pub(all) suberror SupervisorError {
  UnknownApp(String)
  Conflict(String)
  PortConflict(String)
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
    PortConflict(message) => {
      logger.write_string("port conflict: ")
      logger.write_string(message)
    }
    IoError(message) => {
      logger.write_string("io error: ")
      logger.write_string(message)
    }
  }
}

///|
/// One log file rotates once it exceeds this size; ten generations are
/// kept, bounding total log usage per file at ~100 MB.
const LOG_ROTATE_BYTES : Int64 = 10L * 1024L * 1024L

///|
/// How often the daemon checks log sizes for rotation.
const LOG_CHECK_INTERVAL_MS : UInt64 = 10000UL

///|
pub struct Supervisor {
  apps : Map[String, @config.Config]
  instances : Map[String, Array[Instance]]
  pending_restart : Map[String, Unit]
  pending_remove : Map[String, Unit]
  state_dir : String
  bun_path : String
  memory_interval_ms : Int
  mut last_memory_check_ms : UInt64
  mut last_log_check_ms : UInt64
}

///|
/// Create an empty supervisor. Projects are added by `register` (on
/// `bm2 start`) or by `load_projects` (adoption after a daemon restart);
/// nothing is ever started automatically.
pub fn Supervisor::new(
  state_dir~ : String,
  bun_path~ : String,
  memory_interval_ms? : Int = 5000,
) -> Supervisor raise {
  @process.mkdir_p(state_dir, mode=0o700)
  {
    apps: Map([]),
    instances: Map([]),
    pending_restart: Map([]),
    pending_remove: Map([]),
    state_dir,
    bun_path,
    memory_interval_ms,
    last_memory_check_ms: 0UL,
    last_log_check_ms: 0UL,
  }
}

///|
/// Register or update one project from a freshly parsed config, and record
/// its config path so a later daemon can reload it for adoption.
/// Re-registering an existing project swaps its config in place — the
/// instance array is rebuilt by `spawn_fresh` once the full restart that
/// `bm2 start` performs has stopped the old instances. Port ranges must
/// not overlap any other registered project.
pub fn Supervisor::register(
  self : Supervisor,
  config : @config.Config,
  config_path : String,
) -> Unit raise {
  let name = config.name
  self.reject_port_conflict(config)
  @process.mkdir_p("\{self.state_dir}/\{name}/logs", mode=0o700)
  match self.instances.get(name) {
    Some(_) => self.apps[name] = config
    None => {
      let arr = []
      for id in 0..<config.instances {
        arr.push(Instance::new(config, id))
      }
      self.apps[name] = config
      self.instances[name] = arr
    }
  }
  self.pending_restart.remove(name)
  self.pending_remove.remove(name)
  discard(() => save_project(self.state_dir, name, { config_path, }))
}

///|
fn Supervisor::reject_port_conflict(
  self : Supervisor,
  config : @config.Config,
) -> Unit raise {
  let start = config.port
  let end = config.port + config.instances - 1
  for pair in self.apps.iter() {
    let (_, other) = pair
    if other.name != config.name &&
      start <= other.port + other.instances - 1 &&
      other.port <= end {
      raise PortConflict(
        "\{config.name} port range \{start}~\{end} overlaps \{other.name} \{other.port}~\{other.port + other.instances - 1}",
      )
    }
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
    self.pending_restart[app_name] = ()
  } else {
    self.spawn_fresh(app_name)
  }
}

///|
/// Graceful stop; explicitly stopped instances never auto-restart.
/// Clears any pending full restart so a kill during a restart window
/// cannot resurrect the app afterwards.
pub fn Supervisor::stop_app(self : Supervisor, app_name : String) -> Unit raise {
  self.pending_restart.remove(app_name)
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
      // Liveness was lost without a reap: the pid is gone, so clear it
      // (a stale pid would block project removal forever) and release
      // the pidfd so it can never leak.
      inst.pid = 0
      if inst.pidfd > 0 {
        @process.close(inst.pidfd)
        inst.pidfd = 0
      }
      self.try_save_state(inst)
    }
  }
}

///|
/// Immediate SIGKILL; marked manual and never auto-restarted. Clears any
/// pending full restart, mirroring stop_app. The project is queued for
/// removal once every instance has stopped, so a killed project never
/// comes back after a daemon restart.
pub fn Supervisor::kill_app(self : Supervisor, app_name : String) -> Unit raise {
  self.pending_restart.remove(app_name)
  self.pending_remove[app_name] = ()
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
      // Liveness was lost without a reap: clear the stale pid too, or the
      // project removal would wait on it forever.
      inst.pid = 0
      if inst.pidfd > 0 {
        @process.close(inst.pidfd)
        inst.pidfd = 0
      }
      self.try_save_state(inst)
    }
  }
}

///|
/// One supervisor pass: reap children, enforce memory limits, escalate
/// overdue SIGTERMs, run delayed restarts, finish pending full restarts,
/// drop killed projects, rotate oversized logs and reset restart counts
/// of stable instances.
pub fn Supervisor::tick(self : Supervisor) -> Unit {
  self.reap()
  let now = now_ms()
  if now - self.last_memory_check_ms >= self.memory_interval_ms.to_uint64() {
    self.last_memory_check_ms = now
    self.check_memory()
  }
  if now - self.last_log_check_ms >= LOG_CHECK_INTERVAL_MS {
    self.last_log_check_ms = now
    self.rotate_logs()
  }
  self.check_deadlines(now)
  self.check_restarts(now)
  self.check_pending()
  self.check_removals()
  self.check_uptime_resets()
}

///|
/// Rotate logs past the size limit: app stdout/stderr are held open by
/// the app process (copytruncate), crash logs and the daemon event log
/// are written by us (rename). Failures are logged, never fatal.
fn Supervisor::rotate_logs(self : Supervisor) -> Unit {
  for pair in self.instances.iter() {
    let (name, arr) = pair
    for inst in arr {
      let base = "\{self.state_dir}/\{name}/logs/\{name}-\{inst.instance_id}"
      self.rotate_log(base + ".out.log", copytruncate=true)
      self.rotate_log(base + ".error.log", copytruncate=true)
      self.rotate_log(base + ".crash.log", copytruncate=false)
    }
  }
  self.rotate_log("\{self.state_dir}/bm2d.events.jsonl", copytruncate=false)
}

///|
fn Supervisor::rotate_log(
  self : Supervisor,
  path : String,
  copytruncate~ : Bool,
) -> Unit {
  match @process.file_size(path) {
    Some(size) if size > LOG_ROTATE_BYTES =>
      try {
        if copytruncate {
          @process.copytruncate(path)
        } else {
          @process.rotate(path)
        }
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "log_rotated",
          detail=path,
        )
      } catch {
        e =>
          log_event(
            self.state_dir,
            "bm2d.events.jsonl",
            "log_rotate_failed",
            detail=path + ": " + e.to_string(),
          )
      } noraise {
        _ => ()
      }
    _ => ()
  }
}

///|
/// Persist instance state; failures are logged, never fatal, so a broken
/// disk degrades to stale state files instead of breaking supervision.
fn Supervisor::try_save_state(self : Supervisor, inst : Instance) -> Unit {
  try save_state(self.state_dir, inst) catch {
    e =>
      log_event(
        self.state_dir,
        "bm2d.events.jsonl",
        "state_save_failed",
        app=Some(inst.app_name),
        instance=inst.instance_id,
        detail=e.to_string(),
      )
  } noraise {
    _ => ()
  }
}

///|
/// Drop projects whose kill has finished (every instance stopped):
/// remove the in-memory project and its registration file, so a killed
/// project is never listed or re-adopted after a daemon restart.
fn Supervisor::check_removals(self : Supervisor) -> Unit {
  let ready = []
  for pair in self.pending_remove.iter() {
    let (name, _) = pair
    let mut all_stopped = true
    match self.instances.get(name) {
      Some(arr) =>
        for inst in arr {
          if inst.pid != 0 {
            all_stopped = false
            break
          }
        }
      None => ()
    }
    if all_stopped {
      ready.push(name)
    }
  }
  for name in ready {
    self.pending_remove.remove(name)
    self.apps.remove(name)
    self.instances.remove(name)
    discard(() => remove_project(self.state_dir, name))
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "project_removed",
      app=Some(name),
    )
  }
}

///|
pub fn Supervisor::app_config(
  self : Supervisor,
  app_name : String,
) -> @config.Config raise SupervisorError {
  match self.apps.get(app_name) {
    Some(app) => app
    None => raise UnknownApp(app_name)
  }
}

///|
/// Reap exited instances. Child processes report their exit code through
/// waitid(P_PIDFD); adopted (reparented) instances are not waitable
/// (ECHILD), so their exit is detected with the pidfd readability check
/// and recorded as an unknown exit.
fn Supervisor::reap(self : Supervisor) -> Unit {
  for pair in self.instances.iter() {
    let (_, arr) = pair
    for inst in arr {
      if inst.pidfd > 0 {
        // Child processes (including zombies) are reaped by waitid.
        let reaped = try @process.wait_pidfd(inst.pidfd, nohang=true) catch {
          _ => None
        } noraise {
          result => result
        }
        match reaped {
          Some((pid, exit)) => {
            @process.close(inst.pidfd)
            inst.pidfd = 0
            self.handle_exit(inst, pid, Some(exit))
          }
          None =>
            // waitid reports nothing: alive, stopped, or an adopted
            // (non-waitable) instance. The pidfd readability check plus
            // pid liveness distinguishes a real exit from a stop event.
            if !@process.pidfd_alive(inst.pidfd) &&
              !@process.pid_alive(inst.pid) {
              @process.close(inst.pidfd)
              inst.pidfd = 0
              self.handle_exit(inst, inst.pid, None)
            }
        }
      }
    }
  }
}

///|
fn Supervisor::handle_exit(
  self : Supervisor,
  inst : Instance,
  pid : Int,
  exit : @process.ChildExit?,
) -> Unit {
  let app = self.apps[inst.app_name]
  let now = now_ms()
  match exit {
    None => {
      inst.last_exit_code = None
      inst.last_signal = None
    }
    Some(@process.ChildExit::Exited(code)) => {
      inst.last_exit_code = Some(code)
      inst.last_signal = None
    }
    Some(@process.ChildExit::Signaled(sig)) => {
      inst.last_exit_code = None
      inst.last_signal = Some(sig)
    }
  }
  let exit_detail = match exit {
    None => "unknown"
    Some(@process.ChildExit::Exited(code)) => "exit_code=" + code.to_string()
    Some(@process.ChildExit::Signaled(sig)) => "signal=" + signal_name(sig)
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
      self.try_save_state(inst)
    }
    RestartCounted => {
      let reason = match inst.last_reason {
        Some(r) => r
        None => "terminated"
      }
      self.counted_exit(app, inst, now, reason)
    }
    Idle => {
      // elapsed_since clamps clock rollback so a clean exit shortly after
      // a spawn is never misread as a long-lived process.
      let uptime = elapsed_since(inst.started_at_ms)
      let abnormal = match exit {
        Some(@process.ChildExit::Exited(0)) =>
          uptime < app.min_uptime_ms.to_uint64()
        _ => true
      }
      if abnormal {
        let reason = match exit {
          Some(@process.ChildExit::Exited(0)) => "quick_exit"
          Some(@process.ChildExit::Exited(_)) => "exit_code"
          Some(@process.ChildExit::Signaled(_)) => "signal"
          None => "terminated"
        }
        self.counted_exit(app, inst, now, reason)
      } else {
        // Clean self-exit after min_uptime: keep the service alive per
        // plan, but do not burn the consecutive-restart budget. Still
        // log the restart so silent restart storms stay observable.
        inst.status = Restarting
        inst.pid = 0
        inst.restart_at_ms = now + app.restart_delay_ms.to_uint64()
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "instance_restart_scheduled",
          app=Some(inst.app_name),
          instance=inst.instance_id,
          detail="clean_exit",
        )
        self.try_save_state(inst)
      }
    }
  }
  inst.exit_intent = Idle
}

///|
fn Supervisor::counted_exit(
  self : Supervisor,
  app : @config.Config,
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
  self.try_save_state(inst)
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
        // spawn_instance marks its own failures; nothing to do here.
        try self.spawn_instance(self.apps[name], inst) catch {
          _ => ()
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
    // spawn_instance marks its own failures; nothing to do here.
    try self.spawn_fresh(name) catch {
      _ => ()
    } noraise {
      _ => ()
    }
  }
}

///|
fn Supervisor::check_uptime_resets(self : Supervisor) -> Unit {
  for pair in self.instances.iter() {
    let (name, arr) = pair
    let app = self.apps[name]
    for inst in arr {
      if inst.status is Online &&
        inst.restart_count > 0 &&
        !inst.uptime_reset_done &&
        elapsed_since(inst.started_at_ms) >= app.min_uptime_ms.to_uint64() {
        inst.uptime_reset_done = true
        inst.restart_count = 0
        self.try_save_state(inst)
      }
    }
  }
}

///|
/// Rebuild the instance array from the current config, then spawn every
/// instance. Called once a full restart's old instances have stopped, so
/// structural changes (instances count, ports, script) take effect here.
fn Supervisor::spawn_fresh(self : Supervisor, app_name : String) -> Unit raise {
  let app = self.app_config(app_name)
  let old = self.instances.get(app_name)
  let arr = []
  for id in 0..<app.instances {
    let inst = Instance::new(app, id)
    // Keep the accumulated start count across a rebuild, so a config
    // update restart does not reset the launch counter.
    match old {
      Some(prev) =>
        match prev.get(id) {
          Some(prev_inst) => inst.times = prev_inst.times
          None => ()
        }
      None => ()
    }
    arr.push(inst)
  }
  self.instances[app_name] = arr
  for inst in arr {
    // One instance's spawn failure must not abort the loop: the failure
    // is already marked and retried with backoff by mark_spawn_failed,
    // and the remaining instances still deserve their spawn.
    discard(() => self.spawn_instance(app, inst))
  }
}

///|
fn Supervisor::spawn_instance(
  self : Supervisor,
  app : @config.Config,
  inst : Instance,
) -> Unit raise {
  let logs = "\{self.state_dir}/\{app.name}/logs"
  @process.mkdir_p(logs, mode=0o700)
  let base = "\{logs}/\{app.name}-\{inst.instance_id}"
  inst.status = Starting
  let runtime = if app.runtime == "node" { "node" } else { self.bun_path }
  let pid = try
    @process.spawn({
      bun_path: runtime,
      script: app.script,
      cwd: app.cwd,
      out_log: base + ".out.log",
      err_log: base + ".error.log",
      env_blob: @process.instance_env_blob(
        app.name,
        inst.instance_id,
        inst.port,
      ),
    })
  catch {
    e => {
      // Mark the failure here so every spawn path (start, pending restart,
      // delayed retry) lands in the same backoff bookkeeping; callers just
      // propagate the error without re-marking.
      self.mark_spawn_failed(inst)
      raise IoError(e.to_string())
    }
  } noraise {
    pid => pid
  }
  inst.pid = pid
  // Pin the process with a pidfd so liveness and exit detection stay
  // correct even if the pid gets reused later. Failure (kernel < 5.3)
  // is treated as a spawn failure: an unmanaged process is unacceptable.
  let pidfd = try @process.pidfd_open(pid) catch {
    e => {
      discard(() => @process.kill_group(pid, @process.SIGKILL))
      // Reap the killed child so a failed spawn leaves no zombie.
      @process.drain_child(pid)
      raise IoError(e.to_string())
    }
  } noraise {
    fd => fd
  }
  inst.pidfd = pidfd
  inst.status = Online
  inst.started_at_ms = now_ms()
  inst.times += 1
  inst.exit_intent = Idle
  inst.kill_deadline_ms = 0UL
  inst.restart_at_ms = 0UL
  inst.uptime_reset_done = false
  inst.last_reason = None
  self.try_save_state(inst)
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
/// Spawn failures count against the restart budget and back off like
/// crash restarts: transient failures retry with a growing delay, only
/// exhausting the budget lands the instance in errored.
fn Supervisor::mark_spawn_failed(self : Supervisor, inst : Instance) -> Unit {
  if inst.status is Online {
    return
  }
  inst.restart_count += 1
  inst.last_reason = Some("spawn_failed")
  self.write_crash(inst, "spawn_failed")
  let app = self.apps[inst.app_name]
  if inst.restart_count > app.max_restarts {
    inst.status = Errored
    inst.restart_at_ms = 0UL
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "instance_errored",
      app=Some(inst.app_name),
      instance=inst.instance_id,
      detail="spawn_failed",
    )
  } else {
    inst.status = Restarting
    inst.restart_at_ms = now_ms() +
      (app.restart_delay_ms * inst.restart_count).to_uint64()
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "instance_restart_scheduled",
      app=Some(inst.app_name),
      instance=inst.instance_id,
      detail="spawn_failed",
    )
  }
  self.try_save_state(inst)
}

///|
fn Supervisor::write_crash(
  self : Supervisor,
  inst : Instance,
  reason : String,
) -> Unit {
  let buf = StringBuilder()
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
fn terminate(app : @config.Config, inst : Instance) -> Unit {
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
