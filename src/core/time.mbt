///|
/// Milliseconds since `started_mono` on the monotonic clock. Monotonic time
/// never steps backwards, so this subtraction cannot underflow into a huge
/// value and a spawn's uptime is never misread after the system time changes.
/// Every duration in the supervisor is measured this way. The wall clock
/// (`@utils.now_ms`) is reserved for absolute times a human reads.
pub fn elapsed_mono_since(started_mono : UInt64) -> UInt64 {
  let now = @proc.monotonic_ms()
  if now >= started_mono {
    now - started_mono
  } else {
    0UL
  }
}
