///|
/// Current wall-clock time in epoch milliseconds.
pub fn now_ms() -> UInt64 {
  @env.now()
}

///|
/// Current Unix time in whole seconds.
pub fn now_unix() -> UInt64 {
  @env.now() / 1000UL
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
/// UTC year of `epoch_ms`.
pub fn year(epoch_ms : UInt64) -> Int32 {
  civil_from_ms(epoch_ms).0.to_int()
}

///|
/// UTC month of `epoch_ms`, 1-12.
pub fn month(epoch_ms : UInt64) -> Int32 {
  civil_from_ms(epoch_ms).1.to_int()
}

///|
/// UTC day of month of `epoch_ms`, 1-31.
pub fn day(epoch_ms : UInt64) -> Int32 {
  civil_from_ms(epoch_ms).2.to_int()
}

///|
/// UTC hour of `epoch_ms`, 0-23.
pub fn hour(epoch_ms : UInt64) -> Int32 {
  civil_from_ms(epoch_ms).3.to_int()
}

///|
/// UTC minute of `epoch_ms`, 0-59.
pub fn minute(epoch_ms : UInt64) -> Int32 {
  civil_from_ms(epoch_ms).4.to_int()
}

///|
/// UTC second of `epoch_ms`, 0-59.
pub fn second(epoch_ms : UInt64) -> Int32 {
  civil_from_ms(epoch_ms).5.to_int()
}

///|
/// UTC millisecond of `epoch_ms`, 0-999.
pub fn millisecond(epoch_ms : UInt64) -> Int32 {
  civil_from_ms(epoch_ms).6.to_int()
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
  let weekdays = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]
  let months = [
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

///|
/// Gregorian leap-year rule.
pub fn is_leap_year(year : Int32) -> Bool {
  (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

///|
/// Number of days in the given UTC month, 0 for an invalid month.
pub fn days_in_month(year : Int32, month : Int32) -> Int32 {
  match month {
    1 => 31
    2 => if is_leap_year(year) { 29 } else { 28 }
    3 => 31
    4 => 30
    5 => 31
    6 => 30
    7 => 31
    8 => 31
    9 => 30
    10 => 31
    11 => 30
    12 => 31
    _ => 0
  }
}

///|
/// Shift `epoch_ms` by a number of days (negative shifts backwards).
pub fn add_days(epoch_ms : UInt64, days : Int32) -> UInt64 {
  epoch_ms + (days.to_int64() * 86400000L).reinterpret_as_uint64()
}

///|
/// Shift `epoch_ms` by a number of hours (negative shifts backwards).
pub fn add_hours(epoch_ms : UInt64, hours : Int32) -> UInt64 {
  epoch_ms + (hours.to_int64() * 3600000L).reinterpret_as_uint64()
}

///|
/// Shift `epoch_ms` by a number of minutes (negative shifts backwards).
pub fn add_minutes(epoch_ms : UInt64, minutes : Int32) -> UInt64 {
  epoch_ms + (minutes.to_int64() * 60000L).reinterpret_as_uint64()
}

///|
/// Shift `epoch_ms` by a number of seconds (negative shifts backwards).
pub fn add_seconds(epoch_ms : UInt64, seconds : Int32) -> UInt64 {
  epoch_ms + (seconds.to_int64() * 1000L).reinterpret_as_uint64()
}

///|
/// Epoch milliseconds of UTC midnight for the day of `epoch_ms`.
pub fn start_of_day(epoch_ms : UInt64) -> UInt64 {
  epoch_ms - epoch_ms % 86400000UL
}

///|
/// True when both instants fall on the same UTC day.
pub fn is_same_day(a : UInt64, b : UInt64) -> Bool {
  a / 86400000UL == b / 86400000UL
}
