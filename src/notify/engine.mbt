///|
/// The optional delivery engine: deduplication, rate limiting and retry with
/// backoff around the plain `deliver` function. Pure and testable — every
/// timestamp comes from the caller, and outcomes are returned as values
/// instead of being logged, so the host application decides what to record.

///|
struct DedupeEntry {
  first_ms : UInt64
  count : Int32
}

///|
struct Queued {
  message : Message
  /// Owner key for per-group queue accounting (e.g. one project's events).
  owner : String
  targets : Array[Target]
  timeout_ms : Int32
}

///|
const MAX_ATTEMPTS_DEFAULT : Int32 = 3

///|
pub struct Engine {
  ctx : Context
  max_attempts : Int32
  mut queue : Array[Queued]
  mut dropped : Int32
  /// Owner → (window started ms, emitted in window). Each owner gets its own
  /// rolling minute budget, so one project's throttle never starves another.
  rate_window : Map[String, (UInt64, Int32)]
  dedupe : Map[String, DedupeEntry]
  mut next_attempt_ms : UInt64
  mut attempts : Int32
}

///|
/// Create an engine. `ctx` brands the outgoing messages (footer and EHLO
/// name); `max_attempts` is how many delivery passes one message gets before
/// it is dropped.
pub fn Engine::new(
  ctx : Context,
  max_attempts~ : Int32 = MAX_ATTEMPTS_DEFAULT,
) -> Engine {
  {
    ctx,
    max_attempts,
    queue: [],
    dropped: 0,
    rate_window: Map([]),
    dedupe: Map([]),
    next_attempt_ms: 0UL,
    attempts: 0,
  }
}

///|
/// What happened to one emit call.
pub(all) enum EmitOutcome {
  Queued
  /// Same condition inside the dedupe window; `count` is how many times the
  /// key has been seen in the current window.
  Deduped(count~ : Int32)
  RateLimited
  QueueFull
} derive(Debug, Eq)

///|
pub extend EmitOutcome with Eq::{not_equal, equal}

///|
pub extend EmitOutcome with @debug.Debug::{to_repr}

///|
/// Queue one message. Deduplication, rate limiting and queue accounting are
/// all driven by the parameters — the engine keeps no policy of its own.
///
/// - `key` deduplicates identical conditions inside `dedupe_window_s`.
/// - `owner` + `queue_limit` keep a burst from one group from starving others:
///   once `queue_limit` messages of `owner` are queued, further ones drop.
/// - `rate_per_minute` caps emissions per rolling 60s window (0 = unlimited).
pub fn Engine::emit(
  self : Engine,
  now : UInt64,
  key : String,
  owner : String,
  msg : Message,
  targets : Array[Target],
  timeout_ms : Int32,
  dedupe_window_s~ : Int32 = 0,
  rate_per_minute~ : Int32 = 0,
  queue_limit~ : Int32 = 0,
) -> EmitOutcome {
  if targets.length() == 0 {
    return EmitOutcome::Queued
  }
  let mut message = msg
  if dedupe_window_s > 0 {
    let window = (dedupe_window_s * 1000).to_uint64()
    match self.dedupe.get(key) {
      Some(entry) =>
        if now >= entry.first_ms && now - entry.first_ms < window {
          // Same condition inside the window: count it, stay silent.
          self.dedupe[key] = {
            first_ms: entry.first_ms,
            count: entry.count + 1,
          }
          return Deduped(count=entry.count + 1)
        } else {
          // The window expired: send again and say how quiet it has been.
          if entry.count > 1 {
            message = {
              ..message,
              body: message.body +
              "\n(上一个窗口内同样的事件共 \{entry.count} 次)",
            }
          }
          self.dedupe[key] = { first_ms: now, count: 1, }
        }
      None => self.dedupe[key] = { first_ms: now, count: 1, }
    }
  }
  if rate_per_minute > 0 {
    // Per-owner rolling minute window: one project's throttle never counts
    // another project's emissions.
    let (started, sent) = match self.rate_window.get(owner) {
      Some(window) => window
      None => (0UL, 0)
    }
    let (started, sent) = if now >= started && now - started >= 60000UL {
      (now, 0)
    } else {
      (started, sent)
    }
    if sent >= rate_per_minute {
      self.dropped += 1
      self.rate_window[owner] = (started, sent)
      return RateLimited
    }
    self.rate_window[owner] = (started, sent + 1)
  }
  let queued = self.queue.filter(fn(notice) { notice.owner == owner }).length()
  if queue_limit > 0 && queued >= queue_limit {
    // Keep the first events of a burst: they carry the root cause.
    self.dropped += 1
    return QueueFull
  }
  self.queue.push({ message, owner, targets, timeout_ms, })
  EmitOutcome::Queued
}

