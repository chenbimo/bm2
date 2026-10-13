///|
pub(all) suberror SupervisorError {
  UnknownApp(String)
  Conflict(String)
  PortConflict(String)
  /// A name is already registered by a different config file: (name, owner).
  NameTaken(String, String)
  IoError(String)
  RuntimeRejected(String)
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
    NameTaken(name, owner) => {
      logger.write_string("app ")
      logger.write_string(name)
      logger.write_string(" is already registered by ")
      logger.write_string(owner)
      logger.write_string(
        "; rename the project in bm2.toml, or retire the other one first",
      )
    }
    PortConflict(message) => {
      logger.write_string("port conflict: ")
      logger.write_string(message)
    }
    IoError(message) => {
      logger.write_string("io error: ")
      logger.write_string(message)
    }
    RuntimeRejected(message) => {
      logger.write_string("runtime rejected: ")
      logger.write_string(message)
    }
  }
}

///|
pub extend SupervisorError with Show::{to_string, output}

///|
/// The whole control loop for every managed project. All state lives in
/// the two maps below and is only ever mutated from `tick` or from a
/// request handler, both of which run on the daemon's single thread — so
/// no field here needs locking.
pub struct Supervisor {
  apps : Map[String, @config.Config]
  instances : Map[String, Array[Instance]]
  pending_restart : Map[String, Unit]
  pending_remove : Map[String, Unit]
  state_dir : String
  /// Runtime path used when a project does not pick `node`. Only tests
  /// override it (they drive the loop with /bin/sh); production keeps bun.
  bun_path : String
  /// Test seam: the production daemon uses the default.
  memory_interval_ms : Int32
  /// Interval gates: all four hold monotonic milliseconds, like every other
  /// deadline in this struct, so a system clock change cannot desynchronise
  /// them. Wall-clock time is read where an absolute time is needed.
  mut last_memory_check_ms : UInt64
  mut last_log_check_ms : UInt64
  mut last_reuseport_probe_ms : UInt64
  /// Control requests from the control plane. Nothing else may mutate
  /// supervised state, so this queue is the control plane's whole vocabulary:
  /// `tick` drains it and applies each request on the supervision task.
  commands : @aqueue.Queue[Command]
  /// Rotation sweeps published by the tick and executed by the rotation task.
  /// Sizes, copying and renaming all happen over there, so no filesystem work
  /// can land in a tick that must stay free of blocking calls.
  rotations : @aqueue.Queue[Array[@log.RotateJob]]
  /// Children killed on a failed spawn, waiting to be reaped: (pid, deadline on
  /// the monotonic clock). Such a child is never registered as an instance, so
  /// the instance reaper cannot see it, and waiting for it in place would hold
  /// the tick. Bounded by `ORPHAN_REAP_LIMIT`.
  mut reaping : Array[(Int32, UInt64)]
  /// Canonical config file of every registered project, keyed by name. A name is
  /// the project's identity — state dir, logs, supervision and policy all hang
  /// off it — so the same name may only ever be re-registered from the same file.
  /// Keeping it here makes that a pure in-memory check inside the tick.
  config_paths : Map[String, String]
  /// Projects stopped on purpose. Supervision skips them entirely: only `bm2 start`
  /// clears the mark, and it is persisted with the project so a daemon restart
  /// does not bring a stopped project back.
  stopped : Map[String, Unit]
  /// When this daemon started, on the monotonic clock: the uptime it reports is
  /// a duration, so a system time change cannot distort it.
  started_mono_ms : UInt64
  /// Commands applied since start. Monotonic, so an operator can sample it twice
  /// and see whether the control plane is moving.
  mut commands_applied : UInt64
  /// Notification engine: events flow in (an in-memory publish), deliveries flow
  /// out in the notify task. Supervision never waits on it — the tick has no
  /// await point at all.
  notify : Notifier
  mut last_notify_check_ms : UInt64
  mut last_schedule_check_ms : UInt64
  /// Per project: rolling stats window since the last stats push
  /// (peak sampled RSS in kB, automatic restarts).
  stats_window : Map[String, StatsWindow]
  /// Per project: restart timestamps inside the storm window.
  storm_hits : Map[String, Array[UInt64]]
  /// Instance key → the spawn generation (started_mono_ms) already probed
  /// for a missing listener, so each spawn is judged once.
  start_probe_done : Map[String, UInt64]
}

