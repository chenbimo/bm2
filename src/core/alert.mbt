///|
/// bm2 的通知适配层:订阅过滤(events/levels)、监督采样与消息发布留在这里。
/// 渲染、投递、去重、限流与重试属于 `src/notify` 与 `notify_runner.mbt`,
/// 由独立的通知任务执行;监督侧只把渲染好的消息放进队列,不做任何网络调用,
/// 因此通知永远不会拖慢监督心跳。

///|
/// Supervision's own notify state: the sampling windows it fills while watching
/// instances, plus the queue it publishes alerts on. Delivery state (dedupe and
/// rate windows, the retry queue, the network) belongs to `NotifyRunner` on the
/// other side of that queue, so everything here is touched only by the
/// supervision task.
pub struct Notifier {
  outbound : @aqueue.Queue[Outbound]
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
/// The supervision side of notifications, bound to the queue that carries
/// messages to the notify task. `host` brands the outgoing message fields.
pub fn Notifier::new(
  state_dir : String,
  host : String,
  outbound : @aqueue.Queue[Outbound],
) -> Notifier {
  {
    outbound,
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
  match @proc.read_cpu_ticks(pid) {
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
                @proc.clk_tck().to_double()
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
/// A message for `bm2 notify`: proves a project's endpoints and credentials work
/// without waiting for a real incident.
pub fn test_message(now : UInt64, lang~ : String = "en") -> @notify.Message {
  let (title, body) = if is_zh(lang) {
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
  self.publish(
    Instant({
      owner: app,
      key: msg.key,
      policy,
      targets: lib_endpoints(flatten_endpoints(instant), policy),
      message: msg,
    }),
  )
}

///|
/// Publish one periodic report. Periodic delivery has no dedupe and no rate
/// limit by design: the schedule already says how often it should arrive.
pub fn Notifier::publish_schedule(
  self : Notifier,
  app : String,
  policy : @config.NotifyConfig,
  endpoints : Array[@config.NotifyEndpoint],
  msg : @notify.Message,
) -> Unit {
  self.publish(
    Schedule({
      owner: app,
      key: msg.key,
      policy,
      targets: lib_endpoints(endpoints, policy),
      message: msg,
    }),
  )
}

///|
/// Publish one `bm2 notify` test straight onto the notify queue and hand back the
/// queue its results arrive on. The caller owns the reply and decides how long to
/// wait for it.
///
/// This is the one outbound message the control side sends by itself: a test
/// reads no supervised state, so it needs nothing but the queue the two tasks
/// already share.
pub fn publish_test(
  outbound : @aqueue.Queue[Outbound],
  app : String,
  policy : @config.NotifyConfig,
  endpoints : Array[@config.NotifyEndpoint],
  msg : @notify.Message,
) -> @aqueue.Queue[Array[(String, String?)]] {
  let reply : @aqueue.Queue[Array[(String, String?)]] = @aqueue.Queue::Queue(
    kind=Blocking(1),
  )
  let alert : Alert = {
    owner: app,
    key: msg.key,
    policy,
    targets: lib_endpoints(endpoints, policy),
    message: msg,
  }
  let accepted = try outbound.try_put(Test(alert, reply)) catch {
    _ => false
  } noraise {
    ok => ok
  }
  if !accepted {
    // The notify task is far behind. Answer on the reply rather than losing the
    // request silently, so `bm2 notify` can report it.
    @utils.discard(() => {
      ignore(
        reply.try_put([("notify queue", Some("the notification queue is full"))]),
      )
    })
  }
  reply
}

///|
/// The same test, for callers that already hold the notifier.
pub fn Notifier::publish_test(
  self : Notifier,
  app : String,
  policy : @config.NotifyConfig,
  endpoints : Array[@config.NotifyEndpoint],
  msg : @notify.Message,
) -> @aqueue.Queue[Array[(String, String?)]] {
  publish_test(self.outbound, app, policy, endpoints, msg)
}

///|
/// The alert inside one outbound message; every variant carries one.
fn alert_of(outbound : Outbound) -> Alert {
  match outbound {
    Instant(alert) => alert
    Schedule(alert) => alert
    Test(alert, _) => alert
  }
}

///|
/// Put one message on the queue to the notify task. The queue never blocks: if
/// the notify task is stuck far behind, the newest alert is dropped and the
/// drop is logged, which is the same "keep the root cause, drop the tail"
/// behaviour the per-owner queue limit documents.
fn Notifier::publish(self : Notifier, outbound : Outbound) -> Unit {
  let accepted = try self.outbound.try_put(outbound) catch {
    _ => false
  } noraise {
    ok => ok
  }
  if !accepted {
    let alert = alert_of(outbound)
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "notify_backlog_dropped",
      app=Some(alert.owner),
      detail=alert.message.event,
    )
  }
}
