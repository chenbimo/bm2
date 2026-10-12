///|
test "hex_encode lowercases and pads" {
  assert_eq(hex_encode(Bytes::from_array([])), "")
  assert_eq(hex_encode(Bytes::from_array([0x0a, 0xff])), "0aff")
  assert_eq(hex_encode(Bytes::from_array([0x00, 0x01])), "0001")
}

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
