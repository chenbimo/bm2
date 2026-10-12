///|
enum Exit {
  Stay
  /// Bare `kill` or SIGTERM: stop all apps, then exit.
  Shutdown
  /// `reload`: detach without stopping apps; the CLI starts a fresh bm2d
  /// which adopts the surviving instances.
  Detach
}

///|
async fn main {
  @proc.exit(run())
}

///|
async fn run() -> Int32 {
  match @proc.platform_error() {
    None => ()
    Some(msg) => {
      @proc.eprintln("bm2d: " + msg)
      return 1
    }
  }
  // The daemon takes no arguments: registered projects live under the
  // state dir and are loaded on startup (see load_projects).
  if @env.args().length() != 1 {
    @proc.eprintln("usage: bm2d")
    return 2
  }
  let state_dir = @core.resolve_state_dir()
  @util.discard(() => @fsx.mkdir_p(state_dir, mode=0o700))
  // One daemon per state directory: the flock is released automatically
  // when the holder exits, even on SIGKILL, so a crash never leaves a
  // permanent lock behind.
  let _lock_fd = try @fsx.lock_exclusive(state_dir + "/bm2d.lock") catch {
    _ => {
      @proc.eprintln("bm2d: another daemon is already running")
      return 1
    }
  } noraise {
    fd => fd
  }
  // A control socket from a previous generation is stale by definition.
  @util.discard(() => @fsx.unlink(state_dir + "/bm2.sock"))
  @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_starting")
  let sv = try @core.Supervisor::new(state_dir~, bun_path="bun") catch {
    e => {
      @proc.eprintln("bm2d: " + e.to_string())
      return 2
    }
  } noraise {
    created => created
  }
  // Restore registered projects and adopt their still-running instances.
  // Nothing is ever started automatically: projects only run after an
  // explicit `bm2 start`.
  sv.load_projects()
  sv.recover()
  @core.log_event(state_dir, "bm2d.events.jsonl", "recovery_complete")
  // Tell each project's own targets that the daemon is up and what it
  // inherited; a reload or an upgrade lands here too, so this doubles as the
  // "swap finished" notice.
  for name in sv.app_names() {
    sv.notify_daemon_started(name)
  }
  // SIGTERM/SIGINT cancel the async runtime; the shutdown path below treats
  // a cancelled run as the graceful (stop-then-exit) path.
  @signal.set_global_cancellation_signals([
    @signal.Signal::SIGTERM,
    @signal.Signal::SIGINT,
  ])
  // Control plane: loopback TCP, port recorded in the state dir, access
  // gated by a per-daemon shared token (0600 dir, so file reads are
  // owner-only — same trust model as the old unix socket, minus SO_PEERCRED).
  let server = try
    @socket.TcpServer::TcpServer(@socket.Addr::new(2130706433U, 0))
  catch {
    e => {
      @proc.eprintln("bm2d: " + e.to_string())
      return 2
    }
  } noraise {
    bound => bound
  }
  let port = server.addr.port()
  let token = try @ipc.generate_token() catch {
    _ => {
      @proc.eprintln("bm2d: cannot generate the access token")
      server.close()
      return 2
    }
  } noraise {
    generated => generated
  }
  let ok = try {
    @fsx.write_atomic(
      state_dir + "/" + @ipc.PORT_FILE,
      @utf8.encode(port.to_string() + "\n"),
    )
    @fsx.write_atomic(state_dir + "/" + @ipc.TOKEN_FILE, @utf8.encode(token))
    true
  } catch {
    _ => false
  } noraise {
    written => written
  }
  if !ok {
    @proc.eprintln("bm2d: cannot write the control-plane files")
    server.close()
    return 2
  }
  // Only claim the pid file once the control endpoint is up: a daemon that
  // fails to bind must not overwrite the pid of a live daemon.
  @util.discard(() => {
    @fsx.write_atomic(
      state_dir + "/bm2d.pid",
      @utf8.encode(@proc.get_pid().to_string() + "\n"),
    )
  })
  @core.log_event(state_dir, "bm2d.events.jsonl", "socket_listening")
  // The accept loop runs as the group body; the supervision tick is a child
  // task. An exit request (or SIGTERM) ends the group and lands in the
  // shutdown paths below.
  let outcome = @async.handle_cancellation(async fn() {
    @async.with_task_group(async fn(tg) {
      ignore(tg.spawn(async fn() { tick_loop(sv) }))
      let mode = accept_loop(server, sv, state_dir, token)
      tg.return_immediately(mode)
      mode
    })
  })
  match outcome {
    Some(Exit::Detach) => {
      @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_detaching")
      server.close()
      @util.discard(() => @fsx.unlink(state_dir + "/" + @ipc.PORT_FILE))
      @util.discard(() => @fsx.unlink(state_dir + "/" + @ipc.TOKEN_FILE))
      @util.discard(() => @fsx.unlink(state_dir + "/bm2d.pid"))
      @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_detached")
    }
    Some(Exit::Shutdown) => {
      @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_stopping")
      server.close()
      shutdown(sv, state_dir, false)
      @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_stopped")
    }
    // SIGTERM/SIGINT: graceful stop of every app, then exit.
    None => {
      @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_stopping")
      server.close()
      shutdown(sv, state_dir, true)
      @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_stopped")
    }
    Some(Exit::Stay) =>
      // Unreachable: accept_loop never returns Stay.
      ()
  }
  0
}

