///|
/// Milliseconds since `started`, clamped at zero when the clock stepped
/// backwards (WSL and VM clocks can roll back by a millisecond, which
/// would otherwise underflow an unsigned subtraction into a huge value).
pub fn elapsed_since(started : UInt64) -> UInt64 {
  let now = @dateku.now_ms()
  if now >= started {
    now - started
  } else {
    0UL
  }
}
