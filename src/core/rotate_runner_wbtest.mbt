///|
/// Rotation is the daemon's only expensive filesystem work, so its tests live
/// here rather than next to the rotation code: this package already has the
/// async machinery the rotation task runs on, and the interesting cases are the
/// ones the supervisor and the task have to agree about.

///|
/// 本文件专用的临时目录：路径里带 pid，两次运行（或并行跑的测试）不会共用
/// 同一个目录。以前用的是固定的 `/tmp/bm2-wbtest-log`，靠外部先删干净才稳定，
/// 留一个文件在那里就会让断言看到上一次的产物。
fn wb_scratch(tag : String) -> String {
  "/tmp/bm2-wbtest-" + tag + "-" + @proc.get_pid().to_string()
}

///|
/// One job, built the way supervision builds it: the path, who holds the file
/// open, and the policy the project asked for.
fn job(
  path : String,
  max_bytes : Int64,
  copytruncate~ : Bool = false,
  keep~ : Int32 = 0,
) -> @log.RotateJob {
  { path, copytruncate, max_bytes, keep, }
}

///|
/// The whole path for the daemon's own logs: supervision publishes a sweep, the
/// rotation task runs it, the oversized event log is rotated and the event log
/// says so.
///
/// 项目日志不走这条链路了：它们由收集任务写主日志，轮转在 `LogStream` 里按
/// 大小与代数完成，测试在 log 包内。
async test "a published sweep rotates the oversized daemon log" {
  let root = "/tmp/bm2-wbtest-sweep-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4454)
  let state_dir = root + "/state"
  let target = state_dir + "/bm2d.events.log"
  // 11 MB exceeds the 10 MB rotation threshold.
  @fsx.append_file(target, Bytes::make(11 * 1024 * 1024, b'x'))
  sv.publish_daemon_rotation()
  let jobs = match sv.rotations().try_get() {
    Some(jobs) => jobs
    None => fail("expected publish_daemon_rotation to publish a sweep")
  }
  RotateRunner::new(state_dir, sv.rotations(), sv.log_tasks()).sweep(jobs)
  // 代数插在 `.log` 之前：bm2d.events.1.log。
  match @fsx.file_size(state_dir + "/bm2d.events.1.log") {
    Some(size) => assert_true(size > 10L * 1024L * 1024L)
    None => fail("expected rotated generation .1.log")
  }
  // sweep 自己会往事件日志里记一行，所以这里只要求它被截到很小的量级。
  match @fsx.file_size(target) {
    Some(size) => assert_true(size < 1024L)
    None => fail("expected the live log to exist after rotation")
  }
}

///|
async test "rotation leaves small files alone" {
  let dir = wb_scratch("small")
  @fsx.mkdir_p(dir)
  let path = dir + "/small.log"
  // This is the one case that depends on the file staying small, and every run
  // appends a line to it: start from nothing so a repeated run cannot creep past
  // the limit and rotate where the test says it must not.
  @utils.discard(() => @fsx.unlink(path))
  @utils.discard(() => @fsx.unlink(path + ".1"))
  @log.plain(path, "tiny")
  assert_true(@log.maybe_rotate_async(job(path, 1024)) is Skipped)
  assert_false(@fsx.file_size(path + ".1") is Some(_))
}

///|
/// Rotation sweeps every registered instance, including ones that have never
/// written a line, so a missing file has to be a no-op rather than a failure the
/// operator reads about on every sweep.
async test "rotation is a no-op for a log that is not there" {
  assert_true(
    @log.maybe_rotate_async(job(wb_scratch("missing") + "/none.log", 1024))
    is Skipped,
  )
}

///|
async test "rotation renames past the limit" {
  let dir = wb_scratch("renamed")
  @fsx.mkdir_p(dir)
  let path = dir + "/renamed.log"
  // One timestamped line is ~28 bytes, over the tiny limit.
  @log.plain(path, "x")
  assert_true(@log.maybe_rotate_async(job(path, 10)) is Rotated)
  assert_false(@fsx.file_size(path) is Some(_))
  // 代数插在 `.log` 之前，全仓统一：`renamed.1.log`，不是 `renamed.log.1`。
  assert_true(@fsx.file_size(dir + "/renamed.1.log") is Some(_))
}

