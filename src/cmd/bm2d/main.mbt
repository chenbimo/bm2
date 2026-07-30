///|
fn main {
  @process.exit(run())
}

///|
fn run() -> Int {
  let args = @env.args()
  if args.length() != 2 {
    @process.eprintln("usage: bm2d <config-path>")
    return 2
  }
  let config_path = args[1]
  let config = try @config.load(config_path) catch {
    e => {
      @process.eprintln("bm2d: " + e.to_string())
      return 2
    }
  } noraise {
    loaded => loaded
  }
  let state_dir = @core.resolve_state_dir(config.state_dir)
  @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_starting")
  let sv = try @core.Supervisor::new(config, state_dir~, bun_path="bun") catch {
    e => {
      @process.eprintln("bm2d: " + e.to_string())
      return 2
    }
  } noraise {
    created => created
  }
  sv.recover()
  @core.log_event(state_dir, "bm2d.events.jsonl", "recovery_complete")
  discard(() => {
    @process.write_atomic(
      state_dir + "/bm2d.pid",
      @utf8.encode(@process.get_pid().to_string() + "\n"),
    )
  })
  @process.install_term_handler()
  let listen_fd = try @process.socket_listen(state_dir + "/bm2.sock") catch {
    e => {
      @process.eprintln("bm2d: " + e.to_string())
      return 2
    }
  } noraise {
    fd => fd
  }
  @core.log_event(state_dir, "bm2d.events.jsonl", "socket_listening")
  while !@process.term_requested() {
    sv.tick()
    let readable = try @process.poll_fd(listen_fd, 50) catch {
      _ => false
    } noraise {
      ready => ready
    }
    if readable {
      serve(listen_fd, sv, config_path, state_dir)
    }
  }
  @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_stopping")
  shutdown(sv, listen_fd, state_dir)
  @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_stopped")
  0
}

///|
/// SIGTERM received: stop every app, wait for the SIGKILL escalation to
/// finish, sweep anything left and remove the socket and pid file.
fn shutdown(sv : @core.Supervisor, listen_fd : Int, state_dir : String) -> Unit {
  let names = sv.app_names()
  for name in names {
    discard(() => sv.stop_app(name))
  }
  ignore(sv.wait_settled(names))
  for inst in sv.snapshot() {
    if inst.alive() {
      discard(() => @process.kill_group(inst.pid, @process.SIGKILL))
    }
  }
  @process.close(listen_fd)
  discard(() => @process.unlink(state_dir + "/bm2.sock"))
  discard(() => @process.unlink(state_dir + "/bm2d.pid"))
}

///|
/// Serve one queued connection; the request loop stays single threaded
/// so all supervisor mutations are serialized.
fn serve(
  listen_fd : Int,
  sv : @core.Supervisor,
  config_path : String,
  state_dir : String,
) -> Unit {
  let fd = try @process.accept(listen_fd) catch {
    _ => return
  } noraise {
    accepted => accepted
  }
  let response = handle(fd, sv, config_path, state_dir)
  let sent = try {
    @process.send_msg(fd, @core.encode_response(response))
    true
  } catch {
    _ => false
  } noraise {
    ok => ok
  }
  @core.log_event(
    state_dir,
    "bm2d.events.jsonl",
    if sent {
      "response_sent"
    } else {
      "response_failed"
    },
  )
  @process.close(fd)
}

///|
fn handle(
  fd : Int,
  sv : @core.Supervisor,
  config_path : String,
  state_dir : String,
) -> @core.Response {
  let peer = try @process.peer_uid(fd) catch {
    _ => -1
  } noraise {
    uid => uid
  }
  if peer != @process.get_uid() {
    return @core.Response::error("permission denied: same-user only")
  }
  let req = try @core.decode_request(@process.recv_msg(fd)) catch {
    _ => return @core.Response::error("invalid request")
  } noraise {
    parsed => parsed
  }
  @core.log_event(
    state_dir,
    "bm2d.events.jsonl",
    "request_received",
    app=req.app,
    detail=req.command,
  )
  match req.command {
    "status" => cmd_status(sv, req.app)
    "start" => cmd_start(sv, req.app, config_path)
    "stop" => cmd_stop(sv, req.app, true)
    "kill" => cmd_stop(sv, req.app, false)
    _ => @core.Response::error("unknown command: " + req.command)
  }
}

///|
fn cmd_status(sv : @core.Supervisor, app : String?) -> @core.Response {
  let names = try targets(sv, app) catch {
    e => return @core.Response::error(e.to_string())
  } noraise {
    found => found
  }
  @core.Response::ok("ok", infos_of(sv, names))
}

///|
/// Every start re-reads the config from disk so `bm2 start` always
/// reflects the current bm2.toml, then performs a full restart.
fn cmd_start(
  sv : @core.Supervisor,
  app : String?,
  config_path : String,
) -> @core.Response {
  let config = try @config.load(config_path) catch {
    e => return @core.Response::error(e.to_string())
  } noraise {
    loaded => loaded
  }
  try sv.reload(config) catch {
    e => return @core.Response::error(e.to_string())
  } noraise {
    _ => ()
  }
  let names = try targets(sv, app) catch {
    e => return @core.Response::error(e.to_string())
  } noraise {
    found => found
  }
  for name in names {
    try sv.start_app(name) catch {
      e => return @core.Response::error(e.to_string())
    } noraise {
      _ => ()
    }
  }
  let settled = sv.wait_settled(names)
  @core.Response::ok(
    if settled {
      "started"
    } else {
      "start timed out"
    },
    infos_of(sv, names),
  )
}

///|
fn cmd_stop(
  sv : @core.Supervisor,
  app : String?,
  graceful : Bool,
) -> @core.Response {
  let names = try targets(sv, app) catch {
    e => return @core.Response::error(e.to_string())
  } noraise {
    found => found
  }
  for name in names {
    try {
      if graceful {
        sv.stop_app(name)
      } else {
        sv.kill_app(name)
      }
    } catch {
      e => return @core.Response::error(e.to_string())
    } noraise {
      _ => ()
    }
  }
  let settled = sv.wait_settled(names)
  let verb = if graceful { "stopped" } else { "killed" }
  @core.Response::ok(
    if settled {
      verb
    } else {
      verb + " (timeout)"
    },
    infos_of(sv, names),
  )
}

///|
/// Resolve the optional app filter to concrete app names, verifying that
/// a named app exists.
fn targets(sv : @core.Supervisor, app : String?) -> Array[String] raise {
  match app {
    Some(name) => {
      ignore(sv.app_instances(name))
      [name]
    }
    None => sv.app_names()
  }
}

///|
fn infos_of(
  sv : @core.Supervisor,
  names : Array[String],
) -> Array[@core.InstanceInfo] {
  let now = @core.now_ms()
  let infos = []
  for name in names {
    try {
      for inst in sv.app_instances(name) {
        infos.push(@core.InstanceInfo::of(inst, now))
      }
    } catch {
      _ => ()
    } noraise {
      _ => ()
    }
  }
  infos
}

///|
/// Run a side effect whose failure must not abort request handling.
fn discard(f : () -> Unit raise) -> Unit {
  try f() catch {
    _ => ()
  } noraise {
    _ => ()
  }
}
