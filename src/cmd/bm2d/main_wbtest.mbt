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
                  None => dispatch(commands, outbound, received)
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
