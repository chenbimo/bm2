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
  let state_dir = @core.resolve_state_dir()
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
    if readable && serve(listen_fd, sv, config_path, state_dir) {
      break
    }
  }
  @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_stopping")
  shutdown(sv, listen_fd, state_dir, @process.term_requested())
  @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_stopped")
  0
}

///|
/// The bare `kill` request forces every managed process group down before
/// bm2d exits. SIGTERM to bm2d keeps the existing graceful shutdown path.
fn shutdown(
  sv : @core.Supervisor,
  listen_fd : Int,
  state_dir : String,
  graceful : Bool,
) -> Unit {
  let names = sv.app_names()
  for name in names {
    if graceful {
      discard(() => sv.stop_app(name))
    } else {
      discard(() => sv.kill_app(name))
    }
  }
  if graceful {
    ignore(sv.wait_settled(names))
  } else {
    sv.tick()
  }
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
/// so all supervisor mutations are serialized. Bare `kill` exits only after
/// its success response has been written to the caller.
fn serve(
  listen_fd : Int,
  sv : @core.Supervisor,
  config_path : String,
  state_dir : String,
) -> Bool {
  let fd = try @process.accept(listen_fd) catch {
    _ => return false
  } noraise {
    accepted => accepted
  }
  let (response, shutdown_requested) = handle(fd, sv, config_path, state_dir)
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
  sent && shutdown_requested
}

///|
fn handle(
  fd : Int,
  sv : @core.Supervisor,
  config_path : String,
  state_dir : String,
) -> (@core.Response, Bool) {
  let peer = try @process.peer_uid(fd) catch {
    _ => -1
  } noraise {
    uid => uid
  }
  if peer != @process.get_uid() {
    return (@core.Response::error("permission denied: same-user only"), false)
  }
  let req = try @core.decode_request(@process.recv_msg(fd)) catch {
    _ => return (@core.Response::error("invalid request"), false)
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
    "list" => (cmd_list(sv, req.app), false)
    "start" => (cmd_start(sv, req.app, config_path), false)
    "kill" => cmd_kill(sv, req.app)
    _ => (@core.Response::error("unknown command: " + req.command), false)
  }
}

///|
fn cmd_list(sv : @core.Supervisor, app : String?) -> @core.Response {
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
/// Kill an app immediately, or request a complete bm2d shutdown when no app
/// name was supplied. The daemon loop performs the all-app kill after reply.
fn cmd_kill(sv : @core.Supervisor, app : String?) -> (@core.Response, Bool) {
  match app {
    None => (@core.Response::ok("bm2d stopping", []), true)
    Some(name) => {
      try sv.kill_app(name) catch {
        e => return (@core.Response::error(e.to_string()), false)
      } noraise {
        _ => ()
      }
      let settled = sv.wait_settled([name])
      (
        @core.Response::ok(
          if settled {
            "killed"
          } else {
            "killed (timeout)"
          },
          infos_of(sv, [name]),
        ),
        false,
      )
    }
  }
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
/// List output excludes intentionally stopped instances. Other statuses,
/// especially restarting and errored, remain visible for operational diagnosis.
fn infos_of(
  sv : @core.Supervisor,
  names : Array[String],
) -> Array[@core.InstanceInfo] {
  let now = @core.now_ms()
  let infos = []
  for name in names {
    try {
      for inst in sv.app_instances(name) {
        if !(inst.status is @core.Status::Stopped) {
          infos.push(@core.InstanceInfo::of(inst, now))
        }
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
