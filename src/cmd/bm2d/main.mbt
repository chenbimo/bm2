///|
/// How long the control side waits for the supervision task to answer a command.
/// One tick is 50 ms, but `start` also probes the runtime (up to 5 s) before it
/// can answer, so the ceiling is deliberately generous — a CLI that tires of
/// waiting reports the timeout itself.
const COMMAND_REPLY_MS : UInt64 = 15000

///|
/// How many connections may request a daemon exit before the task group body
/// picks one up. More than one is conceivable (a `kill` racing a `reload`), and
/// the first one to arrive wins.
const EXIT_SIGNAL_CAPACITY : Int32 = 4

///|
/// How many control connections may be in flight at once. Each one costs a task
/// and a descriptor, and a local client that opens thousands of silent
/// connections must not be able to grow the daemon without bound. The control
/// plane is loopback-only behind a shared token, so this is a guardrail against
/// a runaway caller, not a security boundary.
///
/// The gate itself is a library semaphore: one permit per connection, taken on
/// accept and released when the connection is done. Refusing a caller is the
/// deliberate answer — a queue would only move the pressure into memory — but if
/// that ever changes, a blocking `acquire` is one call away.
const MAX_CONTROL_CONNECTIONS : Int32 = 64

///|
/// Runtime version probes, owned by the control task. `<runtime> --version` is a
/// helper process on a possibly stuck filesystem: waiting for it belongs to a task
/// that can wait (`@async.with_timeout_opt`), never to the supervision tick. The
/// verdict is cached per daemon, so restarting an existing project costs nothing.
struct RuntimeProbe {
  /// Runtime name → verdict (`None` = the runtime is acceptable).
  checked : Map[String, String?]
}

///|
fn RuntimeProbe::new() -> RuntimeProbe {
  { checked: Map([]), }
}

///|
/// The verdict for one runtime, probing at most once per daemon. `None` means the
/// runtime is acceptable; `Some(reason)` is what the operator sees.
async fn RuntimeProbe::check(self : RuntimeProbe, runtime : String) -> String? {
  match self.checked.get(runtime) {
    Some(verdict) => verdict
    None => {
      let attempt = async fn() {
        let (code, out, _err) = @process.collect_output(runtime, ["--version"])
        @core.runtime_verdict(
          runtime,
          code,
          @utf8.decode_lossy(out.binary()).trim().to_owned(),
        )
      }
      // A cancelled wait kills the helper (only orphan spawns survive their
      // caller), so a stuck runtime cannot outlive its own timeout.
      // Shapes: `Some(None)` = acceptable, `Some(Some(reason))` = rejected,
      // `None` = the probe never answered.
      let answer = try
        @async.with_timeout_opt(@core.RUNTIME_PROBE_TIMEOUT_MS, attempt)
      catch {
        _ => Some(Some(@core.runtime_unrunnable(runtime)))
      } noraise {
        result => result
      }
      let verdict = match answer {
        Some(None) => None
        Some(Some(reason)) => Some(reason)
        None => Some(@core.runtime_timeout(runtime))
      }
      self.checked[runtime] = verdict
      verdict
    }
  }
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
  @utils.discard(() => @fsx.mkdir_p(state_dir, mode=0o700))
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
  @utils.discard(() => @fsx.unlink(state_dir + "/bm2.sock"))
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
    @ipc.write_endpoint(state_dir, port, token)
    true
  } catch {
    _ => false
  } noraise {
    written => written
  }
  if !ok {
    @proc.eprintln("bm2d: cannot write the control-plane file")
    server.close()
    return 2
  }
  // Only claim the pid file once the control endpoint is up: a daemon that
  // fails to bind must not overwrite the pid of a live daemon.
  @utils.discard(() => {
    @fsx.write_atomic(
      state_dir + "/bm2d.pid",
      @utf8.encode(@proc.get_pid().to_string() + "\n"),
    )
  })
  @core.log_event(state_dir, "bm2d.events.jsonl", "socket_listening")
  // Three long-lived tasks (supervision, delivery, control) plus the group body,
  // which waits for an exit request to arrive from a served connection. SIGTERM
  // cancels the whole group instead; both paths land in the shutdown code below.
  let outbound = sv.outbound()
  let commands = sv.commands()
  let outcome = @async.handle_cancellation(async fn() {
    @async.with_task_group(async fn(tg) {
      // Four long-lived tasks, each owning its own state and none able to take
      // another down. Supervision is synchronous: it never waits on the network
      // and never copies a log, publishing both kinds of work onto a queue
      // instead; delivery is the only place that touches the network, and
      // rotation the only place that copies a file. The control plane serves one
      // connection per task and reaches supervision only through the command
      // queue. `allow_failure` keeps a failure in one task from cancelling the
      // others, and each task records its own failures in the event log.
      let runner = @core.NotifyRunner::new(
        state_dir,
        @proc.hostname(),
        outbound,
      )
      let rotator = @core.RotateRunner::new(state_dir, sv.rotations())
      let exits : @aqueue.Queue[@core.ExitMode] = @aqueue.Queue::Queue(
        kind=Blocking(EXIT_SIGNAL_CAPACITY),
      )
      let gate : @semaphore.Semaphore = @semaphore.Semaphore(
        MAX_CONTROL_CONNECTIONS,
      )
      let probe = RuntimeProbe::new()
      ignore(tg.spawn(async fn() { tick_loop(sv) }, allow_failure=true))
      ignore(tg.spawn(async fn() { runner.run() }, allow_failure=true))
      ignore(tg.spawn(async fn() { rotator.run() }, allow_failure=true))
      ignore(
        tg.spawn(async fn() {
          accept_loop(
            server, commands, outbound, state_dir, token, exits, gate, probe, tg,
          )
        }),
      )
      // The group body waits for a served request to ask for an exit; when it
      // returns, the tasks above are cancelled. A failure in the accept task
      // (the only one without `allow_failure`) ends the daemon the same way,
      // exactly as when the accept loop was the body itself.
      let mode = wait_exit(exits)
      tg.return_immediately(mode)
      mode
    })
  })
  match outcome {
    Some(@core.ExitMode::Detach) => {
      @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_detaching")
      server.close()
      @utils.discard(() => @fsx.unlink(state_dir + "/" + @ipc.ENDPOINT_FILE))
      @utils.discard(() => @fsx.unlink(state_dir + "/bm2d.pid"))
      @core.log_event(state_dir, "bm2d.events.jsonl", "daemon_detached")
    }
    Some(@core.ExitMode::Shutdown) => {
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
    Some(@core.ExitMode::Stay) =>
      // Unreachable: `wait_exit` only ever sees a real exit request.
      ()
  }
  0
}

