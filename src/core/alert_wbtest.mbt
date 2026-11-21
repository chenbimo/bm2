///|
/// Tests for bm2's notification adapter: per-target event filtering, the
/// policy-driven dedupe/rate/queue behaviour and the CPU sampler. Rendering,
/// signing and the engine itself are covered by the notify package's own suite.

///|
/// Bulk drops are counted, not announced: one event line per reporting window,
/// with the count of everything since the previous line in the detail.
test "bulk drops are reported once per window" {
  let window : DropWindow = { since_ms: 0UL, count: 0, }
  // The first drop is reported immediately.
  assert_eq(window.note(1000UL), Some(1))
  // Everything inside the window is counted but stays quiet.
  assert_eq(window.note(2000UL), None)
  assert_eq(window.note(30000UL), None)
  // The next report carries everything since the previous one: the 1000ms drop
  // was already reported, so it is the two later ones plus this call.
  assert_eq(window.note(61000UL), Some(3))
  assert_eq(window.note(62000UL), None)
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
/// A supervision-side notifier plus the delivery-side runner, wired over one
/// queue exactly as the daemon wires them.
fn wb_pair(tag : String) -> (Notifier, NotifyRunner) {
  let dir = "/tmp/bm2-notify-\{tag}-\{@proc.get_pid()}"
  @utils.discard(() => @fsx.mkdir_p(dir))
  let queue : @aqueue.Queue[Outbound] = @aqueue.Queue::Queue(kind=Blocking(64))
  (Notifier::new(dir, "host1", queue), NotifyRunner::new(dir, "host1", queue))
}

///|
fn wb_notifier(tag : String) -> Notifier {
  let (notifier, _) = wb_pair(tag)
  notifier
}

///|
/// 过滤是纯函数：三态各自的判定，以及一个"没人收"的事件不进队列。
test "event filters decide which targets receive an event" {
  let all = @config.EventFilter::All
  let only = @config.EventFilter::Only(["crash"])
  let except = @config.EventFilter::Except(["lifecycle"])
  assert_true(all.accepts("lifecycle"))
  assert_true(all.accepts("daily_stats"))
  assert_true(only.accepts("crash"))
  assert_false(only.accepts("lifecycle"))
  assert_false(except.accepts("lifecycle"))
  assert_true(except.accepts("daily_stats"))
  let policy = wb_policy(
    "[notify]\nenabled = true\n[[notify.target]]\nplatform = \"webhook\"\nurl = \"http://127.0.0.1:9/hook\"\nevents = [\"crash\"]\n",
  )
  let (notifier, runner) = wb_pair("filter")
  notifier.emit(policy, "api", wb_message("lifecycle", "info", 1000UL))
  runner.drain(1000UL)
  assert_eq(runner.queued(), 0)
  notifier.emit(policy, "api", wb_message("crash", "warn", 1000UL))
  runner.drain(1000UL)
  assert_eq(runner.queued(), 1)
}

///|
/// 每条消息都自带事件名，且与项目配的通知语言一致：群里看得到「实例崩溃」，
/// 而不是靠标题猜它对应配置里的哪个键。
test "every message carries its event name in the project language" {
  let msg = @notify.Message::new(
    "crash",
    "warn",
    "api · 实例异常退出",
    "退出码 1",
    "crash|api|0",
    1000UL,
    fields=[("app", "api")],
  )
  let zh = with_event_label("zh", msg)
  assert_eq(zh.event_label, "实例崩溃")
  // 中文项目的字段区全是中文名：事件名占首行，其余字段跟在后面。
  assert_eq(zh.fields[0], ("事件", "实例崩溃"))
  assert_eq(zh.fields[1], ("应用", "api"))
  assert_eq(with_event_label("en", msg).event_label, "Instance crash")
  // 英文项目的字段键保持原样，脚本与既有消费方不用改。
  let en = with_event_label("en", msg)
  assert_eq(en.fields[0], ("event", "Instance crash"))
  assert_eq(en.fields[1], ("app", "api"))
  // 十一个事件都有名字，且两种语言都不回落到键名。
  for
    event in [
      "crash", "errored", "memory_limit", "oom_kill", "reuseport_missing", "lifecycle",
      "daemon", "threshold", "disk_pressure", "start_timeout", "daily_stats",
    ] {
    assert_true(event_label("zh", event) != event)
    assert_true(event_label("en", event) != event)
  }
  // 不认识的键原样回显，不空着。
  assert_eq(
    with_event_label("zh", { ..msg, event: "future_event", }).event_label,
    "future_event",
  )
}

///|
/// 字段名同样跟随项目语言：中文项目看到的是「应用」「运行时长」，
/// 英文项目保持原来的键。未收录的键原样回显，不空着。
fn field_label_cases() -> Array[(String, String)] {
  [
    ("event", "事件"),
    ("app", "应用"),
    ("project", "项目"),
    ("host", "主机"),
    ("instance", "实例"),
    ("mode", "模式"),
    ("port", "端口"),
    ("PID", "进程号"),
    ("status", "状态"),
    ("starts", "启动次数"),
    ("crashes", "崩溃次数"),
    ("uptime", "运行时长"),
    ("online", "在线"),
    ("abnormal", "异常"),
    ("load1", "1 分钟负载"),
    ("disk_free", "磁盘余量"),
    ("peak_mb", "内存峰值"),
    ("restarts", "自动重启"),
  ]
}

///|
test "field names follow the notification language" {
  for pair in field_label_cases() {
    let (key, zh) = pair
    assert_eq(field_label("zh", key), zh)
    assert_eq(field_label("en", key), key)
  }
  assert_eq(field_label("zh", "unknown_key"), "unknown_key")
}

///|
/// 测试消息是它自己的一类，不再冒充生命周期事件。
test "the test message reports itself as a test message" {
  let msg = test_message(1000UL, lang="zh")
  assert_eq(msg.event, "notify_test")
  assert_eq(with_event_label("zh", msg).event_label, "测试消息")
  assert_eq(with_event_label("en", msg).event_label, "Test message")
}

///|
test "dedupe counts repeats and the rate limit drops the rest" {
  let policy = wb_policy(
    "[notify]\nenabled = true\ndedupe_window_s = 3600\nmax_per_minute = 2\nqueue_size = 8\n[[notify.target]]\nplatform = \"webhook\"\nurl = \"http://127.0.0.1:9/hook\"\n",
  )
  let (notifier, runner) = wb_pair("dedupe")
  assert_true(policy.enabled)
  // Same signature inside the window: queued once, the rest counted.
  notifier.emit(policy, "api", wb_message("crash", "warn", 1000UL))
  notifier.emit(policy, "api", wb_message("crash", "warn", 2000UL))
  notifier.emit(policy, "api", wb_message("crash", "warn", 3000UL))
  runner.drain(1000UL)
  assert_eq(runner.queued(), 1)
  // A different signature is a different event.
  notifier.emit(
    policy,
    "api",
    @notify.Message::new(
      "crash", "warn", "other", "body", "crash|api|1", 3000UL,
    ),
  )
  runner.drain(1000UL)
  assert_eq(runner.queued(), 2)
}

///|
test "rate limiting and queue overflow are counted, never unbounded" {
  let policy = wb_policy(
    "[notify]\nenabled = true\ndedupe_window_s = 0\nmax_per_minute = 1\nqueue_size = 2\n[[notify.target]]\nplatform = \"webhook\"\nurl = \"http://127.0.0.1:9/hook\"\nevents = [\"crash\"]\n",
  )
  let (notifier, runner) = wb_pair("limit")
  notifier.emit(
    policy,
    "api",
    @notify.Message::new("crash", "warn", "a", "b", "s1", 1000UL),
  )
  runner.drain(1000UL)
  // Each owner has its own minute budget: the second and third emissions of
  // the same project are rate limited, never queued.
  notifier.emit(
    policy,
    "api",
    @notify.Message::new("crash", "warn", "a", "b", "s2", 1000UL),
  )
  runner.drain(1000UL)
  notifier.emit(
    policy,
    "api",
    @notify.Message::new("crash", "warn", "a", "b", "s3", 1000UL),
  )
  runner.drain(1000UL)
  assert_eq(runner.queued(), 1)
  assert_eq(runner.dropped(), 2)
  // 没有目标接收的事件连队列都不进，也不算丢弃。
  notifier.emit(
    policy,
    "api",
    @notify.Message::new("lifecycle", "info", "r", "b", "s4", 1000UL),
  )
  runner.drain(1000UL)
  assert_eq(runner.queued(), 1)
  assert_eq(runner.dropped(), 2)
  // Another project's events queue separately, with its own minute budget.
  notifier.emit(
    policy,
    "other",
    @notify.Message::new("crash", "warn", "a", "b", "s5", 1000UL),
  )
  runner.drain(1000UL)
  assert_eq(runner.queued(), 2)
}

///|
async test "a failed delivery reports a reason without the credential" {
  let policy = wb_policy(
    "[notify]\nenabled = true\nqueue_size = 4\n[[notify.target]]\nplatform = \"webhook\"\nurl = \"http://127.0.0.1:9/hook?token=SECRET\"\nsecret = \"TOPSECRET\"\nevents = [\"crash\"]\n",
  )
  let (notifier, runner) = wb_pair("fail")
  let reply = notifier.publish_test(
    "api",
    policy,
    policy.targets,
    @notify.Message::new("crash", "warn", "t", "b", "s", 1000UL),
  )
  // One pass takes the test off the queue and delivers it; the result comes
  // back on the reply queue rather than as a return value, because the
  // delivery happens in the notify task.
  runner.step(1000UL)
  let received = try reply.try_get() catch {
    _ => None
  } noraise {
    item => item
  }
  let results = match received {
    Some(results) => results
    None => fail("expected the test delivery to report its results")
  }
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
  let dir = "/tmp/bm2-notify-cpu-\{@proc.get_pid()}"
  @fsx.mkdir_p(dir)
  let pid = @proc.spawn({
    bun_path: "/bin/sh",
    script: "-c\u{0}i=0; while true; do i=$((i+1)); done",
    cwd: dir,
    out_log: "",
    err_log: "",
    env_blob: @proc.base_env_blob(),
  })
  // First sample only sets the baseline: no percentage can be derived yet.
  assert_true(notifier.cpu_percent("k", pid, 1000UL) is None)
  @proc.sleep_ms(300)
  match notifier.cpu_percent("k", pid, 1400UL) {
    Some(percent) => assert_true(percent >= 0.0)
    None => fail("expected a cpu percentage once a baseline exists")
  }
  @utils.discard(() => @proc.kill_group(pid, @proc.SIGKILL))
  @proc.drain_child(pid)
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
