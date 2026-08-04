///|
/// Load every registered project (project.json under the state dir) so a
/// restarted daemon can adopt still-running instances. Projects whose
/// config file is gone are skipped with an event; they are never started.
pub fn Supervisor::load_projects(self : Supervisor) -> Unit {
  let entries = try @fs.read_dir(self.state_dir) catch {
    _ => return
  } noraise {
    found => found
  }
  for entry in entries {
    let info = try
      load_project("\{self.state_dir}/\{entry}/project.json")
    catch {
      _ => continue
    } noraise {
      loaded => loaded
    }
    let config = try @config.load(info.config_path) catch {
      e => {
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "project_load_failed",
          app=Some(entry),
          detail=e.to_string(),
        )
        continue
      }
    } noraise {
      loaded => loaded
    }
    try self.register(config, info.config_path) catch {
      e =>
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "project_load_failed",
          app=Some(entry),
          detail=e.to_string(),
        )
    } noraise {
      _ => ()
    }
  }
}

///|
/// Reconcile on-disk state with live processes after a bm2d restart.
/// For every recorded instance: adopt it when the pid is alive and its
/// environment carries bm2's reserved variables; delete the state file
/// when the pid is gone; mark pid_conflict (never signal the process)
/// when a different program occupies the pid.
pub fn Supervisor::recover(self : Supervisor) -> Unit {
  for pair in self.instances.iter() {
    let (name, arr) = pair
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
      // The pidfd proves the pid is the original recorded process; the
      // environment proves it is actually a bm2-spawned instance: only bm2
      // writes the reserved BM2_* variables, so a foreign process (or one
      // started manually with the same script) is never adopted.
      let environ = try
        @process.read_small("/proc/\{state.pid}/environ", cap=131072)
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
      if env_matches(environ, inst) {
        inst.status = Online
        inst.started_at_ms = now_ms()
        inst.times = state.times.unwrap_or(0)
        inst.restart_count = state.restart_count
        self.try_save_state(inst)
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
/// True when the environment carries exactly the reserved variables bm2
/// writes for one instance. A manually started process cannot have them.
fn env_matches(environ : Bytes, inst : Instance) -> Bool {
  let entries = @utf8.decode_lossy(environ).split("\u{0}")
  entries.contains("BM2_APP_NAME=" + inst.app_name) &&
  entries.contains("BM2_INSTANCE_ID=" + inst.instance_id.to_string()) &&
  entries.contains("BM2_APP_PORT=" + inst.port.to_string())
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
  self.try_save_state(inst)
}
