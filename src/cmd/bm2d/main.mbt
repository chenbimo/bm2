///|
/// bm2 is Linux-only; refuse to run elsewhere with a clear message
/// instead of failing on the first POSIX-specific syscall.
/// Returns None when the platform is supported.
fn platform_error() -> String? {
  try {
    let name = @process.uname()
    if name == "Linux" {
      None
    } else {
      Some("this build supports Linux only (detected: \{name})")
    }
  } catch {
    e => Some("cannot detect platform: \{e.to_string()}")
  } noraise {
    ok => ok
  }
}

///|
enum Exit {
  Stay
  /// Bare `kill` or SIGTERM: stop all apps, then exit.
  Shutdown
  /// `refresh`: detach without stopping apps; the CLI starts a fresh bm2d
  /// which adopts the surviving instances.
  Detach
}

///|
fn main {
  @process.exit(run())
}

///|
fn run() -> Int {
  match platform_error() {
    None => ()
    Some(msg) => {
      @process.eprintln("bm2d: " + msg)
      return 1
    }
  }
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
  @core.discard(() => @process.mkdir_p(state_dir, mode=0o700))
  // One daemon per state directory: the flock is released automatically
  // when the holder exits, even on SIGKILL, so a crash never leaves a
  // permanent lock behind.
  let _lock_fd = try @process.lock_exclusive(state_dir + "/bm2d.lock") catch {
    _ => {
      @process.eprintln("bm2d: another daemon is already running")
      return 1
    }
  } noraise {
    fd => fd
  }
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
  @process.install_term_handler()
  let listen_fd = try @process.socket_listen(state_dir + "/bm2.sock") catch {
    e => {
      @process.eprintln("bm2d: " + e.to_string())
      return 2
    }
  } noraise {
    fd => fd
  }
  // Only claim the pid file once the socket is bound: a daemon that
  // fails to bind must not overwrite the pid of a live daemon.
  @core.discard(() => {
    @process.write_atomic(
      state_dir + "/bm2d.pid",
      @utf8.encode(@process.get_pid().to_string() + "\n"),
    )
  })
  // Remember the config path so list/kill/refresh can auto-restore the
  // daemon from any directory. Deleted on explicit shutdown, kept on
  // crashes so a dead daemon can be revived.
  @core.discard(() => {
    @process.write_atomic(
      state_dir + "/bm2d.config",
      @utf8.encode(config_path + "\n"),
    )
  })
  @core.log_event(state_dir, "bm2d.events.jsonl", "socket_listening")
  let mut exit_mode = Exit::Shutdown
  while !@process.term_requested() {
    sv.tick()
    let readable = try @process.poll_fd(listen_fd, 50) catch {
      _ => false
    } noraise {
      ready => ready
    }
    if readable {
      let mode = serve(listen_fd, sv, config_path, state_dir)
      match mode {
        Exit::Stay => ()
        _ => {
          exit_mode = mode
          break
        }
      }
    }
  }
  match exit_mode {
    Exit::Detach => {
      @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_detaching")
      @process.close(listen_fd)
      @core.discard(() => @process.unlink(state_dir + "/bm2.sock"))
      @core.discard(() => @process.unlink(state_dir + "/bm2d.pid"))
      @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_detached")
    }
    _ => {
      @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_stopping")
      shutdown(sv, listen_fd, state_dir, @process.term_requested())
      // Explicit shutdown: forget the config so list/kill/refresh do not
      // silently revive a daemon the user deliberately stopped.
      @core.discard(() => @process.unlink(state_dir + "/bm2d.config"))
      @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_stopped")
    }
  }
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
      @core.discard(() => sv.stop_app(name))
    } else {
      @core.discard(() => sv.kill_app(name))
    }
  }
  if graceful {
    ignore(sv.wait_settled(names))
  } else {
    sv.tick()
  }
  for inst in sv.snapshot() {
    if inst.alive() {
      @core.discard(() => @process.kill_group(inst.pid, @process.SIGKILL))
    }
  }
  @process.close(listen_fd)
  @core.discard(() => @process.unlink(state_dir + "/bm2.sock"))
  @core.discard(() => @process.unlink(state_dir + "/bm2d.pid"))
}

///|
/// Serve one queued connection; the request loop stays single threaded
/// so all supervisor mutations are serialized. Exit requests (kill/refresh)
/// are honored only after their success response has reached the caller.
fn serve(
  listen_fd : Int,
  sv : @core.Supervisor,
  config_path : String,
  state_dir : String,
) -> Exit {
  let fd = try @process.accept(listen_fd) catch {
    _ => return Exit::Stay
  } noraise {
    accepted => accepted
  }
  // A client that connects and stays silent must not freeze the
  // single-threaded loop; drop it after five seconds.
  let readable = try @process.poll_fd(fd, 5000) catch {
    _ => false
  } noraise {
    ready => ready
  }
  if !readable {
    @process.close(fd)
    return Exit::Stay
  }
  let (response, exit) = handle(fd, sv, config_path, state_dir)
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
  if sent {
    exit
  } else {
    Exit::Stay
  }
}

///|
fn handle(
  fd : Int,
  sv : @core.Supervisor,
  config_path : String,
  state_dir : String,
) -> (@core.Response, Exit) {
  let peer = try @process.peer_uid(fd) catch {
    _ => -1
  } noraise {
    uid => uid
  }
  if peer != @process.get_uid() {
    return (
      @core.Response::error("permission denied: same-user only"),
      Exit::Stay,
    )
  }
  let req = try @core.decode_request(@process.recv_msg(fd)) catch {
    _ => return (@core.Response::error("invalid request"), Exit::Stay)
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
    "list" => (cmd_list(sv, req.app), Exit::Stay)
    "start" => (cmd_start(sv, req.app, config_path), Exit::Stay)
    "kill" => cmd_kill(sv, req.app)
    "refresh" => cmd_refresh()
    _ => (@core.Response::error("unknown command: " + req.command), Exit::Stay)
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
fn cmd_kill(sv : @core.Supervisor, app : String?) -> (@core.Response, Exit) {
  match app {
    None => (@core.Response::ok("bm2d stopping", []), Exit::Shutdown)
    Some(name) => {
      try sv.kill_app(name) catch {
        e => return (@core.Response::error(e.to_string()), Exit::Stay)
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
        Exit::Stay,
      )
    }
  }
}

///|
/// Refresh detaches bm2d without stopping apps; the CLI then starts a fresh
/// daemon which adopts the surviving instances.
fn cmd_refresh() -> (@core.Response, Exit) {
  (@core.Response::ok("refreshing", []), Exit::Detach)
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
