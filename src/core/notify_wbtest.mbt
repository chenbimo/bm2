///|
/// Tests for bm2's notification adapter: subscription filtering, policy-driven
/// dedupe/rate/queue behaviour and the CPU sampler. Rendering, signing and the
/// engine itself are covered by the chensuiyi/notify suite.

///|
fn wb_report(
  events? : Array[String],
  min_level? : String,
  cron? : @config.CronSpec,
  template? : String,
  targets? : Array[@config.NotifyEndpoint],
) -> @config.NotifyReport {
  {
    name: "t",
    label: None,
    events,
    min_level,
    cron,
    cron_text: None,
    template,
    targets: targets.unwrap_or([]),
  }
}

///|
fn wb_message(
  event : String,
  level : String,
  ts_ms : UInt64,
) -> @notify.Message {
  @notify.Message::new(
    event,
    level,
    "api · Abnormal exit, restarting automatically",
    "exit code 1",
    "crash|api|0|exit_code",
    ts_ms,
    fields=[("app", "api"), ("port", "3000")],
  )
}

///|
/// Parse a bm2.toml carrying the given `[notify]` section and hand back its
/// policy — the same path the daemon takes when it loads a project.
fn wb_policy(notify_section : String) -> @config.NotifyConfig raise {
  let doc = "name = \"api\"\nscript = \"index.ts\"\ninstances = 1\nport = 3000\n" +
    notify_section
  @config.parse(doc, "/srv/api").notify
}

///|
fn wb_notifier(tag : String) -> Notifier {
  Notifier::new("/tmp/bm2-notify-\{tag}-\{@subproc.get_pid()}", "host1")
}

///|
test "dedupe counts repeats and the rate limit drops the rest" {
  let policy = wb_policy(
    (
      #|[notify]
      #|enabled = true
      #|dedupe_window_s = 3600
      #|max_per_minute = 2
      #|queue_size = 8
      #|events = ["crash"]
      #|
      #|[[notify.report]]
      #|name = "t"
      #|events = ["crash"]
      #|
      #|[[notify.report.target]]
      #|platform = "webhook"
      #|url = "http://127.0.0.1:9/hook"
      #|
    ),
  )
  let notifier = wb_notifier("dedupe")
  assert_true(policy.enabled)
  // Same signature inside the window: queued once, the rest counted.
  notifier.emit(policy, "api", wb_message("crash", "warn", 1000UL))
  notifier.emit(policy, "api", wb_message("crash", "warn", 2000UL))
  notifier.emit(policy, "api", wb_message("crash", "warn", 3000UL))
  assert_eq(notifier.queued(), 1)
  // A different signature is a different event.
  notifier.emit(
    policy,
    "api",
    @notify.Message::new(
      "crash", "warn", "other", "body", "crash|api|1", 3000UL,
    ),
  )
  assert_eq(notifier.queued(), 2)
}

///|
test "rate limiting and queue overflow are counted, never unbounded" {
  let policy = wb_policy(
    (
      #|[notify]
      #|enabled = true
      #|dedupe_window_s = 0
      #|max_per_minute = 1
      #|queue_size = 2
      #|events = ["crash"]
      #|
      #|[[notify.report]]
      #|name = "t"
      #|events = ["crash"]
      #|
      #|[[notify.report.target]]
      #|platform = "webhook"
      #|url = "http://127.0.0.1:9/hook"
      #|
    ),
  )
  let notifier = wb_notifier("limit")
  notifier.emit(
    policy,
    "api",
    @notify.Message::new("crash", "warn", "a", "b", "s1", 1000UL),
  )
  // Each owner has its own minute budget: the second and third emissions of
  // the same project are rate limited, never queued.
  notifier.emit(
    policy,
    "api",
    @notify.Message::new("crash", "warn", "a", "b", "s2", 1000UL),
  )
  notifier.emit(
    policy,
    "api",
    @notify.Message::new("crash", "warn", "a", "b", "s3", 1000UL),
  )
  assert_eq(notifier.queued(), 1)
  assert_eq(notifier.dropped(), 2)
  // An unsubscribed event never queues at all.
  notifier.emit(
    policy,
    "api",
    @notify.Message::new("report", "info", "r", "b", "s4", 1000UL),
  )
  assert_eq(notifier.queued(), 1)
  // Another project's events queue separately, with its own minute budget.
  notifier.emit(
    policy,
    "other",
    @notify.Message::new("crash", "warn", "a", "b", "s5", 1000UL),
  )
  assert_eq(notifier.queued(), 2)
}

