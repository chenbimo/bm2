///|
/// Reap exited instances. Child processes report their exit code through
/// waitid(P_PIDFD); adopted (reparented) instances are not waitable
/// (ECHILD), so their exit is detected with the pidfd readability check
/// and recorded as an unknown exit.
fn Supervisor::reap(self : Supervisor) -> Unit {
  for pair in self.instances.iter() {
    let (name, arr) = pair
    // Both maps are written together, so a missing config means the
    // project is mid-removal and has nothing left to supervise.
    let app = match self.apps.get(name) {
      Some(app) => app
      None => continue
    }
    for inst in arr {
      if inst.pidfd > 0 {
        // Child processes (including zombies) are reaped by waitid.
        let reaped = try @proc.wait_pidfd(inst.pidfd, nohang=true) catch {
          _ => None
        } noraise {
          result => result
        }
        match reaped {
          Some((pid, exit)) => {
            @proc.close(inst.pidfd)
            inst.pidfd = 0
            self.handle_exit(app, inst, pid, Some(exit))
          }
          None =>
            // waitid reports nothing: alive, stopped, or an adopted
            // (non-waitable) instance, in which case the pidfd readability
            // check plus pid liveness is the only available exit signal.
            if @proc.pidfd_exited(inst.pidfd, inst.pid) {
              @proc.close(inst.pidfd)
              inst.pidfd = 0
              self.handle_exit(app, inst, inst.pid, None)
            }
        }
      }
    }
  }
}

///|
fn Supervisor::handle_exit(
  self : Supervisor,
  app : @config.Config,
  inst : Instance,
  pid : Int32,
  exit : @proc.ChildExit?,
) -> Unit {
  let now = @proc.monotonic_ms()
  match exit {
    None => {
      inst.last_exit_code = None
      inst.last_signal = None
    }
    Some(@proc.ChildExit::Exited(code)) => {
      inst.last_exit_code = Some(code)
      inst.last_signal = None
    }
    Some(@proc.ChildExit::Signaled(sig)) => {
      inst.last_exit_code = None
      inst.last_signal = Some(sig)
    }
  }
  let exit_detail = match exit {
    None => "unknown"
    Some(@proc.ChildExit::Exited(code)) => "exit_code=" + code.to_string()
    Some(@proc.ChildExit::Signaled(sig)) => "signal=" + signal_name(sig)
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
    Stop | RestartFresh =>
      // A reusePort violation lands in errored, not stopped: it needs a
      // config or app fix, and errored keeps the project listed for
      // diagnosis.
      if inst.last_reason == Some("reuseport_missing") {
        self.mark_errored(inst, "reuseport_missing")
      } else {
        self.mark_stopped(inst)
      }
    RestartCounted => {
      let reason = match inst.last_reason {
        Some(r) => r
        None => "terminated"
      }
      self.counted_exit(app, inst, now, reason)
    }
    Idle => {
      // Uptime is measured on the monotonic clock, so a system time change
      // can never make a fresh spawn look long-lived (or the reverse).
      let uptime = elapsed_mono_since(inst.started_mono_ms)
      let abnormal = match exit {
        Some(@proc.ChildExit::Exited(0)) =>
          uptime < app.min_uptime_ms.to_uint64()
        _ => true
      }
      if abnormal {
        let reason = match exit {
          Some(@proc.ChildExit::Exited(0)) => "quick_exit"
          Some(@proc.ChildExit::Exited(_)) => "exit_code"
          Some(@proc.ChildExit::Signaled(_)) => "signal"
          None => "terminated"
        }
        self.counted_exit(app, inst, now, reason)
      } else {
        // Clean self-exit after min_uptime: keep the service alive per plan,
        // and earn back the whole crash budget. This is the only place the
        // budget resets, which is what makes `max_restarts` mean "consecutive
        // abnormal restarts": an abnormal exit always counts, no matter how
        // long the instance had been up, so a process crashing on a period
        // longer than min_uptime can never launder its way out of the budget.
        inst.restart_count = 0
        let (title, body) = render_msg(app.notify.lang, CleanExitRestarting)
        self.notify_instance(inst, "lifecycle", "info", title, body)
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "instance_restart_scheduled",
          app=Some(inst.app_name),
          instance=inst.instance_id,
          detail="clean_exit",
        )
        self.mark_restarting(inst, now + app.restart_delay_ms.to_uint64())
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
  self.record_storm_hit(app.name, now)
  self.record_stats_restart(app.name)
  let detail = exit_detail(inst)
  let lang = app.notify.lang
  let cause = crash_cause(
    lang,
    reason,
    detail,
    app.exec_mode == "cluster" && @proc.probe_reuseport(inst.port) == 2,
  )
  if inst.restart_count > app.max_restarts {
    let (title, body) = render_msg(
      lang,
      ErroredStopped(cause, inst.restart_count, app.max_restarts),
    )
    self.notify_instance(inst, "errored", "error", title, body)
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "instance_errored",
      app=Some(inst.app_name),
      instance=inst.instance_id,
      detail=reason,
    )
    self.mark_errored(inst, reason)
  } else if reason != "memory_limit" &&
    is_oom_kill(inst.last_signal, inst.last_rss_kb, app.max_memory_mb) {
    let (title, body) = render_msg(
      lang,
      OomKill(cause, app.max_memory_mb, inst.restart_count, app.max_restarts),
    )
    self.notify_instance(inst, "oom_kill", "warn", title, body)
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "instance_restart_scheduled",
      app=Some(inst.app_name),
      instance=inst.instance_id,
      detail=reason,
    )
    self.mark_restarting(inst, now + app.restart_delay_ms.to_uint64())
  } else {
    let (title, body) = render_msg(
      lang,
      CrashRestarting(cause, inst.restart_count, app.max_restarts),
    )
    self.notify_instance(inst, "crash", "warn", title, body)
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "instance_restart_scheduled",
      app=Some(inst.app_name),
      instance=inst.instance_id,
      detail=reason,
    )
    self.mark_restarting(inst, now + app.restart_delay_ms.to_uint64())
  }
}