///|
/// Supervision heartbeat: the same 50ms cadence as the old poll loop, now a
/// timer inside the async runtime. Timer cancellation is what unwinds this
/// task when the daemon exits.
///
/// `Supervisor::tick` declares no error type, so this loop cannot raise and
/// cannot end early: supervision stops only when the daemon stops.
async fn tick_loop(sv : @core.Supervisor) -> Unit {
  while true {
    let timer = @async.Timer::Timer(50)
    timer.wait()
    sv.tick()
  }
}

///|
/// Accept connections and hand each one to its own task. Cancellation unwinds
/// the blocked accept; a failure here (this is the one task without
/// `allow_failure`) ends the daemon, exactly as when the loop was the task group
/// body itself.
///
/// Nothing but accepting happens here: authentication belongs to the connection's
/// own task, or a client that connects and says nothing would hold the loop up
/// for `AUTH_TIMEOUT_MS` per connection.
async fn accept_loop(
  server : @socket.TcpServer,
  commands : @aqueue.Queue[@core.Command],
  outbound : @aqueue.Queue[@core.Outbound],
  state_dir : String,
  token : String,
  exits : @aqueue.Queue[@core.ExitMode],
  gate : @semaphore.Semaphore,
  probe : RuntimeProbe,
  tg : @async.TaskGroup[@core.ExitMode],
) -> Unit {
  while true {
    let accepted = try server.accept() catch {
      _ => None
    } noraise {
      pair => Some(pair)
    }
    match accepted {
      None => continue
      Some((conn, _peer)) =>
        if gate.try_acquire() {
          // One task per connection: a slow request (a stop timeout, a runtime
          // probe) no longer holds up the next caller. Supervision mutations
          // stay serialized regardless — every one of them happens on the
          // supervision task now.
          ignore(
            tg.spawn(
              async fn() {
                serve_conn(
                  conn, commands, outbound, state_dir, token, exits, gate, probe,
                )
              },
              allow_failure=true,
            ),
          )
        } else {
          @core.log_event(state_dir, "bm2d.events.jsonl", "connection_refused")
          conn.close()
        }
    }
  }
}

