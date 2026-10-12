///|
test "plain prefixes the iso timestamp" {
  let path = "/tmp/logfly-test/app.log"
  @fsx.mkdir_p("/tmp/logfly-test")
  plain(path, "app=demo reason=test")
  let line = @utf8.decode_lossy(@fsx.read_small(path))
  assert_true(line.has_prefix("20"))
  assert_true(line.contains("T"))
  assert_true(line.has_suffix(" app=demo reason=test\n"))
}

///|
test "event writes jsonl with ts, event and caller fields" {
  let path = "/tmp/logfly-test/events.jsonl"
  event(path, "spawn_failed", [("app", @fndash.jstr("api")), ("pid", "42")])
  let line = @utf8.decode_lossy(@fsx.read_small(path))
  assert_true(line.has_prefix("{\"ts\":\"20"))
  assert_true(line.contains("\"event\":\"spawn_failed\""))
  assert_true(line.contains("\"app\":\"api\""))
  // Numbers stay raw JSON numbers, not strings.
  assert_true(line.contains("\"pid\":42"))
  assert_true(line.has_suffix("}\n"))
}

///|
test "maybe_rotate leaves small files alone" {
  let path = "/tmp/logfly-test/small.log"
  plain(path, "tiny")
  assert_false(maybe_rotate(path, 1024))
  assert_false(@fsx.file_size(path + ".1") is Some(_))
}

///|
test "maybe_rotate renames past the limit" {
  let path = "/tmp/logfly-test/renamed.log"
  // One timestamped line is ~28 bytes, over the tiny limit.
  plain(path, "x")
  assert_true(maybe_rotate(path, 10))
  assert_false(@fsx.file_size(path) is Some(_))
  assert_true(@fsx.file_size(path + ".1") is Some(_))
}

///|
test "maybe_rotate copytruncate empties in place" {
  let path = "/tmp/logfly-test/trunc.log"
  plain(path, "content")
  assert_true(maybe_rotate(path, 10, copytruncate=true))
  assert_eq(@utf8.decode_lossy(@fsx.read_small(path)), "")
  assert_true(@fsx.file_size(path + ".1") is Some(_))
}
