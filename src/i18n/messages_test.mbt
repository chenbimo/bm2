///|
/// 英文是默认语言,也是测试断言的语言:这些字符串是既有契约,不是译文。
test "English is the contract the tests assert" {
  assert_eq(@i18n.started(@i18n.Lang::En), "started")
  assert_eq(@i18n.stopped(@i18n.Lang::En), "stopped")
  assert_eq(@i18n.removing(@i18n.Lang::En), "removing")
  assert_eq(@i18n.reloading(@i18n.Lang::En), "reloading")
  assert_eq(@i18n.reloaded(@i18n.Lang::En), "reloaded")
  assert_eq(@i18n.bm2d_stopping(@i18n.Lang::En), "bm2d stopping")
  assert_eq(@i18n.no_instances(@i18n.Lang::En), "no instances")
  assert_eq(
    @i18n.unknown_command(@i18n.Lang::En, "explode"),
    "unknown command: explode",
  )
}

///|
/// 带参数的文案,参数原样接在后面,不翻译。
test "messages with a parameter keep it verbatim" {
  assert_eq(
    @i18n.unknown_command(@i18n.Lang::Zh, "explode"),
    "未知命令:explode",
  )
  assert_eq(
    @i18n.unknown_command(@i18n.Lang::Zh, "explode").contains("explode"),
    true,
  )
}

///|
/// 中文这一列至少要有东西,不能是空的或者忘了写的占位。
test "Chinese answers are non-empty and differ from English" {
  let zh : Array[String] = [
    @i18n.started(@i18n.Lang::Zh),
    @i18n.stopped(@i18n.Lang::Zh),
    @i18n.removing(@i18n.Lang::Zh),
    @i18n.reloading(@i18n.Lang::Zh),
    @i18n.reloaded(@i18n.Lang::Zh),
    @i18n.bm2d_stopping(@i18n.Lang::Zh),
    @i18n.no_instances(@i18n.Lang::Zh),
  ]
  for text in zh {
    assert_true(text.length() > 0)
  }
  assert_true(@i18n.started(@i18n.Lang::Zh) != @i18n.started(@i18n.Lang::En))
}
