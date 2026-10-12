///|
test "parse/plain" {
  assert_eq(parse("1.4.0"), Semver::{ major: 1, minor: 4, patch: 0, })
}

///|
test "parse/skips_prefix_and_suffix" {
  assert_eq(parse("v0.3.0-beta.1"), Semver::{ major: 0, minor: 3, patch: 0, })
  assert_eq(parse("bun 1.4.0 (official release)"), Semver::{
    major: 1,
    minor: 4,
    patch: 0,
  })
  assert_eq(parse("v24.0.0"), Semver::{ major: 24, minor: 0, patch: 0, })
}

///|
test "parse/no_digits_yields_zero" {
  assert_eq(parse("unknown"), Semver::{ major: 0, minor: 0, patch: 0, })
}

///|
test "parse/missing_segments_read_zero" {
  assert_eq(parse("1.4"), Semver::{ major: 1, minor: 4, patch: 0, })
  assert_eq(parse("7"), Semver::{ major: 7, minor: 0, patch: 0, })
}

///|
test "compare/ordering" {
  let low = parse("0.4.9")
  let mid = parse("0.5.0")
  let high = parse("1.0.0")
  assert_true(compare(low, mid) < 0)
  assert_true(compare(mid, high) < 0)
  assert_true(compare(high, low) > 0)
  assert_true(compare(mid, parse("0.5.0")) == 0)
}

///|
test "compare/prelease_suffix_ignored" {
  // "0.3.0-beta" compares as its release triple 0.3.0.
  assert_true(compare(parse("0.3.0-beta"), parse("0.3.0")) == 0)
  assert_true(compare(parse("0.3.0-beta"), parse("0.3.1")) < 0)
}

///|
test "bump/each_segment" {
  let v = Semver::{ major: 2, minor: 5, patch: 1, }
  assert_eq(bump(v, Major).to_string(), "3.0.0")
  assert_eq(bump(v, Minor).to_string(), "2.6.0")
  assert_eq(bump(v, Patch).to_string(), "2.5.2")
}

///|
test "to_string/roundtrip" {
  assert_eq(parse("0.22.4").to_string(), "0.22.4")
}