///|
/// With a bound, the chain stops at it: the oldest generation is dropped rather
/// than shifted past the limit.
async test "rotation keeps at most ten generations" {
  let dir = wb_scratch("gen")
  @fsx.mkdir_p(dir)
  let path = dir + "/app.log"
  for i in 0..<12 {
    @fsx.write_atomic(path, @utf8.encode("gen\{i}"))
    // Every written file is over this limit, so each pass rotates once.
    assert_true(@log.maybe_rotate_async(job(path, 1, keep=10)) is Rotated)
  }
  assert_false(@fsx.file_size(path) is Some(_))
  assert_true(@fsx.file_size(dir + "/app.1.log") is Some(_))
  assert_true(@fsx.file_size(dir + "/app.10.log") is Some(_))
  assert_false(@fsx.file_size(dir + "/app.11.log") is Some(_))
  // Eleven generations were written; the oldest (gen1) fell off at the twelfth
  // rotation, so .10 holds gen2 and .1 holds gen11.
  assert_eq(@utf8.decode_lossy(@fsx.read_small(dir + "/app.10.log")), "gen2")
  assert_eq(@utf8.decode_lossy(@fsx.read_small(dir + "/app.1.log")), "gen11")
}

///|
/// `keep = 0` is the new default: nothing is dropped, so the chain is as long as
/// the directory says it is. The length has to be read from disk, because after a
/// restart the task has no memory of how far the chain had grown.
async test "keep = 0 lets the chain grow without dropping anything" {
  let dir = wb_scratch("unbounded")
  @fsx.mkdir_p(dir)
  let path = dir + "/app.log"
  for i in 0..<12 {
    @fsx.write_atomic(path, @utf8.encode("gen\{i}"))
    assert_true(@log.maybe_rotate_async(job(path, 1)) is Rotated)
  }
  // Twelve writes, twelve generations, nothing dropped: .1 is the newest and
  // .12 goes all the way back to the first write.
  let oldest = dir + "/app.12.log"
  let newest = dir + "/app.1.log"
  assert_true(@fsx.file_size(oldest) is Some(_))
  assert_eq(@utf8.decode_lossy(@fsx.read_small(oldest)), "gen0")
  assert_eq(@utf8.decode_lossy(@fsx.read_small(newest)), "gen11")
}

///|
async test "copytruncate rotation empties the file in place" {
  let dir = wb_scratch("trunc")
  @fsx.mkdir_p(dir)
  let path = dir + "/trunc.log"
  @log.plain(path, "content")
  assert_true(
    @log.maybe_rotate_async(job(path, 10, copytruncate=true)) is Rotated,
  )
  // The content moved to the new generation and the live file is empty, so the
  // app's next write lands in a fresh file on the same inode.
  assert_eq(@utf8.decode_lossy(@fsx.read_small(path)), "")
  assert_true(
    @utf8.decode_lossy(@fsx.read_small(dir + "/trunc.1.log")).contains(
      "content\n",
    ),
  )
}

///|
/// A rotation that cannot finish has to report why rather than take the rotation
/// task down with it: that task is the only thing bounding log growth, so it has
/// to outlive one bad log file. A directory where a log should be is the cheapest
/// deterministic failure — reading it raises, and the failure travels back as a
/// value.
async test "a rotation that cannot copy reports the reason" {
  let dir = wb_scratch("blocked")
  @fsx.mkdir_p(dir)
  let path = dir + "/app.log"
  @fsx.mkdir_p(path)
  match @log.maybe_rotate_async(job(path, 1, copytruncate=true)) {
    Failed(reason) => assert_true(reason.length() > 0)
    _ => fail("expected the rotation to report a failure")
  }
}
