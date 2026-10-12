///|
/// The `[notify]` section is part of bm2.toml, so it is rejected or accepted by
/// the same project parse the CLI and the daemon use. Notification settings get
/// the same treatment as the rest of the file: closed sets, explicit bounds, and
/// messages that name the field without ever echoing a credential.

///|
/// One project document with the given notification section appended, so each
/// case exercises the real parse path rather than a parser of its own.
fn project_doc(notify_section : String) -> String {
  "name = \"blog\"\nscript = \"index.ts\"\ninstances = 1\nport = 3000\n" +
  notify_section
}

///|
fn notify_error(notify_section : String) -> String raise {
  parse_error(project_doc(notify_section))
}

///|
test "parses reports with endpoints, schedules and mail channel" {
  let config = @config.parse(
    project_doc(
      (
        #|[notify]
        #|enabled = true
        #|lang = "zh"
        #|dedupe_window_s = 60
        #|events = ["crash", "errored", "lifecycle"]
        #|
        #|mail_url = "smtps://smtp.example.com:465"
        #|mail_from = "bm2@example.com"
        #|
        #|[[notify.report]]
        #|name = "故障告警"
        #|events = ["crash", "errored"]
        #|min_level = "warn"
        #|
        #|[[notify.report.target]]
        #|platform = "feishu"
        #|url = "https://hook.example/feishu-a"
        #|secret = "sign-a"
        #|
        #|[[notify.report.target]]
        #|platform = "email"
        #|to = ["ops@example.com"]
        #|
        #|[[notify.report]]
        #|name = "健康巡检"
        #|cron = "*/5 * * * *"
        #|template = "health"
        #|
        #|[[notify.report.target]]
        #|platform = "feishu"
        #|url = "https://hook.example/feishu-b"
        #|
      ),
    ),
    "/srv/yicode",
  )
  let notify = config.notify
  assert_true(notify.enabled)
  assert_eq(notify.lang, "zh")
  assert_eq(notify.events.length(), 3)
  assert_eq(notify.mail_from, Some("bm2@example.com"))
  assert_eq(notify.reports.length(), 2)
  let alert = notify.reports[0]
  assert_eq(alert.name, "故障告警")
  assert_eq(alert.events, Some(["crash", "errored"]))
  assert_eq(alert.cron, None)
  assert_eq(alert.targets.length(), 2)
  assert_eq(alert.targets[0].platform, "feishu")
  assert_eq(alert.targets[0].url, "https://hook.example/feishu-a")
  assert_eq(alert.targets[0].secret, Some("sign-a"))
  assert_eq(alert.targets[1].mail_to.unwrap().length(), 1)
  let poll = notify.reports[1]
  assert_eq(poll.cron_text, Some("*/5 * * * *"))
  assert_eq(poll.template, Some("health"))
  assert_eq(poll.events, None)
}

///|
test "a project without a notify section reports nothing" {
  let config = @config.parse(project_doc(""), "/srv/yicode")
  assert_false(config.notify.enabled)
  assert_eq(config.notify.reports.length(), 0)
}

///|
test "notify rejects unknown keys, platforms and enum values" {
  assert_true(
    notify_error("[notify]\nenabled = true\nnope = 1\n").contains(
      "unknown field nope",
    ),
  )
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"a\"\ncron = \"0 8 * * *\"\ntemplate = \"health\"\n\n[[notify.report.target]]\nplatform = \"carrier-pigeon\"\nurl = \"https://x/y\"\n",
    ).contains("platform has unknown value carrier-pigeon"),
  )
  assert_true(
    notify_error("[notify]\nevents = [\"explode\"]\n").contains(
      "unknown value explode",
    ),
  )
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"a\"\n\n[[notify.report.target]]\nplatform = \"webhook\"\nurl = \"https://x/y\"\nformat = \"pdf\"\n",
    ).contains("unknown value pdf"),
  )
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"a\"\n\n[[notify.report.target]]\nplatform = \"webhook\"\nurl = \"https://x/y\"\nmin_level = \"fatal\"\n",
    ).contains("unknown field min_level"),
  )
  assert_true(
    notify_error("[notify]\nthreshold_disk_mb = 1048577\n").contains(
      "notify.threshold_disk_mb must be between",
    ),
  )
  assert_true(
    notify_error("[notify]\ntimeout_ms = 10\n").contains(
      "notify.timeout_ms must be between",
    ),
  )
  assert_true(
    notify_error("[notify]\nqueue_size = 0\n").contains(
      "notify.queue_size must be between",
    ),
  )
}

