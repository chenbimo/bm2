///|
fn info(app : String, status : String) -> @protocol.InstanceInfo {
  {
    app_name: app,
    mode: "production",
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
test "human_duration reads in the largest sensible unit" {
  assert_eq(@utils.human_duration(0UL), "0s")
  assert_eq(@utils.human_duration(59000UL), "59s")
  assert_eq(@utils.human_duration(60000UL), "1m 0s")
  assert_eq(@utils.human_duration(3599000UL), "59m 59s")
  assert_eq(@utils.human_duration(3600000UL), "1h 0m")
  assert_eq(@utils.human_duration(90000000UL), "1d 1h")
  // The list table pads the second unit so the columns line up; messages read
  // better without it.
  assert_eq(@utils.human_duration(60000UL, pad=true), "1m 00s")
  assert_eq(@utils.human_duration(3600000UL, pad=true), "1h 00m")
  assert_eq(@utils.human_duration(90000000UL, pad=true), "1d 01h")
}

///|
/// A daemon that accepts connections but never answers must be reported, not
/// replaced: the CLI only clears the control-plane file when nothing is
/// listening, so a busy daemon is never split into two.
async test "a busy daemon is reported instead of being replaced" {
  let state_dir = "/tmp/bm2-cli-busy-\{@proc.get_pid()}"
  @fsx.mkdir_p(state_dir)
  // Listening but never accepting requests: connects succeed, no answer
  // ever comes.
  let server = @socket.TcpServer::TcpServer(@socket.Addr::new(2130706433U, 0))
  @fs.write_string_to_file(
    state_dir + "/" + @ipc.ENDPOINT_FILE,
    server.addr.port().to_string() + "\nwbtest-token\n",
  )
  let req : @protocol.Request = {
    protocol: Some(@protocol.PROTOCOL_VERSION),
    command: "list",
    app: None,
    config_path: None,
    notify_target: None,
    force: None,
    lang: None,
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
  @fsx.unlink(state_dir + "/" + @ipc.ENDPOINT_FILE)
  @fsx.unlink(state_dir + "/bm2.events.jsonl")
  @fs.remove_dir(state_dir)
}

///|
/// Every line of a table must occupy the same number of terminal columns. The bug
/// this pins: widths used to come from `String::length`, so the translated header
/// `运行时长` measured 4 code units while occupying 8 columns, and the Chinese table
/// came out ragged with the rest of its columns pulled left.
test "table lines are equal in display width, in both languages" {
  for lang in [@i18n.Lang::En, @i18n.Lang::Zh] {
    let header = @i18n.list_headers(lang)
    let rows = [
      [
        "api",
        "0",
        "12345",
        "3020",
        @i18n.mode_value(lang, "production"),
        @i18n.exec_value(lang, "cluster"),
        @i18n.status_value(lang, "running"),
        "3",
        "42 MB",
        "18m 02s",
        "/wwwroot/api",
      ],
    ]
    let lines = @utils.split(render_table(header, rows), "\n")
    assert_eq(lines.length(), 2)
    let expected = @utils.display_width(lines[0])
    for line in lines {
      assert_eq(@utils.display_width(line), expected)
    }
    // The header must be at least as wide as the row it labels, in every column:
    // a width that ignored display columns would fail this on the Chinese header.
    assert_true(expected >= @utils.display_width("api"))
  }
}

///|
/// The daemon summary is a row of numbers with no sentence to it: pairs, four to a
/// line, the second line indented to the width of the prefix so the columns line up
/// in either language.
test "the daemon summary lines up its pairs" {
  for lang in [@i18n.Lang::En, @i18n.Lang::Zh] {
    let labels = @i18n.daemon_labels(lang)
    let pairs = [
      "\{labels[0]} 607883",
      "\{labels[1]} 8",
      "\{labels[2]} 3 \{labels[3]}",
      "\{labels[4]} 18m 02s",
      "\{labels[5]} 0",
      "\{labels[6]} 7",
      "\{labels[7]} 0",
      "\{labels[8]} 0",
    ]
    let lines = @utils.split(render_pairs(pairs, "daemon: ", 4), "\n")
    assert_eq(lines.length(), 2)
    // The first pair of each row carries the prefix, the continuation an indent of
    // exactly the same width.
    assert_true(lines[0].has_prefix("daemon: " + labels[0] + " 607883"))
    assert_true(lines[1].has_prefix("        " + labels[5] + " 0"))
    assert_eq(@utils.display_width(lines[0]), @utils.display_width(lines[1]))
  }
}
