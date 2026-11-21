///|
/// `[notify]` 的解析与校验：目标、事件过滤、阈值默认值。
///
/// 每个用例都走真实的项目解析路径（`@config.parse`），因为配置的约束就该在
/// 用户写错的那一刻报出来，而不是等到投递时。

///|
/// One project document with the given notification section appended.
fn project_doc(notify_section : String) -> String {
  "name = \"blog\"\nscript = \"index.ts\"\ninstances = 1\nport = 3000\n" +
  notify_section
}

///|
fn parse_notify(notify_section : String) -> @config.NotifyConfig raise {
  @config.parse(project_doc(notify_section), "/srv/yicode").notify
}

///|
fn notify_error(notify_section : String) -> String raise {
  parse_error(project_doc(notify_section))
}

///|
test "thresholds default to the recommended values" {
  let notify = parse_notify(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"webhook\"\nurl = \"https://h/a\"\n",
  )
  assert_eq(notify.threshold_rss_percent, 80)
  assert_eq(notify.threshold_offline_min, 5)
  assert_eq(notify.threshold_restarts, 5)
  assert_eq(notify.start_timeout_ms, 30000)
  assert_eq(notify.threshold_disk_mb, 1024)
  assert_eq(notify.threshold_storm, 20)
  assert_eq(notify.daily_report_hour, 8)
}

///|
test "a project without a notify section is silent" {
  let config = @config.parse(project_doc(""), "/srv/yicode")
  assert_true(!config.notify.enabled)
  assert_eq(config.notify.targets.length(), 0)
}

///|
test "enabled without a target is rejected" {
  let message = notify_error("[notify]\nenabled = true\n")
  assert_true(message.contains("no [[notify.target]]"))
}

///|
test "a single target parses with all of its connection fields" {
  let notify = parse_notify(
    (
      #|[notify]
      #|enabled = true
      #|lang = "zh"
      #|
      #|[[notify.target]]
      #|platform = "feishu"
      #|url = "https://hook.example/a"
      #|secret = "sign"
      #|format = "markdown"
      #|
    ),
  )
  assert_true(notify.enabled)
  assert_eq(notify.lang, "zh")
  assert_eq(notify.targets.length(), 1)
  let target = notify.targets[0]
  assert_eq(target.platform, "feishu")
  assert_eq(target.url, "https://hook.example/a")
  assert_eq(target.secret, Some("sign"))
  assert_eq(target.format, Some("markdown"))
}

///|
test "omitting events takes every event" {
  let notify = parse_notify(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\n",
  )
  assert_eq(notify.targets[0].filter, @config.EventFilter::All)
}

