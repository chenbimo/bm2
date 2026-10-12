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
  let dir = "/tmp/bm2-process-test-\{@util.get_pid()}"
  @util.mkdir_p(dir)
  let script_path = dir + "/fixture.sh"
  @util.write_atomic(script_path, @utf8.encode(fixture_script()))
  let out_log = dir + "/app.out.log"
  let err_log = dir + "/app.err.log"
  let pid = @util.spawn({
    bun_path: "/bin/sh",
    script: script_path,
    cwd: dir,
    out_log,
    err_log,
    env_blob: @util.instance_env_blob("testapp", 2, 4001),
  })
  assert_true(pid > 0)
  assert_true(@util.pid_alive(pid))
  @util.sleep_ms(500)
  match @util.read_rss_kb(pid) {
    Some(kb) => assert_true(kb > 0)
    None => fail("expected VmRSS for running process")
  }
  let out = @utf8.decode_lossy(@util.read_small(out_log))
  assert_true(out.contains("cwd=" + dir))
  assert_true(out.contains("port=4001 app=testapp id=2"))
  @util.kill_group(pid, @util.SIGTERM)
  let mut exit = None
  for _ in 0..<50 {
    match @util.wait_child(pid, nohang=true) {
      Some(reaped) => {
        exit = Some(reaped)
        break
      }
      None => @util.sleep_ms(100)
    }
  }
  assert_eq(exit, Some((pid, @util.ChildExit::Signaled(@util.SIGTERM))))
  assert_false(@util.pid_alive(pid))
  @util.unlink(script_path)
  @util.unlink(out_log)
  @util.unlink(err_log)
}

///|
test "wait_child reports exit code" {
  let dir = "/tmp/bm2-process-test-exit-\{@util.get_pid()}"
  @util.mkdir_p(dir)
  let script_path = dir + "/exit.sh"
  @util.write_atomic(script_path, @utf8.encode("exit 42\n"))
  let pid = @util.spawn({
    bun_path: "/bin/sh",
    script: script_path,
    cwd: dir,
    out_log: dir + "/o.log",
    err_log: dir + "/e.log",
    env_blob: @util.instance_env_blob("t", 0, 1),
  })
  assert_eq(@util.wait_child(pid), Some((pid, @util.ChildExit::Exited(42))))
  @util.unlink(script_path)
  @util.unlink(dir + "/o.log")
  @util.unlink(dir + "/e.log")
}

///|
test "exec failure exits 127 and chdir failure exits 126" {
  let dir = "/tmp/bm2-process-test-fail-\{@util.get_pid()}"
  @util.mkdir_p(dir)
  let bad_exec = @util.spawn({
    bun_path: "/nonexistent/bm2-nope",
    script: "x",
    cwd: dir,
    out_log: dir + "/o1.log",
    err_log: dir + "/e1.log",
    env_blob: @util.instance_env_blob("t", 0, 1),
  })
  assert_eq(
    @util.wait_child(bad_exec),
    Some((bad_exec, @util.ChildExit::Exited(127))),
  )
  let bad_cwd = @util.spawn({
    bun_path: "/bin/sh",
    script: "x",
    cwd: "/nonexistent/bm2-no-dir",
    out_log: dir + "/o2.log",
    err_log: dir + "/e2.log",
    env_blob: @util.instance_env_blob("t", 0, 1),
  })
  assert_eq(
    @util.wait_child(bad_cwd),
    Some((bad_cwd, @util.ChildExit::Exited(126))),
  )
  // chdir fails before log redirection, so no o2/e2 logs were created.
  @util.unlink(dir + "/o1.log")
  @util.unlink(dir + "/e1.log")
}

///|
test "instance_env_blob contains reserved vars" {
  let text = @utf8.decode(@util.instance_env_blob("myapp", 3, 5000))
  assert_true(text.contains("BM2_APP_NAME=myapp"))
  assert_true(text.contains("BM2_INSTANCE_ID=3"))
  assert_true(text.contains("BM2_APP_PORT=5000"))
  assert_true(text.contains("BM2_APP_INSTANCE=3"))
  assert_true(text.contains("NODE_ENV=production"))
}

///|
test "instance_env_blob carries only whitelist and reserved vars" {
  let text = @utf8.decode(@util.instance_env_blob("myapp", 2, 5001))
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
  let exe = @util.self_exe()
  assert_true(exe.has_prefix("/"))
  let cmdline = @utf8.decode_lossy(@util.read_small("/proc/self/cmdline"))
  assert_true(cmdline.length() > 0)
}

///|
test "clk_tck is a sane divisor" {
  assert_true(@util.clk_tck() >= 50)
  assert_true(@util.clk_tck() <= 10000)
}

///|
test "load_1m/sane_value" {
  let load = @util.load_1m()
  match load {
    Some(value) => inspect(value >= 0.0, content="true")
    None => ()
  }
}

///|
test "disk_free_kb/root_is_positive" {
  match @util.disk_free_kb("/tmp") {
    Some(kb) => inspect(kb > 0L, content="true")
    None => ()
  }
}

///|
test "disk_free_kb/missing_path_is_none" {
  assert_eq(@util.disk_free_kb("/nonexistent-bm2-probe"), None)
}
