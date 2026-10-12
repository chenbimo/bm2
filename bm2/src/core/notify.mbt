///|
/// bm2 的通知适配层:订阅过滤(events/levels)、事件日志与监督采样留在这里,
/// 投递、去重、限流与重试委托给 chensuiyi/notify 库。库返回结构化结果,
/// 是否落日志由 bm2 决定。

///|
pub struct Notifier {
  engine : @notify.Engine
  ctx : @notify.Context
  host : String
  state_dir : String
  /// Instance key → when it was first seen away from online, and the previous
  /// cpu sample, both kept here so `Instance` stays about supervision only.
  offline_since : Map[String, UInt64]
  cpu_samples : Map[String, (UInt64, UInt64)]
  /// Per-instance RSS peaks in kB: one window since the last health report,
  /// one since the last daily report. Sampled wherever RSS is already read.
  rss_peak : Map[String, Int32]
  rss_peak_daily : Map[String, Int32]
}

///|
/// An engine with no policy of its own: each project brings its own when it
/// emits an event. `host` brands outgoing messages and the SMTP greeting.
pub fn Notifier::new(state_dir : String, host : String) -> Notifier {
  let ctx : @notify.Context = { host, product: "bm2", }
  {
    engine: @notify.Engine::new(ctx),
    ctx,
    host,
    state_dir,
    offline_since: Map([]),
    cpu_samples: Map([]),
    rss_peak: Map([]),
    rss_peak_daily: Map([]),
  }
}

///|
/// When this instance was first seen away from `online`. Recording the first
/// sighting — not the latest — is what makes "stuck for N minutes" meaningful.
pub fn Notifier::offline_since(
  self : Notifier,
  key : String,
  now : UInt64,
) -> UInt64 {
  match self.offline_since.get(key) {
    Some(since) => since
    None => {
      self.offline_since[key] = now
      now
    }
  }
}

///|
pub fn Notifier::forget_offline(self : Notifier, key : String) -> Unit {
  self.offline_since.remove(key)
}

///|
/// Record a sampled RSS value into both peak windows. Windows are cleared by
/// their reports, so a peak always means "since you last heard from us".
pub fn Notifier::record_rss(self : Notifier, key : String, kb : Int32) -> Unit {
  match self.rss_peak.get(key) {
    Some(peak) => if kb > peak { self.rss_peak[key] = kb }
    None => self.rss_peak[key] = kb
  }
  match self.rss_peak_daily.get(key) {
    Some(peak) => if kb > peak { self.rss_peak_daily[key] = kb }
    None => self.rss_peak_daily[key] = kb
  }
}

///|
/// Take the since-last-report peak in kB, clearing the window. None when
/// nothing was sampled since the previous report.
pub fn Notifier::take_report_peak(self : Notifier, key : String) -> Int32? {
  let peak = self.rss_peak.get(key)
  self.rss_peak.remove(key)
  peak
}

///|
/// Take the since-last-daily-report peak in kB, clearing the window.
pub fn Notifier::take_daily_peak(self : Notifier, key : String) -> Int32? {
  let peak = self.rss_peak_daily.get(key)
  self.rss_peak_daily.remove(key)
  peak
}

///|
/// CPU percent since the previous sample of the same instance. The first call
/// only records a baseline, so a fresh daemon reports no CPU rather than a
/// number invented from a missing previous sample.
pub fn Notifier::cpu_percent(
  self : Notifier,
  key : String,
  pid : Int32,
  now : UInt64,
) -> Double? {
  match @subproc.read_cpu_ticks(pid) {
    None => None
    Some(ticks) =>
      match self.cpu_samples.get(key) {
        Some(sample) => {
          let (last_ticks, last_ms) = sample
          self.cpu_samples[key] = (ticks, now)
          if now <= last_ms || ticks < last_ticks {
            None
          } else {
            let elapsed_s = (now - last_ms).to_double() / 1000.0
            if elapsed_s <= 0.0 {
              None
            } else {
              let busy_s = (ticks - last_ticks).to_double() /
                @subproc.clk_tck().to_double()
              Some(busy_s / elapsed_s * 100.0)
            }
          }
        }
        None => {
          self.cpu_samples[key] = (ticks, now)
          None
        }
      }
  }
}

///|
/// Messages dropped since the daemon started: queue overflow plus rate
/// limiting.
pub fn Notifier::dropped(self : Notifier) -> Int32 {
  self.engine.dropped()
}

///|
/// Messages currently queued.
pub fn Notifier::queued(self : Notifier) -> Int32 {
  self.engine.queued()
}

///|
/// A message for `bm2 notify`: proves a project's endpoints and credentials work
/// without waiting for a real incident.
pub fn test_message(now : UInt64, lang~ : String = "en") -> @notify.Message {
  let (title, body) = if lang == "zh" {
    ("bm2 通知测试", "收到此消息说明通知目标配置正确。")
  } else {
    (
      "bm2 notification test", "If you see this message, the notification target is configured correctly.",
    )
  }
  @notify.Message::new("lifecycle", "info", title, body, "notify-test", now)
}

///|
fn level_rank(level : String) -> Int32 {
  match level {
    "error" => 2
    "warn" => 1
    _ => 0
  }
}