///|
/// Rolling aggregation for one project's stats reports: the sampled RSS
/// high-water mark and the automatic restart count since the last push.
pub(all) struct StatsWindow {
  peak_kb : Int32
  restarts : Int32
} derive(Debug)

///|
pub extend StatsWindow with Debug::{to_repr}

///|
/// Create an empty supervisor. Projects are added by `register` (on
/// `bm2 start`) or by `load_projects` (adoption after a daemon restart);
/// nothing is ever started automatically.
///
/// The notification queue is created here and shared by both sides: the
/// supervision task publishes on it (`Notifier`) and the notify task consumes
/// it (`NotifyRunner`, through `outbound`). That queue is the only thing the
/// two tasks have in common.
pub fn Supervisor::new(
  state_dir~ : String,
  bun_path~ : String,
  memory_interval_ms~ : Int32 = 5000,
) -> Supervisor raise {
  @fsx.mkdir_p(state_dir, mode=0o700)
  // mkdir only applies its mode to directories it creates; tighten a state
  // dir left behind by an older version, since it holds app logs.
  @utils.discard(() => @fsx.chmod(state_dir, 0o700))
  // The state dir holds the control-plane token, so it must be a directory this
  // uid owns. Without this check the HOME-less fallback (/tmp/bm2-<uid>) could
  // be a directory another local user created first: the mkdir would report
  // EEXIST, the chmod would fail quietly, and this daemon would write its token
  // where that user can read it.
  match @fsx.dir_owner(state_dir) {
    Some(uid) =>
      if uid != @proc.get_uid() {
        raise IoError(
          "state dir \{state_dir} is owned by uid \{uid}, but this process is uid \{@proc.get_uid()}",
        )
      }
    None => raise IoError("state dir \{state_dir} is not a directory")
  }
  let outbound : @aqueue.Queue[Outbound] = @aqueue.Queue::Queue(
    kind=Blocking(NOTIFY_INBOUND_CAPACITY),
  )
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
    last_reuseport_probe_ms: 0UL,
    commands: @aqueue.Queue::Queue(kind=Blocking(COMMAND_QUEUE_CAPACITY)),
    rotations: @aqueue.Queue::Queue(kind=Blocking(1)),
    reaping: [],
    config_paths: Map([]),
    stopped: Map([]),
    started_mono_ms: @proc.monotonic_ms(),
    commands_applied: 0UL,
    notify: Notifier::new(state_dir, @proc.hostname(), outbound),
    last_notify_check_ms: 0UL,
    last_schedule_check_ms: 0UL,
    stats_window: Map([]),
    storm_hits: Map([]),
    start_probe_done: Map([]),
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
  // Canonicalize before comparing: the same config file reached through a
  // symlink, a relative path or `..` is the same project, and only a genuinely
  // different file may not take the name over.
  let canonical = match @fsx.realpath(config_path) {
    Some(real) => real
    None => config_path
  }
  match self.config_paths.get(name) {
    Some(owner) if owner != canonical => raise NameTaken(name, owner)
    _ => ()
  }
  @fsx.mkdir_p("\{self.state_dir}/\{name}/logs", mode=0o700)
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
  self.config_paths[name] = canonical
  // The stopped mark belongs to supervision, not to the registration: a project
  // recovered at startup is registered again without losing it.
  @utils.discard(() => {
    save_project(self.state_dir, name, {
      config_path: canonical,
      stopped: self.stopped.contains(name),
    })
  })
}

