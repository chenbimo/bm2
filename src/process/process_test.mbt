///|
fn fixture_script() -> String {
  (
    #|#!/bin/sh
    #|echo "cwd=$(pwd)"
    #|echo "port=$PORT app=$BM2_APP_NAME id=$BM2_INSTANCE_ID"
    #|while true; do sleep 1; done
    #|
  )
}

///|
test "spawn runs script with env, cwd and log redirection" {
  let dir = "/tmp/bm2-process-test-\{@process.get_pid()}"
  @process.mkdir_p(dir)
  let script_path = dir + "/fixture.sh"
  @fs.write_string_to_file(script_path, fixture_script())
  let out_log = dir + "/app.out.log"
  let err_log = dir + "/app.err.log"
  let pid = @process.spawn({
    bun_path: "/bin/sh",
    script: script_path,
    cwd: dir,
    out_log,
    err_log,
    env_blob: @process.instance_env_blob("testapp", 2, 4001, Map([])),
  })
  assert_true(pid > 0)
  assert_true(@process.pid_alive(pid))
  @process.sleep_ms(500)
  match @process.read_rss_kb(pid) {
    Some(kb) => assert_true(kb > 0)
    None => fail("expected VmRSS for running process")
  }
  let out = @fs.read_file_to_string(out_log)
  assert_true(out.contains("cwd=" + dir))
  assert_true(out.contains("port=4001 app=testapp id=2"))
  @process.kill_group(pid, @process.SIGTERM)
  let mut exit = None
  for _ in 0..<50 {
    match @process.wait_child(pid, nohang=true) {
      Some(reaped) => {
        exit = Some(reaped)
        break
      }
      None => @process.sleep_ms(100)
    }
  }
  assert_eq(exit, Some((pid, @process.ChildExit::Signaled(@process.SIGTERM))))
  assert_false(@process.pid_alive(pid))
  @process.unlink(script_path)
  @process.unlink(out_log)
  @process.unlink(err_log)
  @fs.remove_dir(dir)
}

///|
test "wait_child reports exit code" {
  let dir = "/tmp/bm2-process-test-exit-\{@process.get_pid()}"
  @process.mkdir_p(dir)
  let script_path = dir + "/exit.sh"
  @fs.write_string_to_file(script_path, "exit 42\n")
  let pid = @process.spawn({
    bun_path: "/bin/sh",
    script: script_path,
    cwd: dir,
    out_log: dir + "/o.log",
    err_log: dir + "/e.log",
    env_blob: @process.instance_env_blob("t", 0, 1, Map([])),
  })
  assert_eq(
    @process.wait_child(pid),
    Some((pid, @process.ChildExit::Exited(42))),
  )
  @process.unlink(script_path)
  @process.unlink(dir + "/o.log")
  @process.unlink(dir + "/e.log")
  @fs.remove_dir(dir)
}

///|
test "exec failure exits 127 and chdir failure exits 126" {
  let dir = "/tmp/bm2-process-test-fail-\{@process.get_pid()}"
  @process.mkdir_p(dir)
  let bad_exec = @process.spawn({
    bun_path: "/nonexistent/bm2-nope",
    script: "x",
    cwd: dir,
    out_log: dir + "/o1.log",
    err_log: dir + "/e1.log",
    env_blob: @process.instance_env_blob("t", 0, 1, Map([])),
  })
  assert_eq(
    @process.wait_child(bad_exec),
    Some((bad_exec, @process.ChildExit::Exited(127))),
  )
  let bad_cwd = @process.spawn({
    bun_path: "/bin/sh",
    script: "x",
    cwd: "/nonexistent/bm2-no-dir",
    out_log: dir + "/o2.log",
    err_log: dir + "/e2.log",
    env_blob: @process.instance_env_blob("t", 0, 1, Map([])),
  })
  assert_eq(
    @process.wait_child(bad_cwd),
    Some((bad_cwd, @process.ChildExit::Exited(126))),
  )
  // chdir fails before log redirection, so no o2/e2 logs were created.
  @process.unlink(dir + "/o1.log")
  @process.unlink(dir + "/e1.log")
  @fs.remove_dir(dir)
}

///|
test "write_atomic and append_file round-trip" {
  let dir = "/tmp/bm2-process-test-file-\{@process.get_pid()}"
  @process.mkdir_p(dir + "/a/b")
  let path = dir + "/a/b/state.json"
  @process.write_atomic(path, @utf8.encode("{\"v\":1}"))
  assert_eq(@fs.read_file_to_string(path), "{\"v\":1}")
  assert_false(@fs.path_exists(path + ".tmp"))
  @process.write_atomic(path, @utf8.encode("{\"v\":2}"))
  @process.append_file(path, @utf8.encode("\nline2\n"))
  @process.append_file(path, @utf8.encode("line3\n"))
  assert_eq(@fs.read_file_to_string(path), "{\"v\":2}\nline2\nline3\n")
  @process.unlink(path)
  @fs.remove_dir(dir + "/a/b")
  @fs.remove_dir(dir + "/a")
  @fs.remove_dir(dir)
}

///|
test "instance_env_blob contains app and reserved vars" {
  let text = @utf8.decode(
    @process.instance_env_blob("myapp", 3, 5000, { "NODE_ENV": "test" }),
  )
  assert_true(text.contains("NODE_ENV=test"))
  assert_true(text.contains("BM2_APP_NAME=myapp"))
  assert_true(text.contains("BM2_INSTANCE_ID=3"))
  assert_true(text.contains("PORT=5000"))
}

///|
test "unix socket send/recv round-trip with peer uid" {
  let path = "/tmp/bm2-process-test-\{@process.get_pid()}.sock"
  let listen_fd = @process.socket_listen(path)
  let client = @process.socket_connect(path)
  let server = @process.accept(listen_fd)
  @process.send_msg(client, @utf8.encode("ping"))
  assert_eq(@utf8.decode(@process.recv_msg(server)), "ping")
  @process.send_msg(server, @utf8.encode("pong"))
  assert_eq(@utf8.decode(@process.recv_msg(client)), "pong")
  assert_eq(@process.peer_uid(server), @process.get_uid())
  assert_false(@process.poll_fd(client, 0))
  @process.close(client)
  @process.close(server)
  @process.close(listen_fd)
  @process.unlink(path)
}

///|
test "self_exe and read_small work on proc files" {
  let exe = @process.self_exe()
  assert_true(exe.has_prefix("/"))
  let cmdline = @utf8.decode_lossy(@process.read_small("/proc/self/cmdline"))
  assert_true(cmdline.length() > 0)
}
