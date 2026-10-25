///|
/// Current wall-clock time in epoch milliseconds.
pub fn now_ms() -> UInt64 {
  @env.now()
}

///|
/// Decompose epoch milliseconds into UTC components:
/// (year, month, day, hour, minute, second, millisecond).
fn civil_from_ms(
  epoch_ms : UInt64,
) -> (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) {
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
  (year, month, day, rem / 3600UL, rem % 3600UL / 60UL, rem % 60UL, ms)
}

///|
/// Format epoch milliseconds as an ISO 8601 UTC timestamp:
/// `2026-10-03T08:15:30.123Z`.
pub fn iso8601(epoch_ms : UInt64) -> String {
  let c = civil_from_ms(epoch_ms)
  pad4(c.0) +
  "-" +
  pad2(c.1) +
  "-" +
  pad2(c.2) +
  "T" +
  pad2(c.3) +
  ":" +
  pad2(c.4) +
  ":" +
  pad2(c.5) +
  "." +
  pad3(c.6) +
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

///|
/// Human-readable duration in the largest sensible unit, at most two units:
/// `45s`, `5m 03s`, `2h 05m`, `3d 04h`. `pad` zero-pads the second unit, which
/// is what an aligned table wants; chat messages read better unpadded.
pub fn human_duration(ms : UInt64, pad~ : Bool = false) -> String {
  let seconds = (ms / 1000UL).to_int()
  if seconds < 60 {
    return "\{seconds}s"
  }
  let minutes = seconds / 60
  if minutes < 60 {
    return "\{minutes}m " + second_unit(seconds % 60, "s", pad)
  }
  let hours = minutes / 60
  if hours < 24 {
    return "\{hours}h " + second_unit(minutes % 60, "m", pad)
  }
  "\{hours / 24}d " + second_unit(hours % 24, "h", pad)
}

///|
/// The second unit of a duration: `03s` when padded, `3s` when not.
fn second_unit(value : Int32, suffix : String, pad : Bool) -> String {
  (if pad { pad2(value.to_uint64()) } else { value.to_string() }) + suffix
}

///|
/// Two decimal digits at a known offset of an ASCII string. Only ever used
/// on the ISO timestamp produced by `iso8601`, so byte and char offsets
/// coincide.
fn two_digits(text : String, start : Int32) -> Int32 {
  let mut value = 0
  let mut index = 0
  for c in text {
    if index >= start && index < start + 2 {
      value = value * 10 + c.to_int() - 48
    }
    index += 1
  }
  value
}

///|
/// Format epoch milliseconds as an RFC 5322 date-time header:
/// `Sat, 03 Oct 2026 08:15:30 +0000`. Email needs the weekday and month
/// names spelled out, which the ISO timestamp does not carry.
pub fn rfc5322(epoch_ms : UInt64) -> String {
  let weekdays : ReadOnlyArray[String] = [
    "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed",
  ]
  let months : ReadOnlyArray[String] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
    "Dec",
  ]
  let iso = iso8601(epoch_ms)
  let days = epoch_ms / 1000UL / 86400UL
  weekdays[(days % 7UL).to_int()] +
  ", " +
  iso[8:10].to_owned() +
  " " +
  months[two_digits(iso, 5) - 1] +
  " " +
  iso[:4].to_owned() +
  " " +
  iso[11:19].to_owned() +
  " +0000"
}

///|
/// days since 1970-01-01 for a proleptic Gregorian date
/// (days_from_civil algorithm, Howard Hinnant, public domain).
fn days_from_civil(y_ : Int64, m_ : Int64, d_ : Int64) -> Int64 {
  let y = if m_ <= 2 { y_ - 1 } else { y_ }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = y - era * 400
  let mp = if m_ > 2 { m_ - 3 } else { m_ + 9 }
  let doy = (153L * mp + 2L) / 5L + d_ - 1L
  let doe = yoe * 365L + yoe / 4L - yoe / 100L + doy
  era * 146097 + doe - 719468
}

///|
/// Construct epoch milliseconds from UTC components. Out-of-range
/// components roll over naturally (like `make_epoch(2026, 13, 1)` being
/// January of the next year).
pub fn make_epoch(
  year : Int32,
  month : Int32,
  day : Int32,
  hour~ : Int32 = 0,
  minute~ : Int32 = 0,
  second~ : Int32 = 0,
  millisecond~ : Int32 = 0,
) -> UInt64 {
  let days = days_from_civil(year.to_int64(), month.to_int64(), day.to_int64())
  let secs = days * 86400L +
    hour.to_int64() * 3600L +
    minute.to_int64() * 60L +
    second.to_int64()
  (secs * 1000L + millisecond.to_int64()).reinterpret_as_uint64()
}