///|
/// What one pump pass did with the head of the queue.
pub(all) enum PumpOutcome {
  /// Queue empty or waiting out the retry backoff.
  Idle
  Delivered
  /// Some targets got it, some failed; retrying would duplicate for the
  /// ones that succeeded, so the head is dropped either way.
  Partial
  /// Every target failed; `attempt` counts this failure. The message is
  /// retried after a backoff until `max_attempts` is reached.
  Failed(attempt~ : Int32)
  /// Every target failed and the attempt budget is spent; the head dropped.
  Exhausted
} derive(Debug, Eq)

///|
pub extend PumpOutcome with Eq::{not_equal, equal}

///|
pub extend PumpOutcome with @debug.Debug::{to_repr}

///|
pub(all) struct PumpReport {
  remaining : Int32
  outcome : PumpOutcome
  /// Owner of the attempted message, so the host application can attribute
  /// the outcome in its own logs. None when idle.
  owner : String?
} derive(Debug)

///|
pub extend PumpReport with Debug::{to_repr}

///|
/// One pass of the engine: deliver at most one queued message.
pub async fn Engine::pump(self : Engine, now : UInt64) -> PumpReport {
  if self.queue.length() == 0 || now < self.next_attempt_ms {
    return { remaining: self.queue.length(), outcome: Idle, owner: None, }
  }
  let notice = self.queue[0]
  let results = deliver_all(
    notice.targets,
    notice.message,
    notice.timeout_ms,
    self.ctx,
  )
  let delivered = results.filter(fn(pair) {
    let (_, failure) = pair
    failure is None
  })
  let failures = results.filter(fn(pair) {
    let (_, failure) = pair
    failure is Some(_)
  })
  let outcome = if failures.length() == 0 {
    self.drop_head()
    self.attempts = 0
    self.next_attempt_ms = 0UL
    Delivered
  } else if delivered.length() > 0 {
    // Somebody got it; retrying now would only duplicate it for them.
    self.drop_head()
    self.attempts = 0
    self.next_attempt_ms = 0UL
    Partial
  } else {
    self.attempts += 1
    if self.attempts >= self.max_attempts {
      self.drop_head()
      self.attempts = 0
      self.next_attempt_ms = 0UL
      Exhausted
    } else {
      // Backoff grows linearly: 5s after the first failure, 15s after the
      // second — long enough to clear a blip, short enough for an alert.
      self.next_attempt_ms = now +
        (5000 * (1 + 2 * (self.attempts - 1))).to_uint64()
      Failed(attempt=self.attempts)
    }
  }
  { remaining: self.queue.length(), outcome, owner: Some(notice.owner), }
}

///|
fn Engine::drop_head(self : Engine) -> Unit {
  self.queue = self.queue[1:].to_owned()
}

///|
/// Messages dropped since the engine was created: queue overflow plus rate
/// limiting.
pub fn Engine::dropped(self : Engine) -> Int32 {
  self.dropped
}

///|
/// Number of messages still queued.
pub fn Engine::queued(self : Engine) -> Int32 {
  self.queue.length()
}