///|
/// Supervision heartbeat: the same 50ms cadence as the old poll loop, now a
/// timer inside the async runtime. Timer cancellation is what unwinds this
/// task when the daemon exits.
async fn tick_loop(sv : @core.Supervisor) -> Unit {
  while true {
    let timer = @async.Timer::Timer(50)
    timer.wait()
    sv.tick()
  }
}

///|
/// Accept and serve connections until an exit request arrives. Cancellation
/// unwinds the blocked accept without touching the catch; per-connection
/// failures never kill the daemon.
async fn accept_loop(
  server : @socket.TcpServer,
  sv : @core.Supervisor,
  state_dir : String,
  token : String,
) -> Exit {
  while true {
    let conn = try @ipc.accept_authed(server, token) catch {
      _ => None
    } noraise {
      accepted => accepted
    }
    match conn {
      None => {
        // A rejected handshake is a wrong token or a probe: worth a line in
        // the event log either way.
        @core.log_event(state_dir, "bm2d.events.jsonl", "auth_failed")
        continue
      }
      Some(conn) =>
        match serve_conn(conn, sv, state_dir) {
          Some(mode) => return mode
          None => ()
        }
    }
  }
  Exit::Shutdown
}

///|
/// Serve one connection; requests stay sequential so all supervisor
/// mutations are serialized exactly as in the poll-loop daemon. Exit
/// requests (kill/reload) are honored only after their success response
/// has reached the caller.
async fn serve_conn(
  conn : @socket.Tcp,
  sv : @core.Supervisor,
  state_dir : String,
) -> Exit? {
  let (response, exit) = match @ipc.read_request(conn) {
    Some(req) =>
      match @core.protocol_problem(req.protocol) {
        Some(problem) => (@core.Response::error(problem), Exit::Stay)
        None => {
          @core.log_event(
            state_dir,
            "bm2d.events.jsonl",
            "request_received",
            app=req.app,
            detail=req.command,
          )
          dispatch(sv, req)
        }
      }
    None => (@core.Response::error("invalid request"), Exit::Stay)
  }
  let sent = try {
    @ipc.write_response(conn, response)
    true
  } catch {
    _ => false
  } noraise {
    sent => sent
  }
  conn.close()
  @core.log_event(
    state_dir,
    "bm2d.events.jsonl",
    if sent {
      "response_sent"
    } else {
      "response_failed"
    },
  )
  if sent && !(exit is Exit::Stay) {
    Some(exit)
  } else {
    None
  }
}

///|
async fn dispatch(
  sv : @core.Supervisor,
  req : @core.Request,
) -> (@core.Response, Exit) {
  match req.command {
    "list" => (cmd_list(sv, req.app), Exit::Stay)
    "start" => (cmd_start(sv, req), Exit::Stay)
    "kill" => cmd_kill(sv, req.app)
    "reload" => cmd_reload()
    "notify" => (cmd_notify(sv, req), Exit::Stay)
    _ => (@core.Response::error("unknown command: " + req.command), Exit::Stay)
  }
}

///|
/// The bare `kill` request forces every managed process group down before
/// bm2d exits. SIGTERM to bm2d keeps the existing graceful shutdown path.
/// A deliberate shutdown unregisters every project, so a dead daemon is
/// never revived with stale registrations.
async fn shutdown(
  sv : @core.Supervisor,
  state_dir : String,
  graceful : Bool,
) -> Unit {
  let names = sv.app_names()
  for name in names {
    if graceful {
      @util.discard(() => sv.stop_app(name))
    } else {
      @util.discard(() => sv.kill_app(name))
    }
  }
  if graceful {
    ignore(sv.wait_settled(names))
  } else {
    sv.tick()
  }
  for inst in sv.snapshot() {
    if inst.alive() {
      @util.discard(() => @proc.kill_group(inst.pid, @proc.SIGKILL))
    }
  }
  for name in names {
    @util.discard(() => @core.remove_project(state_dir, name))
  }
  @util.discard(() => @fsx.unlink(state_dir + "/" + @ipc.PORT_FILE))
  @util.discard(() => @fsx.unlink(state_dir + "/" + @ipc.TOKEN_FILE))
  @util.discard(() => @fsx.unlink(state_dir + "/bm2d.pid"))
}