///|
test "plain names are a whitelist" {
  let notify = parse_notify(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\nevents = [\"crash\", \"errored\"]\n",
  )
  assert_eq(
    notify.targets[0].filter,
    @config.EventFilter::Only(["crash", "errored"]),
  )
}

///|
test "bang names are an exclusion list" {
  let notify = parse_notify(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\nevents = [\"!lifecycle\", \"!daemon\"]\n",
  )
  let filter = notify.targets[0].filter
  assert_eq(filter, @config.EventFilter::Except(["lifecycle", "daemon"]))
  assert_true(filter.accepts("crash"))
  assert_true(!filter.accepts("lifecycle"))
}

///|
test "an empty events array is rejected" {
  let message = notify_error(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\nevents = []\n",
  )
  assert_true(message.contains("list at least one event"))
}

///|
test "mixing plain names and exclusions is rejected" {
  let message = notify_error(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\nevents = [\"crash\", \"!daemon\"]\n",
  )
  assert_true(message.contains("cannot mix"))
}

///|
test "an unknown event name is rejected" {
  let message = notify_error(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\nevents = [\"explosion\"]\n",
  )
  assert_true(message.contains("unknown event explosion"))
}

///|
test "daily_stats is a valid event name" {
  let notify = parse_notify(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\nevents = [\"daily_stats\"]\n",
  )
  assert_eq(
    notify.targets[0].filter,
    @config.EventFilter::Only(["daily_stats"]),
  )
}

///|
test "daily_report_hour only accepts 1 through 23" {
  let ok_low = parse_notify(
    "[notify]\nenabled = true\ndaily_report_hour = 1\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\n",
  )
  assert_eq(ok_low.daily_report_hour, 1)
  let ok_high = parse_notify(
    "[notify]\nenabled = true\ndaily_report_hour = 23\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\n",
  )
  assert_eq(ok_high.daily_report_hour, 23)
  let zero = notify_error(
    "[notify]\nenabled = true\ndaily_report_hour = 0\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\n",
  )
  assert_true(zero.contains("daily_report_hour"))
  let too_late = notify_error(
    "[notify]\nenabled = true\ndaily_report_hour = 24\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\n",
  )
  assert_true(too_late.contains("daily_report_hour"))
}

///|
test "email target borrows the mail channel and carries recipients" {
  let notify = parse_notify(
    (
      #|[notify]
      #|enabled = true
      #|mail_url = "smtps://smtp.example.com:465"
      #|mail_from = "bm2@example.com"
      #|
      #|[[notify.target]]
      #|platform = "email"
      #|to = ["ops@example.com", "boss@example.com"]
      #|events = ["crash"]
      #|
    ),
  )
  let target = notify.targets[0]
  assert_eq(target.url, "")
  assert_eq(target.mail_to, Some(["ops@example.com", "boss@example.com"]))
}

///|
test "email target without recipients is rejected" {
  let message = notify_error(
    "[notify]\nenabled = true\nmail_url = \"smtps://smtp.example.com:465\"\nmail_from = \"bm2@example.com\"\n[[notify.target]]\nplatform = \"email\"\n",
  )
  assert_true(message.contains(".to is required for email"))
}

///|
test "email target without the mail channel is rejected" {
  let message = notify_error(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"email\"\nto = [\"ops@example.com\"]\n",
  )
  assert_true(message.contains("no mail_url"))
}

///|
test "email target may not carry a url" {
  let message = notify_error(
    "[notify]\nenabled = true\nmail_url = \"smtps://smtp.example.com:465\"\nmail_from = \"bm2@example.com\"\n[[notify.target]]\nplatform = \"email\"\nto = [\"ops@example.com\"]\nurl = \"https://h/a\"\n",
  )
  assert_true(message.contains("url is not used by email"))
}

///|
test "a web target needs an http url" {
  let message = notify_error(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"hook.example/a\"\n",
  )
  assert_true(message.contains("http://"))
}

///|
test "a web target may not carry recipients" {
  let message = notify_error(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\nto = [\"ops@example.com\"]\n",
  )
  assert_true(message.contains("to is not used"))
}

///|
test "an unknown platform is rejected" {
  let message = notify_error(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"telegram\"\nurl = \"https://h/a\"\n",
  )
  assert_true(message.contains("unknown value telegram"))
}

///|
test "an unknown key inside a target is rejected" {
  let message = notify_error(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"feishu\"\nurl = \"https://h/a\"\nmin_level = \"error\"\n",
  )
  assert_true(message.contains("min_level"))
}

///|
test "several targets are parsed independently" {
  let notify = parse_notify(
    (
      #|[notify]
      #|enabled = true
      #|
      #|[[notify.target]]
      #|platform = "feishu"
      #|url = "https://h/ops"
      #|
      #|[[notify.target]]
      #|platform = "webhook"
      #|url = "https://h/stats"
      #|events = ["daily_stats"]
      #|
    ),
  )
  assert_eq(notify.targets.length(), 2)
  assert_eq(notify.targets[0].filter, @config.EventFilter::All)
  assert_eq(
    notify.targets[1].filter,
    @config.EventFilter::Only(["daily_stats"]),
  )
}