///|
/// Serve one connection to completion: authenticate, read the request, apply it,
/// answer, and signal an exit request to the task group body. Requests stay
/// sequential per connection, and a failure here ends only this connection.
async fn serve_conn(
  conn : @socket.Tcp,
  commands : @aqueue.Queue[@core.Command],
  outbound : @aqueue.Queue[@core.Outbound],
  state_dir : String,
  token : String,
  exits : @aqueue.Queue[@core.ExitMode],
  gate : @semaphore.Semaphore,
  probe : RuntimeProbe,
) -> Unit {
  if !@ipc.authenticate(conn, token) {
    // A rejected handshake is a wrong token or a probe: worth a line in the
    // event log either way.
    @core.log_event(state_dir, "bm2d.events.jsonl", "auth_failed")
    gate.release()
    return
  }
  let (response, exit) = match @ipc.read_request(conn) {
    Some(req) =>
      match @protocol.protocol_problem(req.protocol) {
        Some(problem) =>
          (@protocol.Response::error(problem), @core.ExitMode::Stay)
        None => {
          @core.log_event(
            state_dir,
            "bm2d.events.jsonl",
            "request_received",
            app=req.app,
            detail=req.command,
          )
          dispatch(commands, outbound, probe, req)
        }
      }
    None => (@protocol.Response::error("invalid request"), @core.ExitMode::Stay)
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
  // Exit requests are honored only after their response has reached the caller.
  if sent && !(exit is @core.ExitMode::Stay) {
    @utils.discard(() => ignore(exits.try_put(exit)))
  }
  gate.release()
}

///|
/// Route one request. `notify` is served here — it reads no supervised state and
/// only publishes onto the notification queue, which is made for cross-task use.
/// Every other command travels to the supervision task and is applied inside its
/// next tick, so the control plane never becomes a second writer of supervised
/// state.
async fn dispatch(
  commands : @aqueue.Queue[@core.Command],
  outbound : @aqueue.Queue[@core.Outbound],
  probe : RuntimeProbe,
  req : @protocol.Request,
) -> (@protocol.Response, @core.ExitMode) {
  if req.command == "notify" {
    return (cmd_notify(outbound, req), @core.ExitMode::Stay)
  }
  // A start is probed here, before the request reaches supervision: the wait for
  // `<runtime> --version` is a wait, and the supervision tick has no await point
  // by design. A rejected runtime never reaches the register step.
  match preflight_runtime(probe, req) {
    Some(reason) =>
      return (@protocol.Response::error(reason), @core.ExitMode::Stay)
    None => ()
  }
  let command = @core.Command::new(req)
  let queued = try commands.try_put(command) catch {
    _ => false
  } noraise {
    ok => ok
  }
  if !queued {
    return (
      @protocol.Response::error("too many control requests in flight"),
      @core.ExitMode::Stay,
    )
  }
  match wait_reply(command.reply) {
    Some(reply) => (reply.response, reply.exit)
    None =>
      (
        @protocol.Response::error(
          "bm2d did not answer within \{COMMAND_REPLY_MS}ms; try again in a moment",
        ),
        @core.ExitMode::Stay,
      )
  }
}

///|
/// The runtime verdict for a start request, or None when there is nothing to check
/// — another command, no config path, or a config that does not load (the command
/// itself reports that one, with the parser's own message).
async fn preflight_runtime(
  probe : RuntimeProbe,
  req : @protocol.Request,
) -> String? {
  let mode = match @config.Mode::of_command(req.command) {
    Some(mode) => mode
    None => return None
  }
  let path = match req.config_path {
    Some(path) => path
    None => return None
  }
  let config = try @config.load(path, mode~) catch {
    _ => return None
  } noraise {
    loaded => loaded
  }
  probe.check(config.runtime)
}

///|
/// Wait for the supervision task's answer. Polls the reply queue so the wait
/// stays cancellable and bounded: one connection never blocks forever.
async fn wait_reply(reply : @aqueue.Queue[@core.Reply]) -> @core.Reply? {
  let deadline = @proc.monotonic_ms() + COMMAND_REPLY_MS
  while true {
    let answer = try reply.try_get() catch {
      _ => None
    } noraise {
      item => item
    }
    match answer {
      Some(reply) => return Some(reply)
      None => ()
    }
    if @proc.monotonic_ms() >= deadline {
      return None
    }
    @async.sleep(20)
  }
  None
}

///|
/// Wait for a served request to ask for an exit. Polls rather than blocking on
/// the queue: the task group body must stay cancellable, and a 50 ms poll costs
/// nothing next to the tick that produced the signal.
async fn wait_exit(exits : @aqueue.Queue[@core.ExitMode]) -> @core.ExitMode {
  while true {
    let signal = try exits.try_get() catch {
      _ => None
    } noraise {
      item => item
    }
    match signal {
      Some(mode) => return mode
      None => @async.sleep(50)
    }
  }
  @core.ExitMode::Shutdown
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
      @utils.discard(() => sv.stop_app(name))
    } else {
      @utils.discard(() => sv.remove_app(name, force=true))
    }
  }
  if graceful {
    ignore(sv.wait_settled(names))
  } else {
    sv.tick()
  }
  for inst in sv.snapshot() {
    if inst.alive() {
      @utils.discard(() => @proc.kill_group(inst.pid, @proc.SIGKILL))
    }
  }
  for name in names {
    @utils.discard(() => @core.remove_project(state_dir, name))
  }
  @utils.discard(() => @fsx.unlink(state_dir + "/" + @ipc.ENDPOINT_FILE))
  @utils.discard(() => @fsx.unlink(state_dir + "/bm2d.pid"))
}

