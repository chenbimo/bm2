///|
/// Reconcile on-disk state with live processes after a bm2d restart.
/// For every recorded instance: adopt it when the pid is alive and its
/// cmdline matches the configured bun script; delete the state file when
/// the pid is gone; mark pid_conflict (never signal the process) when a
/// different program occupies the pid.
pub fn Supervisor::recover(self : Supervisor) -> Unit {
  for pair in self.instances.iter() {
    let (name, arr) = pair
    let app = self.apps[name]
    for inst in arr {
      let path = state_path(self.state_dir, name, inst.instance_id)
      if !@fs.path_exists(path) {
        // Never started under a previous daemon: nothing to reconcile.
        continue
      }
      let state = try load_state(path) catch {
        e => {
          // Corrupt state can never be reconciled; remove it so it stops
          // blocking future recoveries with repeated noise.
          discard(() => @process.unlink(path))
          log_event(
            self.state_dir,
            "bm2d.events.jsonl",
            "state_load_failed",
            app=Some(name),
            instance=inst.instance_id,
            detail=e.to_string(),
          )
          continue
        }
      } noraise {
        loaded => loaded
      }
      if state.pid <= 0 || !@process.pid_alive(state.pid) {
        discard(() => @process.unlink(path))
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "state_discarded",
          app=Some(name),
          instance=inst.instance_id,
          pid=state.pid,
          detail="pid_not_alive",
        )
        continue
      }
      // Pin the recorded process with a pidfd before trusting the pid:
      // a pid that was reused by an unrelated process must never be managed.
      let pidfd = try @process.pidfd_open(state.pid) catch {
        _ => {
          discard(() => @process.unlink(path))
          log_event(
            self.state_dir,
            "bm2d.events.jsonl",
            "state_discarded",
            app=Some(name),
            instance=inst.instance_id,
            pid=state.pid,
            detail="pidfd_open_failed",
          )
          continue
        }
      } noraise {
        fd => fd
      }
      inst.pid = state.pid
      inst.pidfd = pidfd
      let cmdline = try
        @process.read_small("/proc/\{state.pid}/cmdline")
      catch {
        _ => {
          @process.close(pidfd)
          inst.pidfd = 0
          self.mark_pid_conflict(inst)
          continue
        }
      } noraise {
        data => data
      }
      let text = @utf8.decode_lossy(cmdline)
      if text.contains("bun") && text.contains(app.script) {
        inst.status = Online
        inst.started_at_ms = now_ms()
        inst.restart_count = state.restart_count
        discard(() => save_state(self.state_dir, inst))
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "instance_adopted",
          app=Some(name),
          instance=inst.instance_id,
          pid=state.pid,
        )
      } else {
        @process.close(pidfd)
        inst.pidfd = 0
        self.mark_pid_conflict(inst)
      }
    }
  }
}

///|
/// A foreign process holds the recorded pid: record the conflict and
/// leave that process untouched.
fn Supervisor::mark_pid_conflict(self : Supervisor, inst : Instance) -> Unit {
  inst.status = Errored
  inst.last_reason = Some("pid_conflict")
  self.write_crash(inst, "pid_conflict")
  log_event(
    self.state_dir,
    "bm2d.events.jsonl",
    "pid_conflict",
    app=Some(inst.app_name),
    instance=inst.instance_id,
    pid=inst.pid,
  )
  inst.pid = 0
  discard(() => save_state(self.state_dir, inst))
}
