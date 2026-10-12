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
