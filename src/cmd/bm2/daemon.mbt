///|
/// Ask the running daemon to detach (the same request `bm2 reload` sends). False
/// when the daemon cannot be told: the caller then falls back to the manual hint
/// instead of waiting out a swap that cannot happen.
async fn request_detach(state_dir : String) -> Bool {
  let req : @protocol.Request = {
    protocol: Some(@protocol.PROTOCOL_VERSION),
    command: "reload",
    app: None,
    config_path: None,
    notify_target: None,
  }
  match connect_daemon(state_dir) {
    Some(pair) =>
      match send_attempt(pair, req, 5000) {
        Replied(_) => true
        Errored(_) => false
      }
    None => false
  }
}

///|
/// Apply a freshly installed binary without touching running apps: tell the old
/// daemon to detach, wait it out, start the replacement, adopt the survivors.
async fn apply_update(state_dir : String) -> Int32 {
  let running = match connect_daemon(state_dir) {
    Some((conn, _)) => {
      conn.close()
      true
    }
    None => false
  }
  if !running {
    println("updated")
    return 0
  }
  // Ask first, then swap: `swap_daemon` waits for the old daemon to exit, and
  // nothing else ever asks it to — without this request every upgrade stalled
  // for the full wait and then told the operator to run `bm2 reload` by hand.
  if !request_detach(state_dir) {
    println("updated; run 'bm2 reload' to apply")
    return 0
  }
  if swap_daemon(state_dir) {
    println("updated and applied")
    0
  } else {
    println("updated; run 'bm2 reload' to apply")
    0
  }
}

///|
/// Swap in a fresh daemon: wait out the old daemon's exit, then start
/// the replacement which adopts the running apps. Shared by the `reload`
/// command and the automatic apply after `upgrade`. True once the fresh
/// daemon answers; failure reasons go to stderr.
async fn swap_daemon(state_dir : String) -> Bool {
  // The old daemon removes its control-plane file just before exiting;
  // wait for it, then start the fresh daemon which adopts the running apps.
  if !wait_daemon_exit(state_dir) {
    @proc.eprintln("bm2: bm2d did not exit; swap aborted")
    return false
  }
  @async.sleep(50)
  // The old daemon's flock is released on exit; retry briefly in case
  // it has not fully terminated yet.
  let mut fresh : (@socket.Tcp, String)? = None
  for _ in 0..<3 {
    fresh = try ensure_daemon(state_dir) catch {
      _ => None
    } noraise {
      result => Some(result)
    }
    match fresh {
      Some(_) => break
      None => @async.sleep(100)
    }
  }
  match fresh {
    Some((conn, _)) => {
      conn.close()
      true
    }
    None => {
      @proc.eprintln("bm2: bm2d did not start, see " + state_dir + "/bm2d.log")
      false
    }
  }
}

///|
/// Directory containing the running bm2 binary; upgrades replace it and
/// bm2d in place.
fn self_dir() -> String {
  let exe = try @proc.self_exe() catch {
    _ => return "."
  } noraise {
    found => found
  }
  let mut idx = -1
  for i, c in exe {
    if c == '/' {
      idx = i
    }
  }
  if idx >= 0 {
    exe[:idx].to_owned()
  } else {
    "."
  }
}

///|
/// Poll `list` until every instance of the target app reaches a terminal
/// status (or leaves the listing after a stop), or the deadline passes.
/// For a kill the goal state is the project disappearing: an unknown-app
/// error response means the daemon finished unregistering it.
async fn poll_settled(
  state_dir : String,
  command : String,
  app : String?,
  timeout_ms : Int32,
) -> Array[@protocol.InstanceInfo] {
  let deadline = @utils.now_ms() + timeout_ms.to_uint64()
  let mut last : Array[@protocol.InstanceInfo] = []
  let poll_req : @protocol.Request = {
    protocol: Some(@protocol.PROTOCOL_VERSION),
    command: "list",
    app,
    config_path: None,
    notify_target: None,
  }
  while true {
    @async.sleep(200)
    let resp = try {
      match connect_daemon(state_dir) {
        Some(pair) => Some(send_request(pair, poll_req, 3000))
        None => None
      }
    } catch {
      _ => None
    } noraise {
      r => r
    }
    match resp {
      Some(r) if r.ok => {
        last = r.instances
        // For a start, terminal statuses finish the wait. For a kill the
        // instances disappear first; the project is only gone once the
        // daemon answers with unknown-app, so keep polling until then.
        if command != "kill" && settled(r.instances, app) {
          break
        }
      }
      Some(r) if !r.ok && command == "kill" => break
      _ => ()
    }
    if @utils.now_ms() > deadline {
      break
    }
  }
  last
}

///|
/// True when every instance of the target app is in a terminal status.
/// Stopped instances leave the listing entirely, so an empty match set
/// also counts as settled.
fn settled(infos : Array[@protocol.InstanceInfo], app : String?) -> Bool {
  let relevant = infos.filter(fn(info) {
    match app {
      None => true
      Some(name) => info.app_name == name
    }
  })
  if relevant.is_empty() {
    return true
  }
  relevant.all(fn(info) { info.status == "online" || info.status == "errored" })
}

