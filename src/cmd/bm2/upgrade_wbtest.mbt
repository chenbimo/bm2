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
  // 版本号相对当前 VERSION 动态构造,避免每次发版手动同步测试。
  let v = @semver.parse(VERSION)
  let newer = "\{v.major}.\{v.minor}.\{v.patch + 1}"
  let older = "\{v.major}.\{v.minor - 1}.\{v.patch}"
  let index = "{\"version\":\"" +
    older +
    "\"}\n{\"version\":\"" +
    newer +
    "\"}\n"
  let latest = match latest_version(index) {
    Some(version) => version
    None => fail("expected a published version")
  }
  // 索引里最新的是 newer,比当前新:升级应触发。
  assert_true(@semver.compare(@semver.parse(latest), v) > 0)
  assert_true(@semver.compare(@semver.parse(newer), v) > 0)
  assert_true(@semver.compare(@semver.parse(older), v) < 0)
}
