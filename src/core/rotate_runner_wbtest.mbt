///|
/// Rotation is the daemon's only expensive filesystem work, so its tests live
/// here rather than next to the rotation code: this package already has the
/// async machinery the rotation task runs on, and the interesting cases are the
/// ones the supervisor and the task have to agree about.

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
/// The whole path: supervision publishes a sweep, the rotation task runs it, the
/// oversized log is rotated and the event log says so.
async test "a published sweep rotates the oversized log" {
  let root = "/tmp/bm2-wbtest-sweep-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4454)
  let state_dir = root + "/state"
  let base = state_dir + "/wbapp/logs/wbapp-0"
  // 11 MB exceeds the 10 MB rotation threshold.
  @fsx.append_file(base + ".out.log", Bytes::make(11 * 1024 * 1024, b'x'))
  sv.publish_rotation()
  let jobs = match sv.rotations().try_get() {
    Some(jobs) => jobs
    None => fail("expected publish_rotation to publish a sweep")
  }
  RotateRunner::new(state_dir, sv.rotations()).sweep(jobs)
  match @fsx.file_size(base + ".out.log.1") {
    Some(size) => assert_true(size > 10L * 1024L * 1024L)
    None => fail("expected rotated generation .out.log.1")
  }
  // The app keeps its fd: the live file is the same inode, emptied in place.
  assert_eq(@fsx.file_size(base + ".out.log"), Some(0L))
  // The crash log was never written, so its sweep rotates nothing and says
  // nothing — a missing file is the normal case, not a failure to report.
  assert_false(@fs.path_exists(base + ".crash.log.1"))
  let events = @utf8.decode_lossy(
    @fsx.read_small(state_dir + "/bm2d.events.jsonl"),
  )
  assert_true(events.contains("log_rotated"))
  assert_false(events.contains("log_rotate_failed"))
}

///|
async test "rotation leaves small files alone" {
  let path = "/tmp/bm2-wbtest-log/small.log"
  @fsx.mkdir_p("/tmp/bm2-wbtest-log")
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
    @log.maybe_rotate_async(job("/tmp/bm2-wbtest-log-missing/none.log", 1024))
    is Skipped,
  )
}

///|
async test "rotation renames past the limit" {
  let path = "/tmp/bm2-wbtest-log/renamed.log"
  // One timestamped line is ~28 bytes, over the tiny limit.
  @log.plain(path, "x")
  assert_true(@log.maybe_rotate_async(job(path, 10)) is Rotated)
  assert_false(@fsx.file_size(path) is Some(_))
  assert_true(@fsx.file_size(path + ".1") is Some(_))
}

///|
/// With a bound, the chain stops at it: the oldest generation is dropped rather
/// than shifted past the limit.
async test "rotation keeps at most ten generations" {
  let path = "/tmp/bm2-wbtest-log/gen/app.log"
  @fsx.mkdir_p("/tmp/bm2-wbtest-log/gen")
  for i in 0..<12 {
    @fsx.write_atomic(path, @utf8.encode("gen\{i}"))
    // Every written file is over this limit, so each pass rotates once.
    assert_true(@log.maybe_rotate_async(job(path, 1, keep=10)) is Rotated)
  }
  assert_false(@fsx.file_size(path) is Some(_))
  assert_true(@fsx.file_size(path + ".1") is Some(_))
  assert_true(@fsx.file_size(path + ".10") is Some(_))
  assert_false(@fsx.file_size(path + ".11") is Some(_))
  // Eleven generations were written; the oldest (gen1) fell off at the twelfth
  // rotation, so .10 holds gen2 and .1 holds gen11.
  assert_eq(@utf8.decode_lossy(@fsx.read_small(path + ".10")), "gen2")
  assert_eq(@utf8.decode_lossy(@fsx.read_small(path + ".1")), "gen11")
}

///|
/// `keep = 0` is the new default: nothing is dropped, so the chain is as long as
/// the directory says it is. The length has to be read from disk, because after a
/// restart the task has no memory of how far the chain had grown.
async test "keep = 0 lets the chain grow without dropping anything" {
  let path = "/tmp/bm2-wbtest-log/unbounded/app.log"
  @fsx.mkdir_p("/tmp/bm2-wbtest-log/unbounded")
  for i in 0..<12 {
    @fsx.write_atomic(path, @utf8.encode("gen\{i}"))
    assert_true(@log.maybe_rotate_async(job(path, 1)) is Rotated)
  }
  // Twelve writes, twelve generations, nothing dropped: .1 is the newest and
  // .12 goes all the way back to the first write.
  assert_true(@fsx.file_size(path + ".12") is Some(_))
  assert_eq(@utf8.decode_lossy(@fsx.read_small(path + ".12")), "gen0")
  assert_eq(@utf8.decode_lossy(@fsx.read_small(path + ".1")), "gen11")
}

///|
async test "copytruncate rotation empties the file in place" {
  let path = "/tmp/bm2-wbtest-log/trunc.log"
  @log.plain(path, "content")
  assert_true(
    @log.maybe_rotate_async(job(path, 10, copytruncate=true)) is Rotated,
  )
  // The content moved to the new generation and the live file is empty, so the
  // app's next write lands in a fresh file on the same inode.
  assert_eq(@utf8.decode_lossy(@fsx.read_small(path)), "")
  assert_true(
    @utf8.decode_lossy(@fsx.read_small(path + ".1")).contains("content\n"),
  )
}

///|
/// A rotation that cannot finish has to report why rather than take the rotation
/// task down with it: that task is the only thing bounding log growth, so it has
/// to outlive one bad log file. A directory where a log should be is the cheapest
/// deterministic failure — reading it raises, and the failure travels back as a
/// value.
async test "a rotation that cannot copy reports the reason" {
  let path = "/tmp/bm2-wbtest-log-blocked/app.log"
  @fsx.mkdir_p(path)
  match @log.maybe_rotate_async(job(path, 1, copytruncate=true)) {
    Failed(reason) => assert_true(reason.length() > 0)
    _ => fail("expected the rotation to report a failure")
  }
}
