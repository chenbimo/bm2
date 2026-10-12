///|
/// The stopping phase: the process is still alive, and `intent` records
/// what should happen once it is gone (stay down, restart fresh, or
/// restart against the crash budget).
fn Instance::mark_stopping(
  inst : Instance,
  intent : ExitIntent,
  reason : String,
) -> Unit {
  inst.exit_intent = intent
  inst.status = Stopping
  inst.last_reason = Some(reason)
}

///|
/// A spawn attempt is in flight; the instance is not listed as online yet.
fn Instance::mark_starting(inst : Instance) -> Unit {
  inst.status = Starting
}

///|
/// Liveness was lost without a reap: drop the pid (a stale one would block
/// project removal forever) and release the pidfd so it can never leak.
fn Instance::clear_process(inst : Instance) -> Unit {
  inst.pid = 0
  if inst.pidfd > 0 {
    @proc.close(inst.pidfd)
    inst.pidfd = 0
  }
}

///|
/// A successful spawn: the handle is live and every lifecycle field starts
/// from a clean slate.
fn Supervisor::mark_online(
  self : Supervisor,
  app : @config.Config,
  inst : Instance,
  pid : Int32,
  pidfd : Int32,
) -> Unit {
  inst.pid = pid
  inst.pidfd = pidfd
  inst.status = Online
  inst.started_at_ms = @utils.now_ms()
  inst.times += 1
  inst.exit_intent = Idle
  inst.kill_deadline_ms = 0UL
  inst.restart_at_ms = 0UL
  inst.last_reason = None
  inst.reuseport = if app.exec_mode == "cluster" {
    ReusePending
  } else {
    ReuseOff
  }
  inst.reuseport_deadline_ms = 0UL
  self.try_save_state(inst)
}

///|
/// Terminal stopped state. A stopped instance is omitted from `bm2 list`
/// and never restarts on its own.
fn Supervisor::mark_stopped(self : Supervisor, inst : Instance) -> Unit {
  inst.status = Stopped
  inst.clear_process()
  self.try_save_state(inst)
}

///|
/// Waiting out the restart delay. The process handle is already gone.
fn Supervisor::mark_restarting(
  self : Supervisor,
  inst : Instance,
  at_ms : UInt64,
) -> Unit {
  inst.status = Restarting
  inst.clear_process()
  inst.restart_at_ms = at_ms
  self.try_save_state(inst)
}

///|
/// Out of the crash budget, or parked on a condition that needs a config
/// or application fix. Stays visible in `bm2 list` for diagnosis and is
/// never restarted on its own.
fn Supervisor::mark_errored(
  self : Supervisor,
  inst : Instance,
  reason : String,
) -> Unit {
  inst.status = Errored
  inst.last_reason = Some(reason)
  inst.clear_process()
  inst.restart_at_ms = 0UL
  self.try_save_state(inst)
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
      terminate(app, inst, RestartFresh, "restart_requested")
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
  let (title, body) = render_msg(app.notify.lang, ProjectStopped(app_name))
  self.notify_project(
    app_name,
    "lifecycle",
    "info",
    title,
    body,
    "stopped|" + app_name,
  )
  for inst in self.app_instances(app_name) {
    inst.restart_at_ms = 0UL
    if inst.alive() {
      terminate(app, inst, Stop, "stop_requested")
    } else if !(inst.status is Errored) {
      inst.exit_intent = Stop
      self.mark_stopped(inst)
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
  let app = self.app_config(app_name)
  let (title, body) = render_msg(app.notify.lang, ProjectKilled(app_name))
  self.notify_project(
    app_name,
    "lifecycle",
    "info",
    title,
    body,
    "killed|" + app_name,
  )
  for inst in self.app_instances(app_name) {
    inst.restart_at_ms = 0UL
    if inst.alive() {
      inst.mark_stopping(Stop, "manual_kill")
      inst.kill_deadline_ms = 0UL
      @utils.discard(() => @proc.kill_group(inst.pid, @proc.SIGKILL))
    } else if !(inst.status is Errored) {
      inst.exit_intent = Stop
      self.mark_stopped(inst)
    }
  }
}
