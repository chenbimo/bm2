///|
/// Existence probe built on fsx itself, so the tests need no fs dependency.
fn exists(path : String) -> Bool {
  file_size(path) is Some(_)
}

///|
test "write_atomic and append_file round-trip" {
  let dir = "/tmp/fsx-test-file"
  mkdir_p(dir + "/a/b")
  let path = dir + "/a/b/state.json"
  write_atomic(path, @utf8.encode("{\"v\":1}"))
  assert_eq(@utf8.decode_lossy(read_small(path)), "{\"v\":1}")
  assert_false(exists(path + ".tmp"))
  write_atomic(path, @utf8.encode("{\"v\":2}"))
  append_file(path, @utf8.encode("\nline2\n"))
  append_file(path, @utf8.encode("line3\n"))
  assert_eq(@utf8.decode_lossy(read_small(path)), "{\"v\":2}\nline2\nline3\n")
  unlink(path)
}

///|
test "mkdir_p is idempotent" {
  mkdir_p("/tmp/fsx-test-dirs/x/y")
  mkdir_p("/tmp/fsx-test-dirs/x/y")
  assert_true(exists("/tmp/fsx-test-dirs/x/y"))
}

///|
test "chmod reports a missing path" {
  let failed = try {
    chmod("/tmp/fsx-no-such-file", 0o600)
    false
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(failed)
}

///|
/// read_small backs the /proc reads (environ, status, cmdline), which is why it
/// stops at the cap instead of growing a buffer to fit whatever it reads.
test "read_small stops at the cap" {
  let path = "/tmp/fsx-test-cap/big.txt"
  mkdir_p("/tmp/fsx-test-cap")
  write_atomic(path, @utf8.encode("x".repeat(100)))
  assert_eq(read_small(path, cap=10).length(), 10)
  assert_eq(read_small(path, cap=1000).length(), 100)
  unlink(path)
}

///|
test "file_size reports bytes and missing files" {
  let path = "/tmp/fsx-test-size/app.log"
  mkdir_p("/tmp/fsx-test-size")
  write_atomic(path, @utf8.encode("12345"))
  assert_eq(file_size(path), Some(5L))
  assert_eq(file_size(path + "/none"), None)
}

///|
/// The daemon compares config paths to decide whether two registrations name the
/// same project, so the comparison has to survive spelling differences.
test "realpath canonicalizes, and reports what it cannot resolve" {
  let dir = "/tmp/fsx-test-realpath"
  mkdir_p(dir + "/sub")
  write_atomic(dir + "/bm2.toml", @utf8.encode("name = \"app\"\n"))
  let canonical = realpath(dir + "/bm2.toml")
  assert_true(canonical is Some(_))
  // The same file spelled with a redundant `.`, and through `..`: one answer.
  assert_eq(realpath(dir + "/./bm2.toml"), canonical)
  assert_eq(realpath(dir + "/sub/../bm2.toml"), canonical)
  // A path that does not exist has no canonical form.
  assert_eq(realpath(dir + "/nope.toml"), None)
}
