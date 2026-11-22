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
    force: None,
    lang: None,
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
async fn apply_update(state_dir : String, lang : @i18n.Lang) -> Int32 {
  let running = match connect_daemon(state_dir) {
    Some((conn, _)) => {
      conn.close()
      true
    }
    None => false
  }
  if !running {
    println(@i18n.updated(lang, applied=false))
    return 0
  }
  // Ask first, then swap: `swap_daemon` waits for the old daemon to exit, and
  // nothing else ever asks it to — without this request every upgrade stalled
  // for the full wait and then told the operator to run `bm2 reload` by hand.
  if !request_detach(state_dir) {
    println(@i18n.update_needs_reload(lang))
    return 0
  }
  if swap_daemon(state_dir, lang) {
    println(@i18n.updated(lang, applied=true))
    0
  } else {
    println(@i18n.update_needs_reload(lang))
    0
  }
}

///|
/// Swap in a fresh daemon: wait out the old daemon's exit, then start
/// the replacement which adopts the running apps. Shared by the `reload`
/// command and the automatic apply after `upgrade`. True once the fresh
/// daemon answers; failure reasons go to stderr.
async fn swap_daemon(state_dir : String, lang : @i18n.Lang) -> Bool {
  // The old daemon removes its control-plane file just before exiting;
  // wait for it, then start the fresh daemon which adopts the running apps.
  if !wait_daemon_exit(state_dir) {
    @proc.eprintln(@i18n.daemon_did_not_exit(lang))
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
      @proc.eprintln(@i18n.daemon_did_not_start(lang, state_dir))
      false
    }
  }
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
    "bm2.events.log",
    "request_sent",
    app=req.app,
    detail=req.command,
  )
  let detail = match send_attempt(pair, req, timeout_ms) {
    Replied(response) => return response
    Errored(message) => message
  }
  @core.log_event(state_dir, "bm2.events.log", "protocol_failed", detail~)
  match connect_daemon(state_dir) {
    Some((alive, _)) => {
      alive.close()
      raise Unresponsive(
        @i18n.daemon_busy(@i18n.of_request(req.lang), timeout_ms),
      )
    }
    None => ()
  }
  @utils.discard(() => {
    @fsx.unlink(@utils.join_path(state_dir, @ipc.ENDPOINT_FILE))
  })
  @core.log_event(state_dir, "bm2.events.log", "stale_socket_removed")
  let retry = match connect_or_start(state_dir) {
    Some(pair) => pair
    None => raise NoDaemon
  }
  @core.log_event(state_dir, "bm2.events.log", "protocol_retry")
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
      @core.log_event(state_dir, "bm2.events.log", "daemon_connected")
      pair
    }
    None => {
      @core.log_event(state_dir, "bm2.events.log", "daemon_spawn_requested")
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
        if connect_daemon(state_dir) is Some(pair) {
          return pair
        }
      }
      raise @proc.ProcessError::Failed(op="ensure_daemon", errno=2)
    }
  }
}
