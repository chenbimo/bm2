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
