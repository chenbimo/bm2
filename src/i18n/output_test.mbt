///|
/// The command surface's copy: the English column is the text bm2 printed before
/// this existed, so it is a contract and the tests pin it. Everything else here is
/// about structure that would break silently — a column count, a label list, a
/// fallback.

///|
test "English is the contract for the command surface" {
  assert_eq(
    @i18n.help_root(@i18n.Lang::En),
    "Process manager for Bun / Node.js on Linux",
  )
  assert_eq(
    @i18n.help_serve(@i18n.Lang::En),
    "Register and start the project in production (.env, .env.production)",
  )
  assert_eq(
    @i18n.help_no_follow(@i18n.Lang::En),
    "Start and return instead of following the logs",
  )
  assert_eq(
    @i18n.kill_needs_confirmation(@i18n.Lang::En),
    "refusing to stop bm2d and all apps; use 'bm2 kill -y' to confirm",
  )
  assert_eq(
    @i18n.check_script_missing(@i18n.Lang::En, "/srv/api/index.ts"),
    "script not found: /srv/api/index.ts",
  )
}

///|
/// A translated header that changed the column count would shift every row by
/// position, which the table renders by index and nothing else checks.
test "the list header has the same columns in both languages" {
  let en = @i18n.list_headers(@i18n.Lang::En)
  let zh = @i18n.list_headers(@i18n.Lang::Zh)
  assert_eq(en.length(), 11)
  assert_eq(zh.length(), en.length())
}

///|
/// 标签表是摘要表的表头行：八条对应八类数值，MB 这类单位跟数值走，
/// 不占表头位。两种语言的条数与首项必须一致。
test "the daemon labels keep their order and count" {
  let en = @i18n.daemon_labels(@i18n.Lang::En)
  let zh = @i18n.daemon_labels(@i18n.Lang::Zh)
  assert_eq(en.length(), 8)
  assert_eq(zh.length(), en.length())
  assert_eq(en[0], "pid")
  assert_eq(zh[0], "pid")
  assert_true(!en.contains("MB"))
}

///|
test "Chinese is a different text, not a copy" {
  assert_true(
    @i18n.help_root(@i18n.Lang::Zh) != @i18n.help_root(@i18n.Lang::En),
  )
  assert_true(
    @i18n.help_version(@i18n.Lang::Zh) != @i18n.help_version(@i18n.Lang::En),
  )
  assert_true(
    @i18n.list_headers(@i18n.Lang::Zh)[0] !=
    @i18n.list_headers(@i18n.Lang::En)[0],
  )
  assert_true(
    @i18n.no_instances(@i18n.Lang::Zh) != @i18n.no_instances(@i18n.Lang::En),
  )
}

///|
/// A request's language is a hint from over a socket: anything unrecognised has to
/// land on the default rather than fail the command.
test "of_request answers English when the name is absent or unknown" {
  assert_true(@i18n.of_request(None) is @i18n.Lang::En)
  assert_true(@i18n.of_request(Some("zh")) is @i18n.Lang::Zh)
  assert_true(@i18n.of_request(Some("fr")) is @i18n.Lang::En)
  assert_true(@i18n.of_request(Some("")) is @i18n.Lang::En)
}

///|
/// Values bm2 does not recognise are not ours to rename: a status this build has
/// never heard of prints as it came.
test "unrecognised values print as they came" {
  assert_eq(@i18n.status_value(@i18n.Lang::Zh, "invented"), "invented")
  assert_eq(@i18n.exec_value(@i18n.Lang::Zh, "invented"), "invented")
  assert_eq(@i18n.mode_value(@i18n.Lang::Zh, "invented"), "invented")
  assert_eq(@i18n.status_value(@i18n.Lang::Zh, "running"), "运行中")
}

///|
/// The variables in a message are data: a path, a name, a count. Translating must
/// not lose them.
test "parameters survive translation" {
  assert_true(@i18n.removed(@i18n.Lang::Zh, "/srv/api").contains("/srv/api"))
  assert_true(@i18n.status_gone(@i18n.Lang::Zh, "api").contains("api"))
  assert_true(@i18n.status_gone(@i18n.Lang::En, "api").contains("api"))
  assert_true(@i18n.follow_started(@i18n.Lang::Zh, "api").contains("api"))
  assert_true(
    @i18n.unknown_command(@i18n.Lang::Zh, "frobnicate").contains("frobnicate"),
  )
  let kind = @i18n.port_holder_kind(@i18n.Lang::Zh, "shared")
  assert_true(
    @i18n.check_port_held(@i18n.Lang::Zh, 4391, kind).contains("4391"),
  )
}
