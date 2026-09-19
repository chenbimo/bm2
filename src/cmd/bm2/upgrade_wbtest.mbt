///|
/// The upgrade path: read the published version out of the mooncakes index
/// and compare it with the running one through the shared comparator.
test "latest_version returns the last parseable line" {
  let index = "{\"version\":\"0.1.0\"}\n{\"version\":\"0.2.0\"}\n{\"version\":\"0.2.2\"}\n"
  assert_eq(latest_version(index), Some("0.2.2"))
  assert_eq(latest_version("garbage\n{\"version\":\"0.2.2\"}"), Some("0.2.2"))
  assert_eq(latest_version("not json"), None)
  assert_eq(latest_version(""), None)
}

///|
test "upgrade only fires when the published version is newer" {
  let index = "{\"version\":\"0.4.0\"}\n{\"version\":\"0.4.1\"}\n"
  let latest = match latest_version(index) {
    Some(version) => version
    None => fail("expected a published version")
  }
  assert_eq(@core.version_compare(latest, VERSION), 0)
  assert_true(@core.version_compare("0.4.2", VERSION) > 0)
  assert_true(@core.version_compare("0.3.9", VERSION) < 0)
}
