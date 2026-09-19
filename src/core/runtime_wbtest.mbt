///|
test "parse_version skips prefixes and stops at suffixes" {
  assert_eq(parse_version("1.4.0"), (1, 4, 0))
  assert_eq(parse_version("v24.1.3\n"), (24, 1, 3))
  assert_eq(parse_version("bun 1.2.3-debug\n"), (1, 2, 3))
  assert_eq(parse_version("1.4"), (1, 4, 0))
  assert_eq(parse_version(""), (0, 0, 0))
  assert_eq(parse_version("no digits here"), (0, 0, 0))
}

///|
test "version_compare orders versions and treats suffixes as their base" {
  assert_eq(version_compare("0.2.2", "0.2.2"), 0)
  assert_eq(version_compare("0.2.3", "0.2.2"), 1)
  assert_eq(version_compare("0.2.2", "0.3.0"), -1)
  assert_eq(version_compare("1.0.0", "0.9.9"), 1)
  assert_eq(version_compare("0.10.0", "0.9.0"), 1)
  assert_eq(version_compare("0.3.0-beta", "0.3.0"), 0)
  assert_eq(version_compare("0.3.0-rc.1", "0.3.0-rc.2"), 0)
  assert_eq(version_compare("1.2.3-beta.2", "1.2.3-alpha"), 0)
  // Both sides go through the same parser, so a "v" prefix is skipped.
  assert_eq(version_compare("v1.4.0", "1.4.0"), 0)
  assert_eq(version_compare("1.4", "1.4.0"), 0)
}

///|
test "version_at_least enforces minimums" {
  assert_true(version_at_least((1, 4, 0), (1, 4, 0)))
  assert_true(version_at_least((1, 4, 1), (1, 4, 0)))
  assert_true(version_at_least((2, 0, 0), (1, 4, 0)))
  assert_true(version_at_least((24, 0, 1), (24, 0, 0)))
  assert_false(version_at_least((1, 3, 9), (1, 4, 0)))
  assert_false(version_at_least((23, 11, 0), (24, 0, 0)))
  assert_false(version_at_least((1, 4, 0), (1, 4, 1)))
}

///|
test "check_runtime rejects a missing runtime with a clear reason" {
  let sv = Supervisor::new(
    state_dir="/tmp/bm2-runtime-test-\{@process.get_pid()}",
    bun_path="bun",
  )
  let rejected = try sv.check_runtime("no-such-runtime-bm2") catch {
    e => e.to_string()
  } noraise {
    _ => "no error"
  }
  assert_true(rejected.contains("runtime rejected"))
  assert_true(rejected.contains("no-such-runtime-bm2"))
  assert_true(rejected.contains("not found on PATH"))
}
