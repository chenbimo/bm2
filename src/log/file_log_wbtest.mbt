///|
/// 建一个本次运行专用的日志目录。目录名带毫秒时间戳，测试重复跑也不会互相踩。
fn log_test_dir(tag : String) -> String raise {
  let dir = "/tmp/bm2-file-log-" + tag + "-" + @utils.now_ms().to_string()
  @fsx.mkdir_p(dir)
  dir
}

///|
async fn log_write(stream : LogStream, text : String) -> Unit {
  stream.append(text)
}

///|
async fn has_file(dir : String, name : String) -> Bool {
  try @fs.exists(@utils.join_path(dir, name)) catch {
    _ => false
  } noraise {
    v => v
  }
}

///|
async test "append rotates once the current file would exceed the limit" {
  let dir = log_test_dir("rotate")
  let stream = LogStream::new(dir, "api", "", 100L, 3)
  log_write(stream, "aaaaaaaaaa\n")
  log_write(stream, "bbbbbbbbbb\n")
  // 20 字节之后再来 100 字节：一次超限，当前文件挪成 .1，新的从头写。
  log_write(stream, "c".repeat(95) + "\n")
  let current = @utf8.decode_lossy(
    @fsx.read_small(@utils.join_path(dir, "api.log")),
  )
  let previous = @utf8.decode_lossy(
    @fsx.read_small(@utils.join_path(dir, "api.1.log")),
  )
  assert_true(current.contains("ccc"))
  assert_false(current.contains("aaa"))
  assert_true(previous.contains("aaaaaaaaaa"))
}

///|
async test "keep caps how many generations survive" {
  let dir = log_test_dir("keep")
  let stream = LogStream::new(dir, "api", "", 10L, 2)
  // 每一批都超限，连转四轮：只该留下 api.log / api.1.log / api.2.log。
  for round in 0..<4 {
    log_write(stream, "line-" + round.to_string() + "\n")
  }
  assert_true(has_file(dir, "api.log"))
  assert_true(has_file(dir, "api.1.log"))
  assert_true(has_file(dir, "api.2.log"))
  assert_false(has_file(dir, "api.3.log"))
}

///|
/// `keep = 0` 不留历史：轮转只清空当前文件，不产生那个永远只有一行的 `.1`。
async test "keep zero truncates instead of archiving" {
  let dir = log_test_dir("keepzero")
  let stream = LogStream::new(dir, "api", "", 10L, 0)
  log_write(stream, "first-batch\n")
  log_write(stream, "second-batch\n")
  let current = @utf8.decode_lossy(
    @fsx.read_small(@utils.join_path(dir, "api.log")),
  )
  assert_true(current.contains("second"))
  assert_false(current.contains("first"))
  assert_false(has_file(dir, "api.1.log"))
}

///|
/// 配置被调小时，prune 带走多出来的代数；另一条流（`.error`）的文件不动。
async test "prune drops generations beyond keep and leaves the error stream alone" {
  let dir = log_test_dir("prune")
  let normal = LogStream::new(dir, "api", "", 10L, 3)
  for round in 0..<4 {
    log_write(normal, "line-" + round.to_string() + "\n")
  }
  let error = LogStream::new(dir, "api", ".error", 10L, 3)
  for round in 0..<4 {
    log_write(error, "err-" + round.to_string() + "\n")
  }
  // 普通流此刻有 .1 .2 .3；把上限收到 1 代再清一次。
  let shrunk = LogStream::new(dir, "api", "", 10L, 1)
  shrunk.prune()
  assert_true(has_file(dir, "api.1.log"))
  assert_false(has_file(dir, "api.2.log"))
  assert_false(has_file(dir, "api.3.log"))
  // 错误流没被普通流的清理牵连。
  assert_true(has_file(dir, "api.error.1.log"))
  assert_true(has_file(dir, "api.error.2.log"))
}
