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
  let server = @socket.TcpServer::TcpServer(
    @socket.Addr::Addr(
      try @socket.IpAddr::IpAddr("127.0.0.1") catch {
        _ => abort("loopback ip must parse")
      } noraise {
        ip => ip
      },
      0,
    ),
  )
  @fs.write_string_to_file(
    state_dir + "/" + @ipc.ENDPOINT_FILE,
    server.addr.port.to_string() + "\nwbtest-token\n",
  )
  let req : @protocol.Request = {
    protocol: Some(@protocol.PROTOCOL_VERSION),
    command: "list",
    app: None,
    config_path: None,
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
  @fsx.unlink(state_dir + "/bm2.events.log")
  @fs.remove_dir(state_dir)
}

///|
/// 实例表交给 clitable 渲染，宽度与对齐是库的职责，它的仓库里有自己的测试。
/// 这里钉住的是 bm2 侧的输入契约：表头的列数与数据行的列数一致，渲染里要
/// 看得到真实数据，出错也不会悄悄吞掉一张表。
test "the list table keeps a full grid of columns" {
  for lang in [@i18n.Lang::En, @i18n.Lang::Zh] {
    let header = @i18n.list_headers(lang)
    assert_eq(header.length(), 10)
    let row = [
      "api",
      "0",
      "12345",
      "3020",
      @i18n.exec_value(lang, "cluster"),
      @i18n.status_value(lang, "running"),
      "3",
      "42 MB",
      "18m 02s",
      "/wwwroot/api",
    ]
    assert_eq(row.length(), header.length())
    let out = render_table(header, [row])
    assert_true(out.contains("api"))
    assert_true(out.contains("/wwwroot/api"))
  }
}

///|
/// 守护进程摘要的表头与数值行等长：clitable 用 Arity 执法，不等长当场报。
/// 这里钉住表头标签与数值都完整出现在渲染结果里。
test "the daemon summary pairs headers with values" {
  let labels = @i18n.daemon_labels(@i18n.Lang::En)
  let values = ["607883", "8", "3 MB", "18m 02s", "0", "7", "0", "0"]
  assert_eq(values.length(), labels.length())
  let out = render_summary(labels, values)
  assert_true(out.contains("607883"))
  assert_true(out.contains(labels[6]))
}
