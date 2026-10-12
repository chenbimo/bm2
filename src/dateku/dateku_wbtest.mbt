///|
test "iso8601/epoch_zero" {
  assert_eq(iso8601(0UL), "1970-01-01T00:00:00.000Z")
}

///|
test "iso8601/leap_day" {
  assert_eq(iso8601(1709164800000UL), "2024-02-29T00:00:00.000Z")
  // Century rule: 2000 is a leap year (divisible by 400), 2100 is not
  // (divisible by 100 but not 400).
  assert_eq(iso8601(951782400000UL), "2000-02-29T00:00:00.000Z")
  assert_eq(iso8601(4107542400000UL), "2100-03-01T00:00:00.000Z")
}

///|
test "iso8601/millisecond_precision" {
  assert_eq(iso8601(1790985600123UL), "2026-10-03T00:00:00.123Z")
}

///|
test "iso8601/day_rollover" {
  // 23:59:59.999 + 1ms crosses the day and the second boundary.
  assert_eq(iso8601(86399999UL), "1970-01-01T23:59:59.999Z")
  assert_eq(iso8601(86400000UL), "1970-01-02T00:00:00.000Z")
  // Year boundary: last millisecond of 2023, first of 2024.
  assert_eq(iso8601(1704067199999UL), "2023-12-31T23:59:59.999Z")
  assert_eq(iso8601(1704067200000UL), "2024-01-01T00:00:00.000Z")
}

///|
test "rfc5322/epoch_zero" {
  assert_eq(rfc5322(0UL), "Thu, 01 Jan 1970 00:00:00 +0000")
}

///|
test "rfc5322/leap_day_is_thursday" {
  assert_eq(rfc5322(1709164800000UL), "Thu, 29 Feb 2024 00:00:00 +0000")
}

///|
test "rfc5322/weekday_and_month_names" {
  assert_eq(rfc5322(1790985600000UL), "Sat, 03 Oct 2026 00:00:00 +0000")
}

///|
test "components/match_iso8601" {
  let e = 1791015330123UL
  assert_eq(iso8601(e), "2026-10-03T08:15:30.123Z")
  assert_eq(year(e), 2026)
  assert_eq(month(e), 10)
  assert_eq(day(e), 3)
  assert_eq(hour(e), 8)
  assert_eq(minute(e), 15)
  assert_eq(second(e), 30)
  assert_eq(millisecond(e), 123)
}

///|
test "make_epoch/inverse_of_iso8601" {
  assert_eq(
    make_epoch(2026, 10, 3, hour=8, minute=15, second=30, millisecond=123),
    1791015330123UL,
  )
  assert_eq(iso8601(make_epoch(1970, 1, 1)), "1970-01-01T00:00:00.000Z")
  assert_eq(make_epoch(1970, 1, 1), 0UL)
  // Rollover: month 13 is January of the next year
  assert_eq(iso8601(make_epoch(2026, 13, 1)), "2027-01-01T00:00:00.000Z")
}

///|
test "leap_rules" {
  assert_eq(is_leap_year(2000), true)
  assert_eq(is_leap_year(1900), false)
  assert_eq(is_leap_year(2024), true)
  assert_eq(is_leap_year(2026), false)
  assert_eq(days_in_month(2024, 2), 29)
  assert_eq(days_in_month(2026, 2), 28)
  assert_eq(days_in_month(2026, 4), 30)
  assert_eq(days_in_month(2026, 13), 0)
}

///|
test "add_shifts" {
  let e = 1790998530123UL
  assert_eq(add_days(e, 1), e + 86400000UL)
  assert_eq(add_days(e, -1), e - 86400000UL)
  assert_eq(add_hours(e, 2), e + 7200000UL)
  assert_eq(add_minutes(e, -30), e - 1800000UL)
  assert_eq(add_seconds(e, 90), e + 90000UL)
  // Month-end boundary: Oct 31 + 1 day = Nov 1
  assert_eq(
    iso8601(add_days(make_epoch(2026, 10, 31), 1)),
    "2026-11-01T00:00:00.000Z",
  )
}

///|
test "day_bounds" {
  let noon = make_epoch(2026, 10, 3, hour=12)
  assert_eq(start_of_day(noon), make_epoch(2026, 10, 3))
  assert_eq(
    is_same_day(noon, make_epoch(2026, 10, 3, hour=23, minute=59)),
    true,
  )
  assert_eq(is_same_day(noon, add_days(noon, 1)), false)
}

///|
test "now_unix_seconds" {
  let ms = now_ms()
  assert_eq(now_unix() * 1000UL <= ms + 1000UL, true)
}