///|
/// `bm2 notify [name]`: deliver one test message on the calling project's
/// targets, so an operator can prove an endpoint and its credential work without
/// waiting for an incident. Delivery happens synchronously, in the request,
/// because it is an explicit administrative action rather than a side effect of
/// supervision.
async fn cmd_notify(
  sv : @core.Supervisor,
  req : @core.Request,
) -> @core.Response {
  let config_path = match req.config_path {
    Some(path) => path
    None => return @core.Response::error("notify requires a config path")
  }
  let config = try @config.load(config_path) catch {
    e => return @core.Response::error(e.to_string())
  } noraise {
    loaded => loaded
  }
  let policy = config.notify
  let mut has_endpoint = false
  for report in policy.reports {
    if report.targets.length() > 0 {
      has_endpoint = true
    }
  }
  if !policy.enabled || !has_endpoint {
    return @core.Response::error(
      "project " +
      config.name +
      " has no notifications enabled: set [notify].enabled = true and add at least one [[notify.report.target]] in bm2.toml",
    )
  }
  let endpoints = []
  for report in policy.reports {
    if req.notify_target is Some(want) && report.name != want {
      continue
    }
    for endpoint in report.targets {
      endpoints.push(endpoint)
    }
  }
  if endpoints.is_empty() {
    return @core.Response::error(
      match req.notify_target {
        Some(name) => "unknown notification target: " + name
        None => "no notification targets configured"
      },
    )
  }
  let results = sv
    .notifier()
    .deliver_now(
      endpoints,
      policy,
      policy.timeout_ms,
      @core.test_message(@util.now_ms(), lang=policy.lang),
    )
  if results.length() == 0 {
    return @core.Response::error(
      match req.notify_target {
        Some(name) => "unknown notification target: " + name
        None => "no notification targets configured"
      },
    )
  }
  let lines = []
  let mut failed = 0
  for pair in results {
    let (name, failure) = pair
    match failure {
      None => lines.push(name + ": sent")
      Some(reason) => {
        failed += 1
        lines.push(name + ": failed - " + reason)
      }
    }
  }
  let message = lines.join("\n")
  if failed == 0 {
    @core.Response::ok(message, [])
  } else {
    @core.Response::error(message)
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
/// Every start re-reads the config from the request's config path, so
/// `bm2 start` always reflects the current bm2.toml, verifies the runtime
/// meets the minimum version, then registers the project (updating it
/// when it already runs) and starts it.
/// Async: the request returns immediately with the in-flight state; the
/// CLI polls `list` for the terminal state so the accept loop never
/// blocks on stop timeouts.
fn cmd_start(sv : @core.Supervisor, req : @core.Request) -> @core.Response {
  let config_path = match req.config_path {
    Some(path) => path
    None => return @core.Response::error("start requires a config path")
  }
  let config = try @config.load(config_path) catch {
    e => return @core.Response::error(e.to_string())
  } noraise {
    loaded => loaded
  }
  try sv.check_runtime(config.runtime) catch {
    e => return @core.Response::error(e.to_string())
  } noraise {
    _ => ()
  }
  try sv.register(config, config_path) catch {
    e => return @core.Response::error(e.to_string())
  } noraise {
    _ => ()
  }
  let name = config.name
  try sv.start_app(name) catch {
    e => return @core.Response::error(e.to_string())
  } noraise {
    _ => ()
  }
  @core.Response::ok("started", infos_of(sv, [name]))
}

///|
/// Kill an app immediately, or request a complete bm2d shutdown when no app
/// name was supplied. The daemon loop performs the all-app kill after reply.
/// Async: an app kill returns right away; the CLI polls for the terminal
/// state instead of blocking the loop. A killed project is unregistered
/// once its instances have stopped.
fn cmd_kill(sv : @core.Supervisor, app : String?) -> (@core.Response, Exit) {
  match app {
    None => (@core.Response::ok("bm2d stopping", []), Exit::Shutdown)
    Some(name) => {
      try sv.kill_app(name) catch {
        e => return (@core.Response::error(e.to_string()), Exit::Stay)
      } noraise {
        _ => ()
      }
      (@core.Response::ok("killed", infos_of(sv, [name])), Exit::Stay)
    }
  }
}

///|
/// Reload detaches bm2d without stopping apps; the CLI then starts a fresh
/// daemon which adopts the surviving instances (and the new binary).
fn cmd_reload() -> (@core.Response, Exit) {
  (@core.Response::ok("reloading", []), Exit::Detach)
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
  let now = @util.now_ms()
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
