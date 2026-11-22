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
/// 事件行与项目日志同一种格式：`时间 事件名 key=value ...`。
test "event writes one timestamped text line" {
  let path = "/tmp/log-test/events-new.log"
  // Start from nothing: this file is shared across runs and every run appends to
  // it, so without this the assertions below could read a line from an older run.
  @utils.discard(() => @fsx.unlink(path))
  event(path, "spawn_failed", [("app", "api"), ("pid", "42")])
  let line = @utf8.decode_lossy(@fsx.read_small(path))
  assert_true(line.has_prefix("20"))
  assert_true(line.contains("Z spawn_failed app=api pid=42\n"))
  // 不再有 JSON 的括号与引号
  assert_false(line.contains("{"))
  assert_false(line.contains("\"event\""))
}

///|
/// 值里有空格时要加引号，否则一行的边界就分不清了。
test "event quotes a value that contains a space" {
  let path = "/tmp/log-test/events-quoted.log"
  @utils.discard(() => @fsx.unlink(path))
  event(path, "notify_target_failed", [
    ("app", "api"),
    ("detail", "connect refused"),
  ])
  let line = @utf8.decode_lossy(@fsx.read_small(path))
  assert_true(line.contains("detail=\"connect refused\""))
}