///|
pub fn Supervisor::instance(
  self : Supervisor,
  app_name : String,
  instance_id : Int32,
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
/// The notification engine, for the daemon's own events and for `bm2 notify`.
pub fn Supervisor::notifier(self : Supervisor) -> Notifier {
  self.notify
}

///|
/// The queue supervision publishes notifications on. The daemon hands it to the
/// notify task once, at startup, and nothing else takes it.
pub fn Supervisor::outbound(self : Supervisor) -> @aqueue.Queue[Outbound] {
  self.notify.outbound
}

///|
/// The queue supervision publishes rotation sweeps on. The daemon hands it to
/// the rotation task once, at startup, and nothing else takes it.
pub fn Supervisor::rotations(
  self : Supervisor,
) -> @aqueue.Queue[Array[@log.RotateJob]] {
  self.rotations
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
pub async fn Supervisor::wait_settled(
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
  let deadline = @proc.monotonic_ms() + (timeout + 2000).to_uint64()
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
    if @proc.monotonic_ms() > deadline {
      return false
    }
    @async.sleep(50)
  } nobreak {
    false
  }
}

// ---------------------------------------------------------------------
// State transitions
//
// Every write to `inst.status` goes through one of these helpers, so the
// state machine is visible at a glance instead of being spread across the
// control loop. Transitions that only touch the instance are Instance
// methods; the ones that also persist (mark_online, mark_stopped,
// mark_restarting, mark_errored) are Supervisor methods because they write
// into the state dir. What stays at the call site is only the
// reason-specific reporting (events, crash log), which differs per
// transition.
// ---------------------------------------------------------------------

///|
/// One supervisor pass. Every step is idempotent and inspects the current
/// state before acting, so a pass can be repeated at any time without
/// bookkeeping; the daemon simply calls this as fast as its 50 ms poll
/// allows. The expensive scans (memory, log size) gate themselves on their
/// own timestamps, so the 50 ms cadence is a scheduling tick, not a
/// promise to rescan every instance that often.
///
/// This function is deliberately synchronous: it contains no await point, so
/// nothing in supervision can be delayed by the network, by a notification
/// endpoint, or by another task. Notifications are *published* here (an
/// in-memory queue put) and delivered by the notify task.
///
/// Control requests are applied here too, at the top of the tick: that is what
/// makes supervision the single writer of its own state, with the control plane
/// as one more queue to drain.
pub fn Supervisor::tick(self : Supervisor) -> Unit {
  self.drain_commands()
  self.reap()
  self.check_reaps()
  // Every gate and deadline below is measured on the monotonic clock, so a
  // system time change can neither stall a scan forever nor make it run on
  // every tick. Wall-clock time is read separately, where a human needs an
  // absolute time (cron fields, message timestamps).
  let now = @proc.monotonic_ms()
  if now - self.last_memory_check_ms >= self.memory_interval_ms.to_uint64() {
    self.last_memory_check_ms = now
    self.check_memory()
  }
  if now - self.last_log_check_ms >= LOG_CHECK_INTERVAL_MS {
    self.last_log_check_ms = now
    self.publish_rotation()
  }
  self.check_reuseport(now)
  self.check_deadlines(now)
  self.check_restarts(now)
  self.check_pending()
  self.check_removals()
  // Threshold alerts and periodic reports come last: they publish onto the
  // notify queue and never wait for a delivery.
  self.check_notify(now)
  self.check_schedules(now, @utils.now_ms())
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
    self.forget_app(name)
    @utils.discard(() => remove_project(self.state_dir, name))
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "project_removed",
      app=Some(name),
    )
  }
}

///|
/// What the daemon reports about itself in a `list` answer.
pub fn Supervisor::daemon_info(self : Supervisor) -> @protocol.DaemonInfo {
  let mut instances = 0
  for pair in self.instances.iter() {
    let (_, arr) = pair
    instances += arr.length()
  }
  let mut restarts = 0
  for _ in self.pending_restart.iter() {
    restarts += 1
  }
  let mut removals = 0
  for _ in self.pending_remove.iter() {
    removals += 1
  }
  {
    pid: @proc.get_pid(),
    uptime_ms: @proc.monotonic_ms() - self.started_mono_ms,
    instances,
    commands_applied: self.commands_applied,
    pending_restarts: restarts,
    pending_removals: removals,
  }
}

