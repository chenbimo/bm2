///|
test "plain prefixes the iso timestamp" {
  let path = "/tmp/log-test/app.log"
  @fsx.mkdir_p("/tmp/log-test")
  plain(path, "app=demo reason=test")
  let line = @utf8.decode_lossy(@fsx.read_small(path))
  assert_true(line.has_prefix("20"))
  assert_true(line.contains("T"))
  assert_true(line.has_suffix(" app=demo reason=test\n"))
}

///|
test "event writes jsonl with ts, event and caller fields" {
  let path = "/tmp/log-test/events.jsonl"
  // Start from nothing: this file is shared across runs and every run appends to
  // it, so without this the assertions below could read a line from an older run.
  @utils.discard(() => @fsx.unlink(path))
  event(path, "spawn_failed", [("app", @utils.jstr("api")), ("pid", "42")])
  let line = @utf8.decode_lossy(@fsx.read_small(path))
  assert_true(line.has_prefix("{\"ts\":\"20"))
  assert_true(line.contains("\"event\":\"spawn_failed\""))
  assert_true(line.contains("\"app\":\"api\""))
  // Numbers stay raw JSON numbers, not strings.
  assert_true(line.contains("\"pid\":42"))
  assert_true(line.has_suffix("}\n"))
}
