///|
/// The upgrade path: read the published version from the registry and compare it
/// with the running one. Downloading was removed — `bm2 upgrade` now delegates to
/// `moon install`, so there is no manifest and no artifact list to test.

///|
test "parse_registry_version reads the version field" {
  let text = "{\"module\":\"chensuiyi/bm2\",\"version\":\"1.0.0\",\"metadata\":{\"version\":\"0.9.9\"}}"
  assert_eq(parse_registry_version(text), Some("1.0.0"))
}

///|
test "parse_registry_version rejects malformed input" {
  assert_eq(parse_registry_version("not json"), None)
  assert_eq(parse_registry_version("{}"), None)
  assert_eq(parse_registry_version("{\"version\":\"\"}"), None)
  assert_eq(parse_registry_version("{\"version\":1}"), None)
  assert_eq(parse_registry_version("[]"), None)
}

///|
test "upgrade only fires when the published version is newer" {
  // 版本号相对当前 VERSION 动态构造,避免每次发版手动同步测试。
  let v = @utils.parse(VERSION)
  let newer = "\{v.major}.\{v.minor}.\{v.patch + 1}"
  // 旧版本号按位退,不能直接 minor - 1:1.0.0 会拼出 1.-1.0 这种非法串,
  // 那时测的就不是比较逻辑,而是解析器遇到脏输入的反应了。
  let older = if v.patch > 0 {
    "\{v.major}.\{v.minor}.\{v.patch - 1}"
  } else if v.minor > 0 {
    "\{v.major}.\{v.minor - 1}.0"
  } else {
    "\{v.major - 1}.0.0"
  }
  assert_true(@utils.compare(@utils.parse(newer), v) > 0)
  if v.major > 0 || v.minor > 0 || v.patch > 0 {
    assert_true(@utils.compare(@utils.parse(older), v) < 0)
  }
}
