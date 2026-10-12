///|
fn info(app : String, status : String) -> @core.InstanceInfo {
  {
    app_name: app,
    cwd: "/srv/" + app,
    instance_id: 0,
    pid: 100,
    port: 4000,
    exec_mode: "fork",
    status,
    times: 1,
    restart_count: 0,
    rss_kb: 1024,
    uptime_ms: 1000UL,
    last_reason: None,
  }
}

///|
/// `settled` decides when the CLI stops polling after an async start or
/// kill: online and errored are terminal, everything else keeps waiting.
test "settled treats online and errored as terminal" {
  assert_true(settled([info("a", "online")], Some("a")))
  assert_true(settled([info("a", "errored")], Some("a")))
  assert_false(settled([info("a", "starting")], Some("a")))
  assert_false(settled([info("a", "restarting")], Some("a")))
  assert_false(settled([info("a", "stopping")], Some("a")))
}

///|
test "settled ignores other projects and an empty listing" {
  // Another project being busy must not hold up this one.
  assert_true(settled([info("other", "starting")], Some("a")))
  // A stopped instance leaves the listing entirely, which reads as settled.
  assert_true(settled([], Some("a")))
  assert_false(settled([info("a", "starting"), info("a", "online")], Some("a")))
}

///|
test "format_uptime reads in the largest sensible unit" {
  assert_eq(format_uptime(0UL), "0s")
  assert_eq(format_uptime(59000UL), "59s")
  assert_eq(format_uptime(60000UL), "1m 00s")
  assert_eq(format_uptime(3599000UL), "59m 59s")
  assert_eq(format_uptime(3600000UL), "1h 00m")
  assert_eq(format_uptime(90000000UL), "1d 01h")
}

///|
/// A daemon that accepts connections but never answers must be reported, not
/// replaced: the CLI only clears the control-plane files when nothing is
/// listening, so a busy daemon is never split into two.
async test "a busy daemon is reported instead of being replaced" {
  let state_dir = "/tmp/bm2-cli-busy-\{@subproc.get_pid()}"
  @fsx.mkdir_p(state_dir)
  // Listening but never accepting requests: connects succeed, no answer
  // ever comes.
  let server = @socket.TcpServer::TcpServer(@socket.Addr::new(2130706433U, 0))
  @fs.write_string_to_file(
    state_dir + "/" + @dcipc.PORT_FILE,
    server.addr.port().to_string() + "\n",
  )
  @fs.write_string_to_file(state_dir + "/" + @dcipc.TOKEN_FILE, "wbtest-token")
  let req : @core.Request = {
    protocol: Some(@core.PROTOCOL_VERSION),
    command: "list",
    app: None,
    config_path: None,
    notify_target: None,
  }
  let outcome = try {
    ignore(request_with_recovery(state_dir, req, 300))
    "answered"
  } catch {
    NoDaemon => "no daemon"
    Unresponsive(message) => message
    other => "errored: \{other}"
  } noraise {
    _ => "answered"
  }
  assert_true(outcome.contains("did not answer"))
  assert_true(outcome.contains("try again"))
  server.close()
  @fsx.unlink(state_dir + "/" + @dcipc.PORT_FILE)
  @fsx.unlink(state_dir + "/" + @dcipc.TOKEN_FILE)
  @fsx.unlink(state_dir + "/bm2.events.jsonl")
  @fs.remove_dir(state_dir)
}
