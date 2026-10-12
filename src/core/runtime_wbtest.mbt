///|
/// The probe is the daemon's one blocking call, so a runtime that never
/// answers must be killed and reported, not waited on: this is the test that
/// would hang the whole suite if the timeout regressed.
test "check_runtime gives up on a runtime that never answers" {
  let root = "/tmp/bm2-runtime-hang-\{@subproc.get_pid()}"
  @fsx.mkdir_p(root)
  let hang = root + "/hang.sh"
  @fs.write_string_to_file(hang, "#!/bin/sh\nwhile true; do sleep 1; done\n")
  @fsx.chmod(hang, 0o755)
  let sv = Supervisor::new(state_dir=root + "/state", bun_path="bun")
  let started = @env.now()
  let rejected = try sv.check_runtime(hang) catch {
    e => e.to_string()
  } noraise {
    _ => "no error"
  }
  let elapsed = @env.now() - started
  assert_true(rejected.contains("runtime rejected"))
  // Both timeout outcomes (killed, or unkillable and given up on) name the
  // probe deadline, so the message stays diagnostic either way.
  assert_true(rejected.contains("5000ms"))
  assert_true(elapsed < 30000UL)
  @fsx.unlink(hang)
}

///|
test "check_runtime rejects a missing runtime with a clear reason" {
  let sv = Supervisor::new(
    state_dir="/tmp/bm2-runtime-test-\{@subproc.get_pid()}",
    bun_path="bun",
  )
  let rejected = try sv.check_runtime("no-such-runtime-bm2") catch {
    e => e.to_string()
  } noraise {
    _ => "no error"
  }
  assert_true(rejected.contains("runtime rejected"))
  assert_true(rejected.contains("no-such-runtime-bm2"))
  assert_true(rejected.contains("not found on PATH"))
}