///|
/// SIGKILL with the last sampled RSS at 90%+ of the memory limit is, in
/// practice, the kernel OOM killer: the supervisor only SIGKILLs through its
/// own paths (which carry explicit reasons), and an app does not SIGKILL
/// itself right after growing near its limit.
pub fn is_oom_kill(sig : Int32?, rss_kb : Int32, max_memory_mb : Int32) -> Bool {
  sig == Some(9) &&
  rss_kb.to_int64() * 10L >= max_memory_mb.to_int64() * 1024L * 9L
}

///|
/// How far back restart-storm detection looks.
const STORM_WINDOW_MS : UInt64 = 600000UL

///|
/// Record a restart inside the storm window for a project. Pruning happens
/// here, on the write, so the per-project array stays bounded by what the
/// window holds. Deliberately independent of `[notify]`: an unbounded array
/// in a long-running daemon must not depend on whether alerts are configured.
fn Supervisor::record_storm_hit(
  self : Supervisor,
  app_name : String,
  now : UInt64,
) -> Unit {
  let hits = match self.storm_hits.get(app_name) {
    Some(hits) => hits
    None => {
      let fresh : Array[UInt64] = []
      self.storm_hits[app_name] = fresh
      fresh
    }
  }
  hits.push(now)
  ignore(storm_hit_count(hits, now, STORM_WINDOW_MS))
}

///|
/// Hits inside the storm window, pruning older entries in place.
fn storm_hit_count(
  hits : Array[UInt64],
  now : UInt64,
  window_ms : UInt64,
) -> Int32 {
  let fresh : Array[UInt64] = []
  let mut count = 0
  for ts in hits {
    if now >= ts && now - ts <= window_ms {
      fresh.push(ts)
      count += 1
    }
  }
  hits.clear()
  for ts in fresh {
    hits.push(ts)
  }
  count
}

///|
/// The exit shaped part of a message: "exit code 1" or "signal SIGKILL".
fn exit_detail(inst : Instance) -> String {
  match (inst.last_exit_code, inst.last_signal) {
    (Some(code), _) => ", exit code " + code.to_string()
    (None, Some(sig)) => ", signal " + signal_name(sig)
    _ => ""
  }
}