///|
/// Wait for the reloaded daemon to detach (it removes its endpoint file on the
/// way out). Returns false when the daemon stays alive after five seconds.
async fn wait_daemon_exit(state_dir : String) -> Bool {
  for _ in 0..<100 {
    match connect_daemon(state_dir) {
      None => return true
      Some((conn, _)) => {
        conn.close()
        @async.sleep(50)
      }
    }
  }
  false
}

///|
/// Send one request, recovering once from a stale daemon: when the request
/// fails and nothing is listening on the recorded port anymore, remove the
/// leftover control-plane file, start a fresh daemon and retry. A daemon
/// that is merely busy (still inside a long stop timeout) keeps answering
/// connects, so it is reported instead of being split in two.
async fn request_with_recovery(
  state_dir : String,
  req : @protocol.Request,
  timeout_ms : Int32,
) -> @protocol.Response {
  let pair = match connect_or_start(state_dir) {
    Some(pair) => pair
    None => raise NoDaemon
  }
  @core.log_event(
    state_dir,
    "bm2.events.jsonl",
    "request_sent",
    app=req.app,
    detail=req.command,
  )
  let detail = match send_attempt(pair, req, timeout_ms) {
    Replied(response) => return response
    Errored(message) => message
  }
  @core.log_event(state_dir, "bm2.events.jsonl", "protocol_failed", detail~)
  match connect_daemon(state_dir) {
    Some((alive, _)) => {
      alive.close()
      raise Unresponsive(
        "bm2d is running but did not answer within \{timeout_ms}ms; try again in a moment",
      )
    }
    None => ()
  }
  @utils.discard(() => @fsx.unlink(state_dir + "/" + @ipc.ENDPOINT_FILE))
  @core.log_event(state_dir, "bm2.events.jsonl", "stale_socket_removed")
  let retry = match connect_or_start(state_dir) {
    Some(pair) => pair
    None => raise NoDaemon
  }
  @core.log_event(state_dir, "bm2.events.jsonl", "protocol_retry")
  match send_attempt(retry, req, timeout_ms) {
    Replied(response) => response
    Errored(message) => raise Unresponsive(message)
  }
}

///|
/// `ensure_daemon` with its failure collapsed to None: the CLI reports
/// "bm2d did not start" with the log path, so the underlying errno would
/// only add noise.
async fn connect_or_start(state_dir : String) -> (@socket.Tcp, String)? {
  try ensure_daemon(state_dir) catch {
    _ => None
  } noraise {
    pair => Some(pair)
  }
}

///|
async fn send_attempt(
  pair : (@socket.Tcp, String),
  req : @protocol.Request,
  timeout_ms : Int32,
) -> Send {
  try send_request(pair, req, timeout_ms) catch {
    e => Errored(e.to_string())
  } noraise {
    response => Replied(response)
  }
}

///|
/// Send one request over an authenticated channel and wait at most
/// timeout_ms for the daemon's answer, so a busy-but-healthy daemon can
/// never hang the CLI forever.
async fn send_request(
  pair : (@socket.Tcp, String),
  req : @protocol.Request,
  timeout_ms : Int32,
) -> @protocol.Response {
  let (conn, token) = pair
  let response = @ipc.round_trip(conn, token, req, timeout_ms)
  conn.close()
  response
}

///|
/// Open an authenticated channel to the running daemon. None when there is
/// nothing to talk to: no endpoint file, no listener, or a malformed entry. Port
/// and token are read together, so a daemon that has just been replaced can never
/// hand out a token belonging to its predecessor.
async fn connect_daemon(state_dir : String) -> (@socket.Tcp, String)? {
  try @ipc.dial_with_token(state_dir) catch {
    _ => None
  } noraise {
    pair => Some(pair)
  }
}

///|
/// Connect to the running daemon, spawning bm2d when the recorded endpoint
/// is not answering. bm2d is resolved through PATH (execvpe). Raises when
/// the daemon did not come up in time.
async fn ensure_daemon(state_dir : String) -> (@socket.Tcp, String) {
  match connect_daemon(state_dir) {
    Some(pair) => {
      @core.log_event(state_dir, "bm2.events.jsonl", "daemon_connected")
      pair
    }
    None => {
      @core.log_event(state_dir, "bm2.events.jsonl", "daemon_spawn_requested")
      @fsx.mkdir_p(state_dir, mode=0o700)
      ignore(
        @proc.spawn({
          bun_path: "bm2d",
          script: "",
          cwd: "/",
          out_log: state_dir + "/bm2d.log",
          err_log: state_dir + "/bm2d.log",
          env_blob: @proc.base_env_blob(),
        }),
      )
      for _ in 0..<60 {
        @async.sleep(50)
        match connect_daemon(state_dir) {
          Some(pair) => return pair
          None => ()
        }
      }
      raise @proc.ProcessError::Failed(op="ensure_daemon", errno=2)
    }
  }
}