///|
test "per-report subscriptions and level floors are honoured" {
  let config = wb_policy(
    (
      #|[notify]
      #|enabled = true
      #|events = ["crash"]
      #|
    ),
  )
  let quiet = wb_report(min_level="error")
  let crashing = wb_report(events=["crash"])
  let periodic = wb_report(
    cron=@config.CronSpec::{
      minutes: [0],
      hours: [8],
      days_of_month: [1],
      months: [1],
      days_of_week: [0, 1, 2, 3, 4, 5, 6],
    },
    template="health",
  )
  // Level floor: warn sits below the error floor.
  assert_false(wants(quiet, config, wb_message("crash", "warn", 1000UL)))
  assert_true(wants(quiet, config, wb_message("crash", "error", 1000UL)))
  // Subscription: errored is not in these reports' events list.
  assert_false(wants(crashing, config, wb_message("errored", "warn", 1000UL)))
  // No level floor on crashing: any level of a subscribed event passes.
  assert_true(wants(crashing, config, wb_message("crash", "warn", 1000UL)))
  // Periodic reports never take events, whatever their own subscription.
  assert_false(wants(periodic, config, wb_message("crash", "error", 1000UL)))
}

///|
async test "a failed delivery reports a reason without the credential" {
  let policy = wb_policy(
    (
      #|[notify]
      #|enabled = true
      #|queue_size = 4
      #|events = ["crash"]
      #|
      #|[[notify.report]]
      #|name = "dead"
      #|events = ["crash"]
      #|
      #|[[notify.report.target]]
      #|platform = "webhook"
      #|url = "http://127.0.0.1:9/hook?token=SECRET"
      #|secret = "TOPSECRET"
      #|
    ),
  )
  let notifier = wb_notifier("fail")
  let endpoints = []
  for report in policy.reports {
    for endpoint in report.targets {
      endpoints.push(endpoint)
    }
  }
  let results = notifier.deliver_now(
    endpoints,
    policy,
    policy.timeout_ms,
    @notify.Message::new("crash", "warn", "t", "b", "s", 1000UL),
  )
  assert_eq(results.length(), 1)
  let (name, failure) = results[0]
  assert_eq(name, "webhook")
  let reason = match failure {
    Some(reason) => reason
    None => fail("expected the unreachable target to fail")
  }
  assert_false(reason.is_empty())
  // Neither the URL, its token, nor the header credential may leak into a
  // reason that the CLI and the event log print.
  assert_false(reason.contains("SECRET"))
  assert_false(reason.contains("127.0.0.1"))
  assert_false(reason.contains("TOPSECRET"))
}

///|
test "cpu percent needs a baseline before it reports anything" {
  let notifier = wb_notifier("cpu")
  let dir = "/tmp/bm2-notify-cpu-\{@subproc.get_pid()}"
  @fsx.mkdir_p(dir)
  let pid = @subproc.spawn({
    bun_path: "/bin/sh",
    script: "-c\u{0}i=0; while true; do i=$((i+1)); done",
    cwd: dir,
    out_log: "",
    err_log: "",
    env_blob: @subproc.base_env_blob(),
  })
  // First sample only sets the baseline: no percentage can be derived yet.
  assert_true(notifier.cpu_percent("k", pid, 1000UL) is None)
  @subproc.sleep_ms(300)
  match notifier.cpu_percent("k", pid, 1400UL) {
    Some(percent) => assert_true(percent >= 0.0)
    None => fail("expected a cpu percentage once a baseline exists")
  }
  @fndash.discard(() => @subproc.kill_group(pid, @subproc.SIGKILL))
  @subproc.drain_child(pid)
}

///|
/// RSS peaks are windowed: the biggest sample wins, taking clears the window,
/// and the report window and the daily window stay independent.
test "rss peak windows track maxima and clear on take" {
  let notifier = wb_notifier("peak")
  let key = "api/0"
  notifier.record_rss(key, 100)
  notifier.record_rss(key, 300)
  notifier.record_rss(key, 200)
  assert_eq(notifier.take_report_peak(key), Some(300))
  // Taking clears: the next report starts a fresh window.
  assert_eq(notifier.take_report_peak(key), None)
  // The daily window was recording all along and is untouched by report takes.
  assert_eq(notifier.take_daily_peak(key), Some(300))
  assert_eq(notifier.take_daily_peak(key), None)
  // An instance that was never sampled reports nothing.
  assert_eq(notifier.take_report_peak("other/9"), None)
}
