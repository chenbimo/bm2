///|
fn Supervisor::reject_port_conflict(
  self : Supervisor,
  config : @config.Config,
) -> Unit raise {
  // cluster projects share one port (SO_REUSEPORT); fork projects
  // occupy consecutive ports.
  let start = config.port
  let end = if config.exec_mode == "cluster" {
    config.port
  } else {
    config.port + config.instances - 1
  }
  for pair in self.apps.iter() {
    let (_, other) = pair
    let other_end = if other.exec_mode == "cluster" {
      other.port
    } else {
      other.port + other.instances - 1
    }
    if other.name != config.name && start <= other_end && other.port <= end {
      raise PortConflict(
        "\{config.name} port range \{start}~\{end} overlaps \{other.name} \{other.port}~\{other_end}",
      )
    }
  }
}

///|
/// Ask the kernel whether cluster instances actually share their port:
/// bind the port with SO_REUSEPORT — joinable means the app listener
/// enables reusePort, EADDRINUSE means it does not. A missing reusePort
/// stops the whole project with every instance errored (reason
/// `reuseport_missing`) instead of letting later instances crash on
/// EADDRINUSE in confusing ways.
fn Supervisor::check_reuseport(self : Supervisor, now : UInt64) -> Unit {
  if now >= self.last_reuseport_probe_ms &&
    now - self.last_reuseport_probe_ms < REUSEPORT_PROBE_INTERVAL_MS {
    return
  }
  self.last_reuseport_probe_ms = now
  for pair in self.instances.iter() {
    let (name, arr) = pair
    let app = match self.apps.get(name) {
      Some(app) => app
      None => continue
    }
    if app.exec_mode != "cluster" {
      continue
    }
    for inst in arr {
      if !(inst.status is Online) || !(inst.reuseport is ReusePending) {
        continue
      }
      if inst.reuseport_deadline_ms == 0UL {
        inst.reuseport_deadline_ms = now + REUSEPORT_PROBE_TIMEOUT_MS
      }
      let rc = @proc.probe_reuseport(inst.port)
      if rc == 1 {
        inst.reuseport = ReuseOk
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "reuseport_confirmed",
          app=Some(name),
          instance=inst.instance_id,
          pid=inst.pid,
        )
      } else if rc == 2 {
        self.stop_for_reuseport(app, inst)
      } else if now >= inst.reuseport_deadline_ms || rc < 0 {
        // Never listened within the window (or the probe itself failed):
        // not a violation, just stop probing.
        inst.reuseport = ReuseOff
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "reuseport_probe_stopped",
          app=Some(name),
          instance=inst.instance_id,
          detail="probe rc=" + rc.to_string(),
        )
      }
    }
  }
}

///|
/// The listener holds the port exclusively: stop every instance of the
/// project, errored with a concrete reason; the registration stays so a
/// fixed app simply runs `bm2 start` again.
fn Supervisor::stop_for_reuseport(
  self : Supervisor,
  app : @config.Config,
  trigger : Instance,
) -> Unit {
  log_event(
    self.state_dir,
    "bm2d.events.jsonl",
    "reuseport_missing",
    app=Some(app.name),
    instance=trigger.instance_id,
    pid=trigger.pid,
    detail="cluster mode requires the listener to enable reusePort",
  )
  let (title, body) = render_msg(
    app.notify.lang,
    ReuseportMissing(app.name, app.port),
  )
  self.notify_project(
    app.name,
    "reuseport_missing",
    "error",
    title,
    body,
    "reuseport_missing|" + app.name,
  )
  match self.projects.get(app.name) {
    Some(project) => project.restarting = false
    None => ()
  }
  match self.instances.get(app.name) {
    Some(arr) =>
      for inst in arr {
        inst.reuseport = ReuseExclusive
        inst.restart_at_ms = 0UL
        self.write_crash(inst, "reuseport_missing")
        if inst.alive() {
          terminate(app, inst, Stop, "reuseport_missing")
        } else if !(inst.status is Errored) {
          self.mark_errored(inst, "reuseport_missing")
        }
      }
    None => ()
  }
}

///|
fn Supervisor::check_memory(self : Supervisor) -> Unit {
  for pair in self.instances.iter() {
    let (name, arr) = pair
    let app = match self.apps.get(name) {
      Some(app) => app
      None => continue
    }
    for inst in arr {
      if inst.status is Online {
        match @proc.read_rss_kb(inst.pid) {
          Some(kb) => {
            self.notify.record_rss(
              inst.app_name + "/" + inst.instance_id.to_string(),
              kb,
            )
            self.record_stats_peak(inst.app_name, kb)
            if kb.to_int64() > app.max_memory_mb.to_int64() * 1024L {
              inst.last_rss_kb = kb
              log_event(
                self.state_dir,
                "bm2d.events.jsonl",
                "memory_limit",
                app=Some(inst.app_name),
                instance=inst.instance_id,
                pid=inst.pid,
                detail="rss_kb=" + kb.to_string(),
              )
              let (title, body) = render_msg(
                app.notify.lang,
                MemoryLimit(kb / 1024, app.max_memory_mb),
              )
              self.notify_instance(inst, "memory_limit", "warn", title, body)
              // Over the limit counts as an abnormal exit: it restarts
              // against the crash budget via the RestartCounted intent.
              terminate(app, inst, RestartCounted, "memory_limit")
            } else {
              self.notify_memory_pressure(inst, kb)
            }
          }
          None => ()
        }
      }
    }
  }
}