///|
test "notify enforces per-platform endpoint rules" {
  // Web endpoints need http(s); email endpoints need recipients and a
  // configured mail channel.
  assert_true(
    notify_error(
      "[notify]\nmail_url = \"smtps://smtp.example.com:465\"\n\n[[notify.report]]\nname = \"a\"\n\n[[notify.report.target]]\nplatform = \"webhook\"\nurl = \"smtp://x:25\"\n",
    ).contains("must start with"),
  )
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"a\"\n\n[[notify.report.target]]\nplatform = \"email\"\nto = [\"d@e.f\"]\n",
    ).contains("notify has no mail_url"),
  )
  assert_true(
    notify_error(
      "[notify]\nmail_url = \"smtps://smtp.example.com:465\"\n\n[[notify.report]]\nname = \"a\"\n\n[[notify.report.target]]\nplatform = \"email\"\n",
    ).contains("email.to is required"),
  )
  assert_true(
    notify_error(
      "[notify]\nmail_url = \"smtps://smtp.example.com:465\"\n\n[[notify.report]]\nname = \"a\"\n\n[[notify.report.target]]\nplatform = \"feishu\"\nurl = \"https://x/y\"\nto = [\"d@e.f\"]\n",
    ).contains("to is not used by this platform"),
  )
  // Exactly one platform object per endpoint.
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"a\"\n\n[[notify.report.target]]\nplatform = \"feishu\"\nurl = \"https://x/y\"\n\n[notify.report.target.feishu]\nurl = \"https://x/y\"\n",
    ).contains("unknown field feishu"),
  )
  assert_true(
    notify_error("[notify]\n\n[[notify.report]]\nname = \"a\"\n").contains(
      "at least one",
    ),
  )
}

///|
test "notify errors never echo a url, secret or password" {
  let message = notify_error(
    (
      #|[notify]
      #|
      #|[[notify.report]]
      #|name = "leaky"
      #|
      #|[[notify.report.target]]
      #|platform = "carrier-pigeon"
      #|url = "https://gateway.example/hook?token=URLSECRET"
      #|secret = "TOPSECRET"
      #|mail_password = "PASSSECRET"
      #|
    ),
  )
  assert_true(message.contains("notify.report[0]"))
  assert_false(message.contains("URLSECRET"))
  assert_false(message.contains("TOPSECRET"))
  assert_false(message.contains("PASSSECRET"))
  assert_false(message.contains("gateway.example"))
}

///|
test "periodic report requires template and instant report rejects it" {
  // cron without template is rejected.
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"t\"\ncron = \"*/5 * * * *\"\n\n[[notify.report.target]]\nplatform = \"feishu\"\nurl = \"https://x/y\"\n",
    ).contains("cron requires template"),
  )
  // template without cron is rejected.
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"t\"\ntemplate = \"health\"\n\n[[notify.report.target]]\nplatform = \"feishu\"\nurl = \"https://x/y\"\n",
    ).contains("template requires cron"),
  )
  // Unknown template preset is rejected.
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"t\"\ncron = \"*/5 * * * *\"\ntemplate = \"weekly_summary\"\n\n[[notify.report.target]]\nplatform = \"feishu\"\nurl = \"https://x/y\"\n",
    ).contains("unknown value weekly_summary"),
  )
  // Periodic reports take no event routing.
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"t\"\ncron = \"*/5 * * * *\"\ntemplate = \"health\"\nevents = [\"crash\"]\n\n[[notify.report.target]]\nplatform = \"feishu\"\nurl = \"https://x/y\"\n",
    ).contains("events is not used by a periodic report"),
  )
  // A valid periodic report parses with its schedule.
  let config = @config.parse(
    project_doc(
      (
        #|[notify]
        #|enabled = true
        #|
        #|[[notify.report]]
        #|name = "health"
        #|cron = "*/5 * * * *"
        #|template = "health"
        #|
        #|[[notify.report.target]]
        #|platform = "feishu"
        #|url = "https://x/y"
      ),
    ),
    "/srv/yicode",
  )
  let report = config.notify.reports[0]
  assert_eq(report.template, Some("health"))
  assert_eq(report.cron_text, Some("*/5 * * * *"))
  let spec = report.cron.unwrap()
  // */5 expands to [0,5,10,...,55]
  assert_eq(spec.minutes.length(), 12)
  assert_eq(spec.minutes[0], 0)
  assert_eq(spec.minutes[1], 5)
  assert_eq(spec.hours.length(), 24)
}

