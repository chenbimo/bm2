///|
fn fixture_script() -> String {
  (
    #|#!/bin/sh
    #|echo "cwd=$(pwd)"
    #|echo "port=$BM2_APP_PORT app=$BM2_APP_NAME id=$BM2_INSTANCE_ID"
    #|while true; do sleep 1; done
    #|
  )
}

///|
test "spawn runs script with env, cwd and log redirection" {
  let dir = "/tmp/bm2-process-test-\{@subproc.get_pid()}"
  @fsx.mkdir_p(dir)
  let script_path = dir + "/fixture.sh"
  @fsx.write_atomic(script_path, @utf8.encode(fixture_script()))
  let out_log = dir + "/app.out.log"
  let err_log = dir + "/app.err.log"
  let pid = @subproc.spawn({
    bun_path: "/bin/sh",
    script: script_path,
    cwd: dir,
    out_log,
    err_log,
    env_blob: @subproc.instance_env_blob("testapp", 2, 4001),
  })
  assert_true(pid > 0)
  assert_true(@subproc.pid_alive(pid))
  @subproc.sleep_ms(500)
  match @subproc.read_rss_kb(pid) {
    Some(kb) => assert_true(kb > 0)
    None => fail("expected VmRSS for running process")
  }
  let out = @utf8.decode_lossy(@fsx.read_small(out_log))
  assert_true(out.contains("cwd=" + dir))
  assert_true(out.contains("port=4001 app=testapp id=2"))
  @subproc.kill_group(pid, @subproc.SIGTERM)
  let mut exit = None
  for _ in 0..<50 {
    match @subproc.wait_child(pid, nohang=true) {
      Some(reaped) => {
        exit = Some(reaped)
        break
      }
      None => @subproc.sleep_ms(100)
    }
  }
  assert_eq(exit, Some((pid, @subproc.ChildExit::Signaled(@subproc.SIGTERM))))
  assert_false(@subproc.pid_alive(pid))
  @fsx.unlink(script_path)
  @fsx.unlink(out_log)
  @fsx.unlink(err_log)
}

///|
test "wait_child reports exit code" {
  let dir = "/tmp/bm2-process-test-exit-\{@subproc.get_pid()}"
  @fsx.mkdir_p(dir)
  let script_path = dir + "/exit.sh"
  @fsx.write_atomic(script_path, @utf8.encode("exit 42\n"))
  let pid = @subproc.spawn({
    bun_path: "/bin/sh",
    script: script_path,
    cwd: dir,
    out_log: dir + "/o.log",
    err_log: dir + "/e.log",
    env_blob: @subproc.instance_env_blob("t", 0, 1),
  })
  assert_eq(
    @subproc.wait_child(pid),
    Some((pid, @subproc.ChildExit::Exited(42))),
  )
  @fsx.unlink(script_path)
  @fsx.unlink(dir + "/o.log")
  @fsx.unlink(dir + "/e.log")
}

///|
test "exec failure exits 127 and chdir failure exits 126" {
  let dir = "/tmp/bm2-process-test-fail-\{@subproc.get_pid()}"
  @fsx.mkdir_p(dir)
  let bad_exec = @subproc.spawn({
    bun_path: "/nonexistent/bm2-nope",
    script: "x",
    cwd: dir,
    out_log: dir + "/o1.log",
    err_log: dir + "/e1.log",
    env_blob: @subproc.instance_env_blob("t", 0, 1),
  })
  assert_eq(
    @subproc.wait_child(bad_exec),
    Some((bad_exec, @subproc.ChildExit::Exited(127))),
  )
  let bad_cwd = @subproc.spawn({
    bun_path: "/bin/sh",
    script: "x",
    cwd: "/nonexistent/bm2-no-dir",
    out_log: dir + "/o2.log",
    err_log: dir + "/e2.log",
    env_blob: @subproc.instance_env_blob("t", 0, 1),
  })
  assert_eq(
    @subproc.wait_child(bad_cwd),
    Some((bad_cwd, @subproc.ChildExit::Exited(126))),
  )
  // chdir fails before log redirection, so no o2/e2 logs were created.
  @fsx.unlink(dir + "/o1.log")
  @fsx.unlink(dir + "/e1.log")
}

///|
test "instance_env_blob contains reserved vars" {
  let text = @utf8.decode(@subproc.instance_env_blob("myapp", 3, 5000))
  assert_true(text.contains("BM2_APP_NAME=myapp"))
  assert_true(text.contains("BM2_INSTANCE_ID=3"))
  assert_true(text.contains("BM2_APP_PORT=5000"))
  assert_true(text.contains("BM2_APP_INSTANCE=3"))
  assert_true(text.contains("NODE_ENV=production"))
}

///|
test "instance_env_blob carries only whitelist and reserved vars" {
  let text = @utf8.decode(@subproc.instance_env_blob("myapp", 2, 5001))
  let allowed = [
    "PATH", "HOME", "TMPDIR", "BM2_APP_NAME", "BM2_INSTANCE_ID", "BM2_APP_INSTANCE",
    "BM2_APP_PORT", "NODE_ENV",
  ]
  let mut seen = 0
  for entry in text.split("\u{0}") {
    if entry.is_empty() {
      continue
    }
    seen += 1
    let mut key = entry.to_owned()
    for part in entry.split("=") {
      key = part.to_owned()
      break
    }
    // Whitelist + reserved, plus every BM2_* variable the caller environment
    // carries (credential pass-through by design).
    assert_true(allowed.contains(key) || key.has_prefix("BM2_"))
  }
  // whitelist (PATH/HOME/TMPDIR, present in the test environment) + 5
  // reserved vars; at least 5 entries must exist.
  assert_true(seen >= 5)
}

///|
test "self_exe and fsx read_small work on proc files" {
  let exe = @subproc.self_exe()
  assert_true(exe.has_prefix("/"))
  let cmdline = @utf8.decode_lossy(@fsx.read_small("/proc/self/cmdline"))
  assert_true(cmdline.length() > 0)
}

///|
test "clk_tck is a sane divisor" {
  assert_true(@subproc.clk_tck() >= 50)
  assert_true(@subproc.clk_tck() <= 10000)
}

///|
test "load_1m/sane_value" {
  let load = @subproc.load_1m()
  match load {
    Some(value) => inspect(value >= 0.0, content="true")
    None => ()
  }
}

///|
test "disk_free_kb/root_is_positive" {
  match @subproc.disk_free_kb("/tmp") {
    Some(kb) => inspect(kb > 0L, content="true")
    None => ()
  }
}

///|
test "disk_free_kb/missing_path_is_none" {
  assert_eq(@subproc.disk_free_kb("/nonexistent-bm2-probe"), None)
}
