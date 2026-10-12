///|
/// The outbound side of notifications: supervision *composes* a message (it
/// owns the state the message describes) and the notify task owns everything
/// that can block — the delivery queue, retries and the network. The two sides
/// meet on one async queue and nothing else, so a slow or dead endpoint can
/// never delay the supervision heartbeat, and the supervision loop contains no
/// await point at all.

///|
/// One notification on its way out. The policy travels with the message: a
/// project's `[notify]` section is the policy for its own alerts, and the
/// notify task keeps no policy of its own.
pub(all) struct Alert {
  /// Project the alert belongs to: per-owner accounting and log attribution.
  owner : String
  /// Deduplication signature.
  key : String
  policy : @config.NotifyConfig
  targets : Array[@notify.Target]
  message : @notify.Message
}

///|
/// How a message is to be delivered.
pub(all) enum Outbound {
  /// Event-driven: dedupe, rate limit, per-owner queue, retry with backoff.
  Instant(Alert)
  /// Periodic report: delivered straight through, no queue, no dedupe.
  Schedule(Alert)
  /// `bm2 notify`: deliver now and report the per-target results through the
  /// reply queue, so the CLI can print them.
  Test(Alert, @aqueue.Queue[Array[(String, String?)]])
}

///|
/// How long one delivery pass may spend. A burst of periodic reports, or one
/// dead endpoint, must not make a single pass run for minutes: whatever the
/// budget does not reach stays queued for the next pass.
const NOTIFY_PASS_BUDGET_MS : Int32 = 2000

///|
/// Capacity of the supervision → notify handoff queue. It only has to absorb
/// one burst between two delivery passes (50 ms), and it is wide enough that a
/// project's own `queue_size` (≤ 4096) remains the limit the documentation
/// promises. A full queue drops the newest alert and logs the drop.
const NOTIFY_INBOUND_CAPACITY : Int32 = 4096

///|
/// Delivery-side owner of notifications: the engine (dedupe, rate limit, queue,
/// retry), the network, and the delivery queue. Only the notify task touches
/// these fields, so nothing here needs a lock.
pub struct NotifyRunner {
  /// Messages published by the supervision task.
  inbound : @aqueue.Queue[Outbound]
  /// Work that needs the network but has not been delivered yet: it survives
  /// across passes when one pass runs out of budget.
  mut deferred : Array[Outbound]
  engine : @notify.Engine
  ctx : @notify.Context
  state_dir : String
}

///|
/// Create the delivery side around the queue it shares with supervision.
pub fn NotifyRunner::new(
  state_dir : String,
  host : String,
  inbound : @aqueue.Queue[Outbound],
) -> NotifyRunner {
  let ctx : @notify.Context = { host, product: "bm2", }
  { inbound, deferred: [], engine: @notify.Engine::new(ctx), ctx, state_dir, }
}

///|
/// Messages waiting in the engine's queue (instant alerts only).
pub fn NotifyRunner::queued(self : NotifyRunner) -> Int32 {
  self.engine.queued()
}

///|
/// Messages dropped since start: rate limiting, per-owner queue limits, and
/// exhausted retries.
pub fn NotifyRunner::dropped(self : NotifyRunner) -> Int32 {
  self.engine.dropped()
}

///|
/// Take everything that arrived onto this task's side. Instant alerts go into
/// the engine's queue (pure memory, with dedupe/rate/queue policy applied),
/// everything that needs the network is deferred to the delivery phase. Never
/// blocks and never touches the network, so it is safe to run to completion.
pub fn NotifyRunner::drain(self : NotifyRunner, now : UInt64) -> Unit {
  while true {
    let next = try self.inbound.try_get() catch {
      _ => None
    } noraise {
      item => item
    }
    match next {
      None => break
      Some(outbound) =>
        match outbound {
          Instant(alert) => self.enqueue(alert, now)
          _ => self.deferred.push(outbound)
        }
    }
  }
}

