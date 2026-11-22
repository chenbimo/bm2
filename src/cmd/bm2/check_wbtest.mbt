///|
/// A config fixture with three targets: two take every event, one only takes the
/// daily stats. The summary must count targets and say whether stats go out.
fn check_config() -> @config.Config {
  {
    name: "api",
    lang: None,
    logs: @config.LogsConfig::builtin(),
    cwd: "/srv/api",
    script: "index.ts",
    runtime: "bun",
    exec_mode: "cluster",
    instances: 4,
    port: 3020,
    max_memory_mb: 0,
    max_tree_processes: 512,
    max_restarts: 10,
    restart_delay_ms: 1000,
    min_uptime_ms: 0,
    stop_timeout_ms: 3000,
    notify: {
      enabled: true,
      mail_url: None,
      mail_from: None,
      mail_username: None,
      mail_password: None,
      lang: "en",
      timeout_ms: 5000,
      dedupe_window_s: 3600,
      max_per_minute: 30,
      queue_size: 128,
      daily_report_hour: 8,
      threshold_rss_percent: 0,
      threshold_offline_min: 0,
      threshold_restarts: 0,
      start_timeout_ms: 0,
      threshold_disk_mb: 0,
      threshold_storm: 0,
      targets: [
        {
          platform: "feishu",
          url: "https://x/y",
          secret: None,
          format: None,
          mail_to: None,
          filter: @config.EventFilter::All,
        },
        {
          platform: "webhook",
          url: "https://x/z",
          secret: None,
          format: None,
          mail_to: None,
          filter: @config.EventFilter::Except(["lifecycle"]),
        },
        {
          platform: "email",
          url: "",
          secret: None,
          format: None,
          mail_to: Some(["a@b.c"]),
          filter: @config.EventFilter::Only(["daily_stats"]),
        },
      ],
    },
  }
}

///|
test "check_summary counts targets and reports the daily stats schedule" {
  let text = check_summary(check_config(), @i18n.Lang::En)
  // Identity and layout first.
  assert_true(text.contains("project \"api\""))
  assert_true(text.contains("4 x cluster on port 3020"))
  assert_true(text.contains("runtime bun"))
  // Notify line: 3 targets, and one of them takes the daily stats at 08:00.
  assert_true(text.contains("notify: 3 target(s), daily stats at 8:00"))
}

///|
test "check_summary says disabled without a notify section" {
  let config = check_config()
  let quiet = { ..config, notify: { ..config.notify, enabled: false, }, }
  assert_true(check_summary(quiet, @i18n.Lang::En).contains("notify: disabled"))
}

///|
test "check_project reports a missing script, nothing when present" {
  let config = check_config()
  // The probed path is cwd + "/" + script.
  let mut seen = ""
  let probe = fn(path : String) -> Bool {
    seen = path
    path.contains("index.ts")
  }
  assert_true(check_project(config, probe, @i18n.Lang::En) is None)
  assert_true(seen == "/srv/api/index.ts")
  let missing = fn(_path : String) -> Bool { false }
  match check_project(config, missing, @i18n.Lang::En) {
    Some(problem) => assert_true(problem.contains("script not found"))
    None => fail("expected the missing script to be reported")
  }
}
