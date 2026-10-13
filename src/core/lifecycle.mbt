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
  inst.started_mono_ms = @proc.monotonic_ms()
  inst.times += 1
  inst.exit_intent = Idle
  inst.kill_deadline_ms = 0UL
  inst.restart_at_ms = 0UL
  inst.last_reason = None
  // Each generation samples its own RSS: without this the OOM heuristic could
  // compare a SIGKILL against a peak from the generation before it.
  inst.last_rss_kb = 0
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
  // Starting a project is also how a stopped one resumes: clearing the mark is
  // what puts it back under supervision, and the persisted copy has to follow, or
  // the next daemon restart would stop it again.
  let was_stopped = self.is_stopped(app_name)
  match self.projects.get(app_name) {
    Some(project) => project.stopped = false
    None => ()
  }
  if was_stopped {
    match self.projects.get(app_name) {
      Some(project) =>
        @utils.discard(() => {
          save_project(self.state_dir, app_name, {
            config_path: project.config_path,
            stopped: false,
          })
        })
      None => ()
    }
  }
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
/// Retire a project: hard (- `force`) or graceful. Either way it is marked manual
/// and never auto-restarted, and queued for removal once every instance has
/// stopped, so a retired project never comes back after a daemon restart.
pub fn Supervisor::remove_app(
  self : Supervisor,
  app_name : String,
  force~ : Bool = false,
) -> Unit raise {
  self.pending_restart.remove(app_name)
  match self.projects.get(app_name) {
    Some(project) => project.removing = true
    None => ()
  }
  let app = self.app_config(app_name)
  let (title, body) = render_msg(
    app.notify.lang,
    if force {
      ProjectKilled(app_name)
    } else {
      ProjectStopped(app_name)
    },
  )
  self.notify_project(
    app_name,
    "lifecycle",
    "info",
    title,
    body,
    "removed|" + app_name,
  )
  for inst in self.app_instances(app_name) {
    inst.restart_at_ms = 0UL
    if inst.alive() {
      inst.mark_stopping(
        Stop,
        if force {
          "manual_kill"
        } else {
          "manual_remove"
        },
      )
      if force {
        inst.kill_deadline_ms = 0UL
        @utils.discard(() => @proc.kill_group(inst.pid, @proc.SIGKILL))
      } else {
        // Graceful: SIGTERM now, and the tick's escalation behind it if the app
        // is still there when its own stop timeout runs out.
        inst.kill_deadline_ms = @proc.monotonic_ms() +
          app.stop_timeout_ms.to_uint64()
        @utils.discard(() => @proc.kill_group(inst.pid, @proc.SIGTERM))
      }
    } else if !(inst.status is Errored) {
      inst.exit_intent = Stop
      self.mark_stopped(inst)
    }
  }
}

///|
/// Stop a project on purpose: `stop_app` takes the instances down politely and
/// marks them stopped, and the mark recorded here is what keeps supervision from
/// bringing them back. It is persisted with the project, so a stopped project
/// stays stopped across a daemon restart — which is the whole difference between
/// `stop` and a pause until the next reload. Only `bm2 start` clears it.
pub fn Supervisor::pause_app(
  self : Supervisor,
  app_name : String,
) -> Unit raise {
  self.stop_app(app_name)
  match self.projects.get(app_name) {
    Some(project) => project.stopped = true
    None => ()
  }
  match self.projects.get(app_name) {
    Some(project) =>
      @utils.discard(() => {
        save_project(self.state_dir, app_name, {
          config_path: project.config_path,
          stopped: true,
        })
      })
    None => ()
  }
}