///|
test "cron rejects malformed fields and the double day restriction" {
  // Four fields instead of five.
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"t\"\ncron = \"*/5 * * *\"\n\n[[notify.report.target]]\nplatform = \"feishu\"\nurl = \"https://x/y\"\n",
    ).contains("five fields"),
  )
  // Step syntax works.
  let config = @config.parse(
    project_doc(
      (
        #|[notify]
        #|
        #|[[notify.report]]
        #|name = "t"
        #|cron = "0 */6 * * *"
        #|template = "health"
        #|
        #|[[notify.report.target]]
        #|platform = "feishu"
        #|url = "https://x/y"
      ),
    ),
    "/srv/yicode",
  )
  let spec = config.notify.reports[0].cron.unwrap()
  assert_eq(spec.hours.length(), 4)
  // Day-of-month and day-of-week both restricted is rejected.
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"t\"\ncron = \"0 8 1 * 1\"\n\n[[notify.report.target]]\nplatform = \"feishu\"\nurl = \"https://x/y\"\n",
    ).contains("both day-of-month and day-of-week"),
  )
  // Out-of-range values are rejected.
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"t\"\ncron = \"0 25 * * *\"\n\n[[notify.report.target]]\nplatform = \"feishu\"\nurl = \"https://x/y\"\n",
    ).contains("must be between"),
  )
}

///|
test "new threshold fields parse, default off and validate their ranges" {
  let config = @config.parse(
    project_doc(
      (
        #|[notify]
        #|enabled = true
        #|start_timeout_ms = 30000
        #|threshold_disk_mb = 1024
        #|threshold_storm = 10
        #|events = ["crash", "oom_kill", "disk_pressure", "start_timeout"]
      ),
    ),
    "/srv/yicode",
  )
  assert_eq(config.notify.start_timeout_ms, 30000)
  assert_eq(config.notify.threshold_disk_mb, 1024)
  assert_eq(config.notify.threshold_storm, 10)
  assert_eq(config.notify.events.length(), 4)
  // Absent means disabled.
  let plain = @config.parse(
    project_doc(
      (
        #|[notify]
        #|enabled = true
      ),
    ),
    "/srv/yicode",
  )
  assert_eq(plain.notify.start_timeout_ms, 0)
  assert_eq(plain.notify.threshold_disk_mb, 0)
  assert_eq(plain.notify.threshold_storm, 0)
  // Ranges are enforced.
  assert_true(
    notify_error("[notify]\nstart_timeout_ms = 600001\n").contains(
      "start_timeout_ms must be between",
    ),
  )
  assert_true(
    notify_error("[notify]\nthreshold_disk_mb = 1048577\n").contains(
      "threshold_disk_mb must be between",
    ),
  )
  assert_true(
    notify_error("[notify]\nthreshold_storm = 1001\n").contains(
      "threshold_storm must be between",
    ),
  )
  // The new events are known values; a typo stays rejected.
  assert_true(
    notify_error("[notify]\nevents = [\"oom_killed\"]\n").contains(
      "unknown value oom_killed",
    ),
  )
}

