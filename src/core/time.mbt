///|
pub fn now_ms() -> UInt64 {
  @env.now()
}

///|
/// Format epoch milliseconds as an ISO 8601 UTC timestamp.
pub fn iso8601(epoch_ms : UInt64) -> String {
  let ms = epoch_ms % 1000UL
  let secs = epoch_ms / 1000UL
  let days = secs / 86400UL
  let rem = secs % 86400UL
  // civil-from-days algorithm (Howard Hinnant, public domain)
  let z = days + 719468UL
  let era = z / 146097UL
  let doe = z - era * 146097UL
  let yoe = (doe - doe / 1460UL + doe / 36524UL - doe / 146096UL) / 365UL
  let y0 = yoe + era * 400UL
  let doy = doe - (365UL * yoe + yoe / 4UL - yoe / 100UL)
  let mp = (5UL * doy + 2UL) / 153UL
  let day = doy - (153UL * mp + 2UL) / 5UL + 1UL
  let month = if mp < 10UL { mp + 3UL } else { mp - 9UL }
  let year = if month <= 2UL { y0 + 1UL } else { y0 }
  pad4(year) +
  "-" +
  pad2(month) +
  "-" +
  pad2(day) +
  "T" +
  pad2(rem / 3600UL) +
  ":" +
  pad2(rem % 3600UL / 60UL) +
  ":" +
  pad2(rem % 60UL) +
  "." +
  pad3(ms) +
  "Z"
}

///|
fn pad2(n : UInt64) -> String {
  if n < 10UL {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
fn pad3(n : UInt64) -> String {
  if n < 10UL {
    "00" + n.to_string()
  } else if n < 100UL {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
fn pad4(n : UInt64) -> String {
  if n < 1000UL {
    "0" + pad3(n)
  } else {
    n.to_string()
  }
}
