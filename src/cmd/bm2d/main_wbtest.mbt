///|
/// One request/response round trip against the real daemon handler, driven
/// over a real Unix socket so the wire format is exercised end to end rather
/// than stubbed.
fn round_trip(
  sv : @core.Supervisor,
  state_dir : String,
  req : @core.Request,
) -> @core.Response raise {
  let path = state_dir + "/probe.sock"
  let listen_fd = @process.socket_listen(path)
  let client = @process.socket_connect(path)
  let server = @process.accept(listen_fd)
  @process.send_msg(client, @core.encode_request(req))
  let (response, _) = handle(server, sv, state_dir)
  @process.close(server)
  @process.close(client)
  @process.close(listen_fd)
  @process.unlink(path)
  response
}

///|
fn probe_sv(name : String) -> (@core.Supervisor, String) raise {
  let state_dir = "/tmp/bm2-daemon-probe-\{name}-\{@process.get_pid()}"
  let sv = @core.Supervisor::new(state_dir~, bun_path="bun")
  (sv, state_dir)
}

///|
fn request(protocol : Int?, command : String) -> @core.Request {
  { protocol, command, app: None, config_path: None, }
}

///|
/// Version skew has to be a named condition on both sides: the daemon answers
/// with a matching revision and tells the caller what to do about it, instead
/// of failing while decoding.
test "daemon rejects a mismatched protocol and says so" {
  let (sv, state_dir) = probe_sv("mismatch")
  let old = round_trip(sv, state_dir, request(None, "list"))
  assert_false(old.ok)
  assert_eq(old.protocol, Some(@core.PROTOCOL_VERSION))
  assert_true(old.message.contains("protocol mismatch"))
  assert_true(old.message.contains("reload"))

  let newer = round_trip(sv, state_dir, request(Some(99), "list"))
  assert_false(newer.ok)
  assert_true(newer.message.contains("protocol mismatch"))

  let current = round_trip(
    sv,
    state_dir,
    request(Some(@core.PROTOCOL_VERSION), "list"),
  )
  assert_true(current.ok)
  assert_eq(current.protocol, Some(@core.PROTOCOL_VERSION))
}

///|
test "daemon answers list and rejects unknown commands" {
  let (sv, state_dir) = probe_sv("commands")
  let listed = round_trip(
    sv,
    state_dir,
    request(Some(@core.PROTOCOL_VERSION), "list"),
  )
  assert_true(listed.ok)
  assert_eq(listed.message, "ok")
  assert_eq(listed.instances.length(), 0)

  let unknown = round_trip(
    sv,
    state_dir,
    request(Some(@core.PROTOCOL_VERSION), "explode"),
  )
  assert_false(unknown.ok)
  assert_true(unknown.message.contains("unknown command"))
}
