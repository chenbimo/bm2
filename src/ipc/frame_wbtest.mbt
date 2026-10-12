///|
test "hex_encode lowercases and pads" {
  assert_eq(hex_encode(Bytes::from_array([])), "")
  assert_eq(hex_encode(Bytes::from_array([0x0a, 0xff])), "0aff")
  assert_eq(hex_encode(Bytes::from_array([0x00, 0x01])), "0001")
}

///|
test "read_token and read_daemon_port tolerate missing files" {
  assert_eq(read_token("/tmp/dcipc-test-empty"), None)
  assert_eq(read_daemon_port("/tmp/dcipc-test-empty"), None)
}

///|
test "read_token trims and read_daemon_port validates the range" {
  let dir = "/tmp/dcipc-test-files"
  @fsx.mkdir_p(dir)
  @fsx.write_atomic(dir + "/" + TOKEN_FILE, @utf8.encode("  tok-123 \n"))
  @fsx.write_atomic(dir + "/" + PORT_FILE, @utf8.encode("41007"))
  assert_eq(read_token(dir), Some("tok-123"))
  assert_eq(read_daemon_port(dir), Some(41007))
  @fsx.write_atomic(dir + "/" + PORT_FILE, @utf8.encode("99999"))
  assert_eq(read_daemon_port(dir), None)
  @fsx.write_atomic(dir + "/" + PORT_FILE, @utf8.encode("0"))
  assert_eq(read_daemon_port(dir), None)
}
