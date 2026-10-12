///|
/// The optional delivery engine: deduplication, rate limiting and retry with
/// backoff around the plain `deliver` function. Pure and testable — every
/// timestamp comes from the caller, and outcomes are returned as values
/// instead of being logged, so the host application decides what to record.

///|
struct DedupeEntry {
  first_ms : UInt64
  count : Int32
  /// Owner that produced the signature, so `forget_owner` can drop a removed
  /// project's entries instead of leaving them in the map for good.
  owner : String
}

///|
struct Queued {
  message : Message
  /// Owner key for per-group queue accounting (e.g. one project's events).
  owner : String
  targets : Array[Target]
  timeout_ms : Int32
  /// Retry state, per message: how many delivery attempts have failed, and the
  /// earliest time of the next one. Keeping it per message is what lets one
  /// dead endpoint back off on its own instead of stalling every other
  /// project's alerts.
  mut attempts : Int32
  mut next_attempt_ms : UInt64
}

///|
const MAX_ATTEMPTS_DEFAULT : Int32 = 3

///|
pub struct Engine {
  ctx : Context
  max_attempts : Int32
  mut queue : Array[Queued]
  mut dropped : Int32
  /// Owner the last attempt belonged to. The next attempt prefers a different
  /// project, so a failing endpoint delays its own project's alerts rather than
  /// everybody's.
  mut last_owner : String?
  /// Owner → (window started ms, emitted in window). Each owner gets its own
  /// rolling minute budget, so one project's throttle never starves another.
  rate_window : Map[String, (UInt64, Int32)]
  dedupe : Map[String, DedupeEntry]
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
    last_owner: None,
    rate_window: Map([]),
    dedupe: Map([]),
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
          self.dedupe[key] = { ..entry, count: entry.count + 1, }
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
          self.dedupe[key] = { first_ms: now, count: 1, owner, }
        }
      None => self.dedupe[key] = { first_ms: now, count: 1, owner, }
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
  self.queue.push({
    message,
    owner,
    targets,
    timeout_ms,
    attempts: 0,
    next_attempt_ms: 0UL,
  })
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
/// One pass of the engine: attempt delivery on at most one queued message.
///
/// The message is chosen by `pick`, which skips whatever is waiting out its own
/// backoff and prefers a project other than the last one attempted. A queue
/// that mixes projects therefore keeps making progress on all of them while one
/// endpoint is down.
pub async fn Engine::pump(self : Engine, now : UInt64) -> PumpReport {
  let picked = self.pick(now)
  let index = match picked {
    Some(index) => index
    None =>
      return { remaining: self.queue.length(), outcome: Idle, owner: None, }
  }
  let queued = self.queue[index]
  self.last_owner = Some(queued.owner)
  let results = deliver_all(
    queued.targets,
    queued.message,
    queued.timeout_ms,
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
    self.drop_at(index)
    Delivered
  } else if delivered.length() > 0 {
    // Somebody got it; retrying now would only duplicate it for them.
    self.drop_at(index)
    Partial
  } else {
    queued.attempts += 1
    if queued.attempts >= self.max_attempts {
      self.drop_at(index)
      Exhausted
    } else {
      // Backoff grows linearly: 5s after the first failure, 15s after the
      // second — long enough to clear a blip, short enough for an alert.
      queued.next_attempt_ms = now +
        (5000 * (1 + 2 * (queued.attempts - 1))).to_uint64()
      Failed(attempt=queued.attempts)
    }
  }
  { remaining: self.queue.length(), outcome, owner: Some(queued.owner), }
}

///|
/// Choose the message to attempt: the oldest one that is not waiting out its own
/// backoff, preferring a project other than the last one attempted. None while
/// every queued message is in backoff.
fn Engine::pick(self : Engine, now : UInt64) -> Int32? {
  let mut fallback : Int32? = None
  for index, queued in self.queue {
    if queued.next_attempt_ms > 0UL && now < queued.next_attempt_ms {
      continue
    }
    match self.last_owner {
      Some(owner) =>
        if queued.owner != owner {
          return Some(index)
        } else {
          match fallback {
            None => fallback = Some(index)
            Some(_) => ()
          }
        }
      None => return Some(index)
    }
  }
  fallback
}

///|
/// Drop the message at `index`, keeping the rest in order. The queue is short
/// (each project's own `queue_size` caps it), so rebuilding it is cheaper to
/// reason about than an in-place removal.
fn Engine::drop_at(self : Engine, index : Int32) -> Unit {
  let kept : Array[Queued] = []
  for i, queued in self.queue {
    if i != index {
      kept.push(queued)
    }
  }
  self.queue = kept
}

///|
/// Drop everything held for one project: a project that has been unregistered
/// must not leave its queue, rate window or dedupe entries behind — they would
/// outlive it, and a project re-registered under the same name would inherit
/// them.
pub fn Engine::forget_owner(self : Engine, owner : String) -> Unit {
  self.rate_window.remove(owner)
  let doomed = []
  for pair in self.dedupe.iter() {
    let (key, entry) = pair
    if entry.owner == owner {
      doomed.push(key)
    }
  }
  for key in doomed {
    self.dedupe.remove(key)
  }
  // Its queued alerts are no longer worth delivering: the project is gone.
  self.queue = self.queue.filter(fn(notice) { notice.owner != owner })
  match self.last_owner {
    Some(last) => if last == owner { self.last_owner = None }
    None => ()
  }
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
