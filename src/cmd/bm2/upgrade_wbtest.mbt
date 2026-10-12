///|
/// The upgrade path: read the release manifest, pick this platform's
/// artifacts, and compare the published version with the running one.
/// 清单条文见 yicode-tech 仓库 `specs/update-spec.md`。

///|
fn manifest_fixture(target : String) -> String {
  "{\"version\":\"0.7.0\",\"artifacts\":[" +
  "{\"name\":\"bm2\",\"target\":\"" +
  target +
  "\",\"url\":\"https://static2.yicode.tech/products/bm2/" +
  target +
  "/bm2-v0.7.0\",\"sha256\":\"aa\",\"fileSize\":1024}," +
  "{\"name\":\"bm2d\",\"target\":\"" +
  target +
  "\",\"url\":\"https://static2.yicode.tech/products/bm2/" +
  target +
  "/bm2d-v0.7.0\",\"sha256\":\"bb\",\"fileSize\":2048}]}"
}

///|
test "parse_manifest reads version and artifacts" {
  let parsed = parse_manifest(manifest_fixture("linux-x64"))
  let (version, artifacts) = match parsed {
    Some(value) => value
    None => fail("expected a manifest")
  }
  assert_eq(version, "0.7.0")
  assert_eq(artifacts.length(), 2)
  assert_eq(artifacts[0].name, "bm2")
  assert_eq(artifacts[0].target, "linux-x64")
  assert_eq(artifacts[1].sha256, "bb")
}

///|
test "parse_manifest rejects malformed input" {
  assert_eq(parse_manifest("not json"), None)
  assert_eq(parse_manifest("{\"artifacts\":[]}"), None)
  assert_eq(parse_manifest("{\"version\":\"0.7.0\"}"), None)
}

///|
test "pick_artifacts takes both binaries for the matching platform" {
  let (_, artifacts) = match parse_manifest(manifest_fixture("linux-x64")) {
    Some(value) => value
    None => fail("expected a manifest")
  }
  let picked = match pick_artifacts(artifacts, "linux-x64", ["bm2", "bm2d"]) {
    Some(items) => items
    None => fail("expected both binaries")
  }
  assert_eq(picked.length(), 2)
  // 平台不匹配:整组拒绝,避免半更新。
  assert_eq(pick_artifacts(artifacts, "win-x64", ["bm2", "bm2d"]), None)
}

///|
test "pick_artifacts falls back to any" {
  let (_, artifacts) = match
    parse_manifest(
      "{\"version\":\"1.0.0\",\"artifacts\":[{\"name\":\"bm2\",\"target\":\"any\",\"url\":\"https://example.com/bm2\",\"sha256\":\"cc\",\"fileSize\":1}]}",
    ) {
    Some(value) => value
    None => fail("expected a manifest")
  }
  let picked = match pick_artifacts(artifacts, "linux-arm64", ["bm2"]) {
    Some(items) => items
    None => fail("expected the any artifact")
  }
  assert_eq(picked[0].target, "any")
  // any 不能替代缺失的必需产物。
  assert_eq(pick_artifacts(artifacts, "linux-arm64", ["bm2", "bm2d"]), None)
}

///|
test "upgrade only fires when the published version is newer" {
  // 版本号相对当前 VERSION 动态构造,避免每次发版手动同步测试。
  let v = @semver.parse(VERSION)
  let newer = "\{v.major}.\{v.minor}.\{v.patch + 1}"
  let older = "\{v.major}.\{v.minor - 1}.\{v.patch}"
  assert_true(@semver.compare(@semver.parse(newer), v) > 0)
  assert_true(@semver.compare(@semver.parse(older), v) < 0)
}