///|
/// Which reports receive one event: the global gate, the report's own
/// override, and the level floor. Periodic reports (cron) never take events.
fn wants(
  report : @config.NotifyReport,
  policy : @config.NotifyConfig,
  msg : @notify.Message,
) -> Bool {
  if report.cron is Some(_) {
    return false
  }
  let events = match report.events {
    Some(events) => events
    None => policy.events
  }
  if !events.contains(msg.event) {
    return false
  }
  match report.min_level {
    Some(minimum) => level_rank(msg.level) >= level_rank(minimum)
    None => true
  }
}

///|
/// bm2.toml 的 target 携带订阅字段(events/min_level/report/label),投递用不到;
/// 转换为库的中立 Target。
/// Build a library target from a config endpoint. Email endpoints borrow the
/// send capability from the project's mail channel; their own config only
/// ever carries recipients.
fn lib_target(
  endpoint : @config.NotifyEndpoint,
  mail_url : String?,
  mail_from : String?,
  mail_username : String?,
  mail_password : String?,
) -> @notify.Target {
  let is_email = endpoint.platform == "email"
  {
    name: endpoint.platform,
    preset: endpoint.platform,
    url: if is_email {
      mail_url.unwrap_or("")
    } else {
      endpoint.url
    },
    secret: endpoint.secret,
    format: endpoint.format,
    from: if is_email {
      mail_from
    } else {
      None
    },
    to: endpoint.mail_to,
    username: if is_email {
      mail_username
    } else {
      None
    },
    password: if is_email {
      mail_password
    } else {
      None
    },
  }
}

///|
fn lib_endpoints(
  endpoints : Array[@config.NotifyEndpoint],
  policy : @config.NotifyConfig,
) -> Array[@notify.Target] {
  endpoints.map(fn(endpoint) {
    lib_target(
      endpoint,
      policy.mail_url,
      policy.mail_from,
      policy.mail_username,
      policy.mail_password,
    )
  })
}

///|
/// Flatten the endpoints of several reports into one delivery list.
fn flatten_endpoints(
  reports : Array[@config.NotifyReport],
) -> Array[@config.NotifyEndpoint] {
  let out = []
  for report in reports {
    for endpoint in report.targets {
      out.push(endpoint)
    }
  }
  out
}

///|
/// The single entry point for events: subscription, deduplication, rate limit,
/// then the queue. Callers describe what happened; policy lives here.
pub fn Notifier::emit(
  self : Notifier,
  policy : @config.NotifyConfig,
  app : String,
  msg : @notify.Message,
) -> Unit {
  if !policy.enabled {
    return
  }
  if !policy.events.contains(msg.event) {
    return
  }
  let instant = policy.reports.filter(fn(report) { wants(report, policy, msg) })
  if instant.length() == 0 {
    return
  }
  let outcome = self.engine.emit(
    msg.ts_ms,
    msg.key,
    app,
    msg,
    lib_endpoints(flatten_endpoints(instant), policy),
    policy.timeout_ms,
    dedupe_window_s=policy.dedupe_window_s,
    rate_per_minute=policy.max_per_minute,
    queue_limit=policy.queue_size,
  )
  match outcome {
    RateLimited =>
      log_event(
        self.state_dir,
        "bm2d.events.jsonl",
        "notify_rate_limited",
        app=Some(app),
        detail=msg.event,
      )
    _ => ()
  }
}

///|
/// One pass of the engine: deliver at most one queued message. Returns the
/// number of messages still queued; the outcome lands in the event log.
pub async fn Notifier::pump(self : Notifier, now : UInt64) -> Int32 {
  let report = self.engine.pump(now)
  match report.outcome {
    Partial =>
      log_event(
        self.state_dir,
        "bm2d.events.jsonl",
        "notify_partial",
        app=report.owner,
        detail="partial delivery",
      )
    Failed(attempt~) =>
      log_event(
        self.state_dir,
        "bm2d.events.jsonl",
        "notify_failed",
        app=report.owner,
        detail="attempt \{attempt}/3",
      )
    Exhausted =>
      log_event(
        self.state_dir,
        "bm2d.events.jsonl",
        "notify_failed",
        app=report.owner,
        detail="attempt 3/3, dropped",
      )
    _ => ()
  }
  report.remaining
}

///|
/// Deliver immediately, ignoring subscriptions — this is `bm2 notify`, where the
/// operator explicitly asks for a message on a project's targets.
pub async fn Notifier::deliver_now(
  self : Notifier,
  endpoints : Array[@config.NotifyEndpoint],
  policy : @config.NotifyConfig,
  timeout_ms : Int32,
  msg : @notify.Message,
) -> Array[(String, String?)] {
  let results = @notify.deliver_all(
    lib_endpoints(endpoints, policy),
    msg,
    timeout_ms,
    self.ctx,
  )
  for pair in results {
    let (name, failure) = pair
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      match failure {
        None => "notify_sent"
        Some(_) => "notify_target_failed"
      },
      app=Some(name),
      detail=match failure {
        None => msg.event
        Some(reason) => msg.event + ": " + reason
      },
    )
  }
  results
}
