///|
test "read_endpoint tolerates a missing file" {
  assert_eq(read_endpoint("/tmp/dcipc-test-empty"), None)
}

///|
test "read_endpoint validates both halves" {
  let dir = "/tmp/dcipc-test-files"
  @fsx.mkdir_p(dir)
  @fsx.write_atomic(dir + "/" + ENDPOINT_FILE, @utf8.encode("41007\ntok-123\n"))
  assert_eq(read_endpoint(dir), Some((41007, "tok-123")))
  // A port out of range, an empty token, and a file with no separator are all
  // "no daemon" to the caller.
  @fsx.write_atomic(dir + "/" + ENDPOINT_FILE, @utf8.encode("99999\ntok\n"))
  assert_eq(read_endpoint(dir), None)
  @fsx.write_atomic(dir + "/" + ENDPOINT_FILE, @utf8.encode("41007\n\n"))
  assert_eq(read_endpoint(dir), None)
  @fsx.write_atomic(dir + "/" + ENDPOINT_FILE, @utf8.encode("41007"))
  assert_eq(read_endpoint(dir), None)
}

///|
/// 令牌是 32 字节内核随机数的 hex：64 个字符、只含 0-9a-f、每次不同。
/// 这三条合起来才能说明它不是拿时间或计数器凑出来的。
test "generate_token is 64 hex chars and varies" {
  let a = generate_token()
  let b = generate_token()
  assert_eq(a.length(), 64)
  assert_eq(b.length(), 64)
  assert_true(a != b)
  for ch in a.to_array() {
    assert_true((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))
  }
}