///|
/// Hand one alert to the engine. `now` is monotonic time: the dedupe window,
/// the rolling rate limit and the retry backoff are all durations, so a system
/// time change must not shorten or stretch them.
fn NotifyRunner::enqueue(
  self : NotifyRunner,
  alert : Alert,
  now : UInt64,
) -> Unit {
  let outcome = self.engine.emit(
    now,
    alert.key,
    alert.owner,
    alert.message,
    alert.targets,
    alert.policy.timeout_ms,
    dedupe_window_s=alert.policy.dedupe_window_s,
    rate_per_minute=alert.policy.max_per_minute,
    queue_limit=alert.policy.queue_size,
  )
  let event = match outcome {
    RateLimited => "notify_rate_limited"
    QueueFull => "notify_queue_full"
    _ => ""
  }
  if event != "" {
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      event,
      app=Some(alert.owner),
      detail=alert.message.event,
    )
  }
}

///|
/// Deliver one alert to its targets, one request each, and record the outcome.
/// Failures are events only: a dead endpoint never changes supervision, and the
/// reason never carries a credential (the library guarantees that).
async fn NotifyRunner::deliver_alert(
  self : NotifyRunner,
  alert : Alert,
  detail~ : String = "instant",
) -> Array[(String, String?)] {
  let results = @notify.deliver_all(
    alert.targets,
    alert.message,
    alert.policy.timeout_ms,
    self.ctx,
  )
  for pair in results {
    let (target, failure) = pair
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      match failure {
        None => "notify_sent"
        Some(_) => "notify_target_failed"
      },
      app=Some(alert.owner),
      detail=match failure {
        None => detail + ": " + target
        Some(reason) => detail + ": " + target + ": " + reason
      },
    )
  }
  results
}

///|
/// Deliver what is deferred, within one pass budget. Periodic reports and
/// `bm2 notify` tests wait here; the leftovers stay for the next pass.
async fn NotifyRunner::deliver_deferred(self : NotifyRunner) -> Unit {
  let deadline = @proc.monotonic_ms() + NOTIFY_PASS_BUDGET_MS.to_uint64()
  let mut handled = 0
  while handled < self.deferred.length() {
    match self.deferred[handled] {
      Schedule(alert) => ignore(self.deliver_alert(alert, detail="schedule"))
      Test(alert, reply) => {
        let results = self.deliver_alert(alert, detail="test")
        // Capacity 1, one producer: the put only fails if the caller gave up
        // on the reply, in which case the result is dropped, not lost.
        @utils.discard(() => ignore(reply.try_put(results)))
      }
      Instant(_) => ()
    }
    handled += 1
    if @proc.monotonic_ms() >= deadline {
      break
    }
  }
  if handled > 0 {
    self.deferred = self.deferred[handled:].to_owned()
  }
}

///|
/// Deliver at most one queued instant alert and record what happened to it.
async fn NotifyRunner::pump(self : NotifyRunner, now : UInt64) -> Unit {
  let report = self.engine.pump(now)
  let detail = match report.outcome {
    Partial => Some("partial delivery")
    Failed(attempt~) => Some("attempt \{attempt}/3")
    Exhausted => Some("attempt 3/3, dropped")
    _ => None
  }
  let event = match report.outcome {
    Partial => "notify_partial"
    Failed(_) | Exhausted => "notify_failed"
    _ => ""
  }
  if event != "" {
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      event,
      app=report.owner,
      detail?,
    )
  }
}

///|
/// One delivery pass: take what arrived, deliver one queued instant alert, then
/// spend the remaining pass budget on periodic reports and tests. Instant
/// alerts go first so an incident never waits behind a scheduled report.
pub async fn NotifyRunner::step(self : NotifyRunner, now : UInt64) -> Unit {
  self.drain(now)
  self.pump(now)
  self.deliver_deferred()
}

///|
/// The notify task's loop: the same 50 ms cadence as the supervision tick, so
/// both tasks are driven the same way and neither can starve the other. This is
/// the only place in the daemon where notification delivery happens, and
/// nothing in `Supervisor::tick` waits for it.
///
/// `step` declares no error type, so a failed delivery can only ever be an
/// event: the loop cannot raise and delivery keeps running.
pub async fn NotifyRunner::run(self : NotifyRunner) -> Unit {
  while true {
    let timer = @async.Timer::Timer(50)
    timer.wait()
    self.step(@proc.monotonic_ms())
  }
}
