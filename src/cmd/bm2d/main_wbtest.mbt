///|
/// One request/response round trip against the real daemon handler, driven
/// over a real loopback TCP connection so the wire format, the token
/// handshake and the dispatch are exercised end to end rather than stubbed.
/// The control side reaches supervision only through the command queue, so the
/// test runs the same tiny tick loop the daemon does.
async fn round_trip(
  sv : @core.Supervisor,
  _state_dir : String,
  req : @protocol.Request,
) -> @protocol.Response {
  let server = @socket.TcpServer::TcpServer(@socket.Addr::new(2130706433U, 0))
  let commands = sv.commands()
  let outbound = sv.outbound()
  @async.with_task_group(async fn(tg) {
    // Supervision, sped up so the test does not wait out the daemon's cadence.
    ignore(
      tg.spawn(async fn() {
        while true {
          sv.tick()
          @async.sleep(5)
        }
      }),
    )
    ignore(
      tg.spawn(async fn() {
        // Server side: one connection, served exactly like the daemon's.
        let conn = @ipc.accept_authed(server, "wbtest")
        match conn {
          Some(conn) =>
            match @ipc.read_request(conn) {
              Some(received) => {
                let (response, _) = match
                  @protocol.protocol_problem(received.protocol) {
                  Some(problem) =>
                    (@protocol.Response::error(problem), @core.ExitMode::Stay)
                  None =>
                    dispatch(commands, outbound, RuntimeProbe::new(), received)
                }
                let _ = @ipc.write_response(conn, response)
                conn.close()
              }
              None => {
                let _ = @ipc.write_response(
                  conn,
                  @protocol.Response::error("invalid request"),
                )
                conn.close()
              }
            }
          None => ()
        }
      }),
    )
    // Client side: token, request, response.
    let client = @socket.Tcp::connect_to_host(
      "127.0.0.1",
      port=server.addr.port(),
    )
    let resp = @ipc.round_trip(client, "wbtest", req, 5000)
    client.close()
    tg.return_immediately(resp)
    resp
  })
}

///|
/// The probe is the daemon's one long wait, so a runtime that never answers must be
/// killed and reported — this is the test that would hang the suite if the timeout
/// regressed. The second call proves the verdict is cached per daemon.
async test "the runtime probe gives up on a hung runtime and caches the verdict" {
  let root = "/tmp/bm2-probe-hang-\{@proc.get_pid()}"
  @fsx.mkdir_p(root)
  let hang = root + "/hang.sh"
  @fsx.write_atomic(
    hang,
    @utf8.encode("#!/bin/sh\nwhile true; do sleep 1; done\n"),
  )
  @fsx.chmod(hang, 0o755)
  let probe = RuntimeProbe::new()
  let started = @proc.monotonic_ms()
  let verdict = probe.check(hang)
  let elapsed = @proc.monotonic_ms() - started
  assert_true(verdict is Some(_))
  match verdict {
    Some(reason) => assert_true(reason.contains("5000ms"))
    None => ()
  }
  assert_true(elapsed < 30000UL)
  // Cached: the second answer comes back immediately.
  let cached_at = @proc.monotonic_ms()
  let again = probe.check(hang)
  assert_true(@proc.monotonic_ms() - cached_at < 1000UL)
  assert_eq(again, verdict)
  @fsx.unlink(hang)
}

///|
async test "the probe reports a runtime that cannot be run" {
  let probe = RuntimeProbe::new()
  let verdict = probe.check("no-such-runtime-bm2")
  assert_true(verdict is Some(_))
  match verdict {
    Some(reason) => assert_true(reason.contains("not found on PATH"))
    None => ()
  }
}

///|
fn probe_sv(name : String) -> (@core.Supervisor, String) raise {
  let state_dir = "/tmp/bm2-daemon-probe-\{name}-\{@proc.get_pid()}"
  let sv = @core.Supervisor::new(state_dir~, bun_path="bun")
  (sv, state_dir)
}

///|
fn request(protocol : Int32?, command : String) -> @protocol.Request {
  { protocol, command, app: None, config_path: None, notify_target: None, }
}

///|
/// Version skew has to be a named condition on both sides: the daemon answers
/// with a matching revision and tells the caller what to do about it, instead
/// of failing while decoding.
async test "daemon rejects a mismatched protocol and says so" {
  let (sv, state_dir) = probe_sv("mismatch")
  let old = round_trip(sv, state_dir, request(None, "list"))
  assert_false(old.ok)
  assert_eq(old.protocol, Some(@protocol.PROTOCOL_VERSION))
  assert_true(old.message.contains("protocol mismatch"))
  assert_true(old.message.contains("reload"))

  let newer = round_trip(sv, state_dir, request(Some(99), "list"))
  assert_false(newer.ok)
  assert_true(newer.message.contains("protocol mismatch"))

  let current = round_trip(
    sv,
    state_dir,
    request(Some(@protocol.PROTOCOL_VERSION), "list"),
  )
  assert_true(current.ok)
  assert_eq(current.protocol, Some(@protocol.PROTOCOL_VERSION))
}

///|
async test "daemon answers list and rejects unknown commands" {
  let (sv, state_dir) = probe_sv("commands")
  let listed = round_trip(
    sv,
    state_dir,
    request(Some(@protocol.PROTOCOL_VERSION), "list"),
  )
  assert_true(listed.ok)
  assert_eq(listed.message, "ok")
  assert_eq(listed.instances.length(), 0)

  let unknown = round_trip(
    sv,
    state_dir,
    request(Some(@protocol.PROTOCOL_VERSION), "explode"),
  )
  assert_false(unknown.ok)
  assert_true(unknown.message.contains("unknown command"))
}
