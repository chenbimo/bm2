///|
/// A config fixture with a notify section the summary must count correctly:
/// one instant report with two targets, one periodic report with one target.
fn check_config() -> @config.Config {
  {
    name: "api",
    cwd: "/srv/api",
    script: "index.ts",
    runtime: "bun",
    exec_mode: "cluster",
    instances: 4,
    port: 3020,
    max_memory_mb: 0,
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
      events: ["crash"],
      threshold_rss_percent: 0,
      threshold_offline_min: 0,
      threshold_restarts: 0,
      start_timeout_ms: 0,
      threshold_disk_mb: 0,
      threshold_storm: 0,
      reports: [
        {
          name: "t1",
          label: None,
          events: Some(["crash"]),
          min_level: None,
          cron: None,
          cron_text: None,
          template: None,
          targets: [
            {
              platform: "feishu",
              url: "https://x/y",
              secret: None,
              format: None,
              mail_to: None,
            },
            {
              platform: "email",
              url: "",
              secret: None,
              format: None,
              mail_to: Some(["a@b.c"]),
            },
          ],
        },
        {
          name: "t2",
          label: None,
          events: None,
          min_level: None,
          cron: Some({
            minutes: [0],
            hours: [8],
            days_of_month: [1],
            months: [1],
            days_of_week: [0, 1, 2, 3, 4, 5, 6],
          }),
          cron_text: Some("0 8 * * *"),
          template: Some("health"),
          targets: [
            {
              platform: "webhook",
              url: "https://x/z",
              secret: None,
              format: None,
              mail_to: None,
            },
          ],
        },
      ],
    },
    env: [],
  }
}

///|
test "check_summary counts reports, targets and periodic entries" {
  let text = check_summary(check_config())
  // Identity and layout first.
  assert_true(text.contains("project \"api\""))
  assert_true(text.contains("4 x cluster on port 3020"))
  assert_true(text.contains("runtime bun"))
  // Notify line: 2 reports, 3 targets total, 1 periodic (t2 has a template).
  assert_true(text.contains("notify: 2 report(s), 3 target(s), 1 periodic"))
}

///|
test "check_summary says disabled without a notify section" {
  let config = check_config()
  let quiet = { ..config, notify: { ..config.notify, enabled: false, }, }
  assert_true(check_summary(quiet).contains("notify: disabled"))
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
  assert_true(check_project(config, probe) is None)
  assert_true(seen == "/srv/api/index.ts")
  let missing = fn(_path : String) -> Bool { false }
  match check_project(config, missing) {
    Some(problem) => assert_true(problem.contains("script not found"))
    None => fail("expected the missing script to be reported")
  }
}
