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
/// replaced: the CLI only clears a stale socket when nothing is listening, so
/// a busy daemon is never split into two.
test "a busy daemon is reported instead of being replaced" {
  let state_dir = "/tmp/bm2-cli-busy-\{@process.get_pid()}"
  @process.mkdir_p(state_dir)
  // Listening but never accepting: connect() succeeds, no answer ever comes.
  let listen_fd = @process.socket_listen(state_dir + "/bm2.sock")
  let req : @core.Request = {
    protocol: Some(@core.PROTOCOL_VERSION),
    command: "list",
    app: None,
    config_path: None,
  }
  let outcome = try {
    ignore(request_with_recovery(state_dir, req, 300))
    "answered"
  } catch {
    NoDaemon => "no daemon"
    Unresponsive(message) => message
  } noraise {
    _ => "answered"
  }
  assert_true(outcome.contains("did not answer"))
  assert_true(outcome.contains("try again"))
  @process.close(listen_fd)
  @process.unlink(state_dir + "/bm2.sock")
  @process.unlink(state_dir + "/bm2.events.jsonl")
  @fs.remove_dir(state_dir)
}
