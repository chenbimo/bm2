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