///|
test "expand_with resolves placeholders through the lookup" {
  let vars = Map([("BM2_URL", "https://hook.example/abc"), ("BM2_PATH", "x")])
  let lookup = fn(name : String) -> String? { vars.get(name) }
  assert_eq(
    @config.expand_with("${BM2_URL}", "t", lookup),
    "https://hook.example/abc",
  )
  assert_eq(
    @config.expand_with(
      "https://hook.example/${BM2_PATH}?key=${BM2_URL}", "t", lookup,
    ),
    "https://hook.example/x?key=https://hook.example/abc",
  )
  assert_eq(
    @config.expand_with("https://plain.example/hook", "t", lookup),
    "https://plain.example/hook",
  )
  // A literal ${ with no closing brace is a config mistake, not a lookup.
  try @config.expand_with("https://x/${oops", "t", lookup) catch {
    _ => assert_true(true)
  } noraise {
    _ => assert_true(false)
  }
}

///|
test "expand_with rejects unset variables and bad names" {
  fn expand_error(value : String) -> String {
    try
      @config.expand_with(value, "t", fn(_name : String) -> String? { None })
    catch {
      e => e.to_string()
    } noraise {
      _ => "no-error"
    }
  }
  let message = expand_error("${BM2_SECRET_URL}")
  assert_true(message.contains("BM2_SECRET_URL"))
  assert_true(message.contains("which is not set"))
  assert_false(message.contains("https://"))
  // Names must look like environment variables.
  fn rejects(value : String) -> Bool {
    try
      @config.expand_with(value, "t", fn(_name : String) -> String? {
        Some("x")
      })
    catch {
      _ => true
    } noraise {
      _ => false
    }
  }
  assert_true(rejects("${}"))
  assert_true(rejects("${9BAD}"))
  assert_true(rejects("${A-B}"))
}

///|
test "parse expands ${VAR} anywhere in the notify tree" {
  @env.set_env_var("BM2_TEST_HOOK", "https://hook.example/from-env")
  @env.set_env_var("BM2_TEST_KEY", "sign-key")
  @env.set_env_var("BM2_TEST_MAIL", "smtps://smtp.example.com:465")
  let config = @config.parse(
    project_doc(
      (
        #|[notify]
        #|enabled = true
        #|mail_url = "${BM2_TEST_MAIL}"
        #|
        #|[[notify.report]]
        #|name = "t"
        #|
        #|[[notify.report.target]]
        #|platform = "feishu"
        #|url = "${BM2_TEST_HOOK}"
        #|secret = "${BM2_TEST_KEY}"
      ),
    ),
    "/srv/yicode",
  )
  assert_eq(config.notify.mail_url, Some("smtps://smtp.example.com:465"))
  let endpoint = config.notify.reports[0].targets[0]
  assert_eq(endpoint.url, "https://hook.example/from-env")
  assert_eq(endpoint.secret, Some("sign-key"))
  @env.unset_env_var("BM2_TEST_HOOK")
  @env.unset_env_var("BM2_TEST_KEY")
  @env.unset_env_var("BM2_TEST_MAIL")
  // With the variable gone the same config fails, naming the variable.
  assert_true(
    notify_error(
      "[notify]\n\n[[notify.report]]\nname = \"t\"\n\n[[notify.report.target]]\nplatform = \"feishu\"\nurl = \"${BM2_TEST_HOOK}\"\n",
    ).contains("BM2_TEST_HOOK which is not set"),
  )
}

///|
test "notify lang is a closed set defaulting to en" {
  let config = @config.parse(
    project_doc(
      (
        #|[notify]
        #|enabled = true
        #|lang = "zh"
      ),
    ),
    "/srv/yicode",
  )
  assert_eq(config.notify.lang, "zh")
  let plain = @config.parse(
    project_doc(
      (
        #|[notify]
        #|enabled = true
      ),
    ),
    "/srv/yicode",
  )
  assert_eq(plain.notify.lang, "en")
  assert_true(
    notify_error("[notify]\nlang = \"fr\"\n").contains(
      "notify.lang has unknown value fr",
    ),
  )
}