///|
/// Drop every in-memory trace of a project that has just been unregistered. Its
/// config, instances and registration file are gone by then; what is left is the
/// per-project bookkeeping (stats window, restart-storm history, start probes)
/// plus the notifier's own maps. Without this, a project re-registered under the
/// same name inherits the previous generation's numbers, and every removed
/// project leaves entries behind for good.
pub fn Supervisor::forget_app(self : Supervisor, app_name : String) -> Unit {
  self.stats_window.remove(app_name)
  self.storm_hits.remove(app_name)
  drop_app_keys(self.start_probe_done, app_name)
  self.notify.forget_app(app_name)
  self.notify.publish_forget(app_name)
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
/// How often the daemon probes cluster ports for SO_REUSEPORT.
const REUSEPORT_PROBE_INTERVAL_MS : UInt64 = 500UL

///|
/// A cluster instance that never listens within this window stops being
/// probed: slow boots and non-listening workers are legal, only an
/// exclusive listener is a violation.
const REUSEPORT_PROBE_TIMEOUT_MS : UInt64 = 60000UL

///|
fn Supervisor::check_deadlines(self : Supervisor, now : UInt64) -> Unit {
  for pair in self.instances.iter() {
    let (_, arr) = pair
    for inst in arr {
      if inst.kill_deadline_ms != 0UL && now >= inst.kill_deadline_ms {
        inst.kill_deadline_ms = 0UL
        if inst.alive() {
          @utils.discard(() => @proc.kill_group(inst.pid, @proc.SIGKILL))
        }
      }
    }
  }
}

///|
fn Supervisor::check_restarts(self : Supervisor, now : UInt64) -> Unit {
  for pair in self.instances.iter() {
    let (name, arr) = pair
    // A project stopped on purpose is never brought back by supervision; only
    // `bm2 start` clears the mark. Checked before anything else in this pass so
    // no scheduling below can resurrect it.
    if self.stopped.contains(name) {
      continue
    }
    let app = match self.apps.get(name) {
      Some(app) => app
      None => continue
    }
    for inst in arr {
      if inst.status is Restarting &&
        inst.restart_at_ms != 0UL &&
        now >= inst.restart_at_ms {
        inst.restart_at_ms = 0UL
        // spawn_instance marks its own failures; nothing to do here.
        try self.spawn_instance(app, inst) catch {
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
    self.pending_restart.remove(name)
    if self.stopped.contains(name) {
      continue
    }
    // spawn_instance marks its own failures; nothing to do here.
    try self.spawn_fresh(name) catch {
      _ => ()
    } noraise {
      _ => ()
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
  // Instances that no longer exist must not leave their state file behind: a
  // later recovery reads them, and a surviving orphan carrying the right
  // environment could be adopted back into a config that had dropped it.
  match old {
    Some(prev) =>
      for id in app.instances..<prev.length() {
        @utils.discard(() => {
          @fsx.unlink(state_path(self.state_dir, app_name, id))
        })
      }
    None => ()
  }
  self.instances[app_name] = arr
  for inst in arr {
    // One instance's spawn failure must not abort the loop: the failure
    // is already marked and retried with backoff by mark_spawn_failed,
    // and the remaining instances still deserve their spawn.
    @utils.discard(() => self.spawn_instance(app, inst))
  }
  let (title, body) = render_msg(
    app.notify.lang,
    ProjectStarted(app.instances, app.exec_mode, app.port),
  )
  self.notify_project(
    app_name,
    "lifecycle",
    "info",
    title,
    body,
    "started|" + app_name,
  )
}

///|
fn Supervisor::spawn_instance(
  self : Supervisor,
  app : @config.Config,
  inst : Instance,
) -> Unit raise {
  let logs = "\{self.state_dir}/\{app.name}/logs"
  @fsx.mkdir_p(logs, mode=0o700)
  let base = "\{logs}/\{app.name}-\{inst.instance_id}"
  inst.mark_starting()
  let runtime = if app.runtime == "node" { "node" } else { self.bun_path }
  let pid = try
    @proc.spawn({
      bun_path: runtime,
      script: app.script,
      cwd: app.cwd,
      out_log: base + ".out.log",
      err_log: base + ".error.log",
      env_blob: @proc.instance_env_blob(
        app.name,
        inst.instance_id,
        inst.port,
        extra=app.env,
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
  // Pin the process with a pidfd so liveness and exit detection stay
  // correct even if the pid gets reused later. Failure (kernel < 5.3)
  // is treated as a spawn failure: an unmanaged process is unacceptable.
  let pidfd = try @proc.pidfd_open(pid) catch {
    e => {
      // Group first, pid after: the child has not called setsid() yet at this
      // instant, so its group may not exist while its pid always does.
      @proc.kill_fresh(pid, @proc.SIGKILL)
      // Hand the killed child to the tick's reaper: a failed spawn must leave no
      // zombie, but waiting for it here would block this tick for up to half a
      // second — on the one path where the process is already misbehaving.
      self.register_reap(pid)
      raise IoError(e.to_string())
    }
  } noraise {
    fd => fd
  }
  self.mark_online(app, inst, pid, pidfd)
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
/// How long a killed child is given to disappear before its pid is forgotten.
/// This is the window the synchronous drain used to cover (50 attempts, 10ms
/// apart); being a duration, it is measured on the monotonic clock.
const ORPHAN_REAP_MS : UInt64 = 500UL

///|
/// How many killed-but-unreaped children to track. Spawn failures are rate
/// limited by the restart backoff, so a real daemon never comes near this; it
/// exists so the list cannot grow without a bound.
const ORPHAN_REAP_LIMIT : Int32 = 64

///|
/// Queue one killed child for the tick to reap. Nothing waits here: the pid is
/// remembered until it is gone or its window closes.
fn Supervisor::register_reap(self : Supervisor, pid : Int32) -> Unit {
  if self.reaping.length() >= ORPHAN_REAP_LIMIT {
    // The oldest entry is the one closest to giving up anyway.
    self.reaping = self.reaping[1:].to_owned()
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "reap_overflow",
      detail="dropped the oldest pending child",
    )
  }
  self.reaping.push((pid, @proc.monotonic_ms() + ORPHAN_REAP_MS))
}

///|
/// Reap the children left by failed spawns. Each tick makes one non-blocking
/// attempt per pending pid and keeps it until its deadline: the same bounded
/// window the synchronous drain covered, spread across ticks instead of slept
/// through, so no tick is ever held for it.
///
/// A pid that is not ours answers ECHILD and is dropped at once; an entry past
/// its deadline is dropped too, which leaves a zombie rather than a stuck tick —
/// the daemon's own exit collects anything left.
fn Supervisor::check_reaps(self : Supervisor) -> Unit {
  if self.reaping.is_empty() {
    return
  }
  let now = @proc.monotonic_ms()
  let keep : Array[(Int32, UInt64)] = []
  for entry in self.reaping {
    let (pid, deadline) = entry
    if now >= deadline {
      continue
    }
    let done = try @proc.wait_child(pid, nohang=true) catch {
      _ => true
    } noraise {
      reaped =>
        match reaped {
          Some(_) => true
          None => false
        }
    }
    if !done {
      keep.push(entry)
    }
  }
  self.reaping = keep
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
  self.record_storm_hit(inst.app_name, @utils.now_ms())
  self.record_stats_restart(inst.app_name)
  let app = match self.apps.get(inst.app_name) {
    Some(app) => app
    None => return
  }
  if inst.restart_count > app.max_restarts {
    let (title, body) = render_msg(
      app.notify.lang,
      ErroredSpawnStopped(inst.restart_count, app.max_restarts),
    )
    self.notify_instance(inst, "errored", "error", title, body)
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "instance_errored",
      app=Some(inst.app_name),
      instance=inst.instance_id,
      detail="spawn_failed",
    )
    self.mark_errored(inst, "spawn_failed")
  } else {
    let (title, body) = render_msg(
      app.notify.lang,
      SpawnFailedRetrying(inst.restart_count, app.max_restarts),
    )
    self.notify_instance(inst, "crash", "warn", title, body)
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "instance_restart_scheduled",
      app=Some(inst.app_name),
      instance=inst.instance_id,
      detail="spawn_failed",
    )
    self.mark_restarting(
      inst,
      @proc.monotonic_ms() +
      (app.restart_delay_ms * inst.restart_count).to_uint64(),
    )
  }
}

///|
/// Enter the stopping phase and ask the process group to terminate. The
/// SIGKILL escalation is armed here and fired by check_deadlines.
fn terminate(
  app : @config.Config,
  inst : Instance,
  intent : ExitIntent,
  reason : String,
) -> Unit {
  inst.mark_stopping(intent, reason)
  @utils.discard(() => @proc.kill_group(inst.pid, @proc.SIGTERM))
  inst.kill_deadline_ms = @proc.monotonic_ms() + app.stop_timeout_ms.to_uint64()
}

///|
fn signal_name(sig : Int32) -> String {
  match sig {
    15 => "SIGTERM"
    9 => "SIGKILL"
    6 => "SIGABRT"
    11 => "SIGSEGV"
    _ => "SIG\{sig}"
  }
}
