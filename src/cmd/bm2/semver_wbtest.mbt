///|
test "semver_cmp compares plain versions" {
  assert_eq(semver_cmp("0.2.2", "0.2.2"), 0)
  assert_eq(semver_cmp("0.2.3", "0.2.2"), 1)
  assert_eq(semver_cmp("0.2.2", "0.3.0"), -1)
  assert_eq(semver_cmp("1.0.0", "0.9.9"), 1)
  assert_eq(semver_cmp("0.10.0", "0.9.0"), 1)
}

///|
test "semver_cmp treats pre-release suffixes as their base version" {
  assert_eq(semver_cmp("0.3.0-beta", "0.3.0"), 0)
  assert_eq(semver_cmp("0.3.0-rc.1", "0.3.0-rc.2"), 0)
  assert_eq(semver_cmp("1.2.3-beta.2", "1.2.3-alpha"), 0)
}

///|
test "latest_version returns the last parseable line" {
  let index = "{\"version\":\"0.1.0\"}\n{\"version\":\"0.2.0\"}\n{\"version\":\"0.2.2\"}\n"
  assert_eq(latest_version(index), Some("0.2.2"))
  assert_eq(latest_version("garbage\n{\"version\":\"0.2.2\"}"), Some("0.2.2"))
  assert_eq(latest_version("not json"), None)
  assert_eq(latest_version(""), None)
}