///|
/// Wait for the notify task's per-target results. Polls rather than cancelling
/// a pending read, so the semantics stay obvious and no result can be lost to a
/// cancellation.
async fn wait_notify_results(
  reply : @aqueue.Queue[Array[(String, String?)]],
  budget_ms : UInt64,
) -> Array[(String, String?)]? {
  let deadline = @proc.monotonic_ms() + budget_ms
  while true {
    let results = try reply.try_get() catch {
      _ => None
    } noraise {
      item => item
    }
    match results {
      Some(results) => return Some(results)
      None => ()
    }
    if @proc.monotonic_ms() >= deadline {
      return None
    }
    @async.sleep(20)
  } nobreak {
    None
  }
}

///|
/// How long to wait for a test delivery: one `timeout_ms` plus margin — targets
/// are delivered in parallel, so the wait is the slowest of them, not their sum.
/// Capped so a pathological endpoint count cannot pin the request; the CLI derives
/// its own request timeout from the same shape of bound, so it gives up first.
fn test_wait_budget_ms(policy : @config.NotifyConfig) -> UInt64 {
  let budget = policy.timeout_ms.to_uint64()
  let capped = if budget > 120000UL { 120000UL } else { budget }
  capped + 2000UL
}

///|
/// `bm2 notify [name]`: deliver one test message on the calling project's
/// targets, so an operator can prove an endpoint and its credential work without
/// waiting for an incident. The delivery itself happens in the notify task (the
/// only place that talks to the network); this request publishes the test and
/// waits for the per-target results. It needs no supervised state — only the
/// queue the two tasks share — so it runs entirely on the control side.
async fn cmd_notify(
  outbound : @aqueue.Queue[@core.Outbound],
  req : @protocol.Request,
) -> @protocol.Response {
  let config_path = match req.config_path {
    Some(path) => path
    None => return @protocol.Response::error("notify requires a config path")
  }
  let config = try @config.load(config_path) catch {
    e => return @protocol.Response::error(e.to_string())
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
    return @protocol.Response::error(
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
    return @protocol.Response::error(
      match req.notify_target {
        Some(name) => "unknown notification target: " + name
        None => "no notification targets configured"
      },
    )
  }
  let reply = @core.publish_test(
    outbound,
    config.name,
    policy,
    endpoints,
    @core.test_message(@utils.now_ms(), lang=policy.lang),
  )
  let results = match wait_notify_results(reply, test_wait_budget_ms(policy)) {
    Some(results) => results
    None =>
      return @protocol.Response::error(
        "the notify task did not report a result within the delivery timeout",
      )
  }
  if results.length() == 0 {
    return @protocol.Response::error(
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
    @protocol.Response::ok(message, [])
  } else {
    @protocol.Response::error(message)
  }
}
