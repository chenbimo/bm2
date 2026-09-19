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
    env_blob: @process.instance_env_blob("testapp", 2, 4001),
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
    env_blob: @process.instance_env_blob("t", 0, 1),
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
    env_blob: @process.instance_env_blob("t", 0, 1),
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
    env_blob: @process.instance_env_blob("t", 0, 1),
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
test "instance_env_blob contains reserved vars" {
  let text = @utf8.decode(@process.instance_env_blob("myapp", 3, 5000))
  assert_true(text.contains("BM2_APP_NAME=myapp"))
  assert_true(text.contains("BM2_INSTANCE_ID=3"))
  assert_true(text.contains("BM2_APP_PORT=5000"))
  assert_true(text.contains("BM2_APP_INSTANCE=3"))
  assert_true(text.contains("NODE_ENV=production"))
}

///|
test "instance_env_blob carries only whitelist and reserved vars" {
  let text = @utf8.decode(@process.instance_env_blob("myapp", 2, 5001))
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
    assert_true(allowed.contains(key))
  }
  // whitelist (PATH/HOME/TMPDIR, present in the test environment) + 5
  // reserved vars; at least 5 entries must exist.
  assert_true(seen >= 5)
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
test "a message larger than the old 64 KiB buffer still arrives intact" {
  let path = "/tmp/bm2-process-test-big-\{@process.get_pid()}.sock"
  let listen_fd = @process.socket_listen(path)
  let client = @process.socket_connect(path)
  let server = @process.accept(listen_fd)
  // 80 KiB: 25% past the fixed buffer the protocol used to have, and still
  // inside the kernel's default AF_UNIX socket buffer. The payload must
  // stay under that buffer because this test writes before it reads, and a
  // full buffer would only make the sender back off.
  let payload = "x".repeat(80 * 1024)
  @process.send_msg(client, @utf8.encode(payload))
  let received = @utf8.decode(@process.recv_msg(server))
  assert_eq(received.length(), payload.length())
  assert_eq(received, payload)
  @process.close(client)
  @process.close(server)
  @process.close(listen_fd)
  @process.unlink(path)
}

///|
test "wait_child_timeout kills a child that never exits" {
  let dir = "/tmp/bm2-process-test-timeout-\{@process.get_pid()}"
  @process.mkdir_p(dir)
  let script_path = dir + "/hang.sh"
  @fs.write_string_to_file(script_path, "while true; do sleep 1; done\n")
  let pid = @process.spawn({
    bun_path: "/bin/sh",
    script: script_path,
    cwd: dir,
    out_log: dir + "/o.log",
    err_log: dir + "/e.log",
    env_blob: @process.instance_env_blob("t", 0, 1),
  })
  assert_true(@process.pid_alive(pid))
  // 300 ms deadline: the child is SIGKILLed and reaped, so the caller gets
  // a signal instead of hanging forever on a stuck helper.
  assert_eq(
    @process.wait_child_timeout(pid, 300),
    Some((pid, @process.ChildExit::Signaled(@process.SIGKILL))),
  )
  assert_false(@process.pid_alive(pid))
  @process.unlink(script_path)
  @process.unlink(dir + "/o.log")
  @process.unlink(dir + "/e.log")
  @fs.remove_dir(dir)
}

///|
test "wait_child_timeout reports a normal exit" {
  let dir = "/tmp/bm2-process-test-timeout-ok-\{@process.get_pid()}"
  @process.mkdir_p(dir)
  let script_path = dir + "/quick.sh"
  @fs.write_string_to_file(script_path, "exit 7\n")
  let pid = @process.spawn({
    bun_path: "/bin/sh",
    script: script_path,
    cwd: dir,
    out_log: dir + "/o.log",
    err_log: dir + "/e.log",
    env_blob: @process.instance_env_blob("t", 0, 1),
  })
  assert_eq(
    @process.wait_child_timeout(pid, 5000),
    Some((pid, @process.ChildExit::Exited(7))),
  )
  @process.unlink(script_path)
  @process.unlink(dir + "/o.log")
  @process.unlink(dir + "/e.log")
  @fs.remove_dir(dir)
}

///|
test "sending to a peer that stops reading fails instead of blocking" {
  let path = "/tmp/bm2-process-test-stall-\{@process.get_pid()}.sock"
  let listen_fd = @process.socket_listen(path)
  let client = @process.socket_connect(path)
  let server = @process.accept(listen_fd)
  // Nobody ever reads `server`. Without a kernel send timeout the write below
  // would block forever once the socket buffer filled, which is exactly how a
  // dead CLI could wedge the single-threaded daemon. 8 MiB is far past any
  // default socket buffer, so the send must give up on its own deadline.
  let payload = Bytes::make(8 * 1024 * 1024, b'x')
  let started = @env.now()
  let raised = try {
    @process.send_msg(client, payload)
    false
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  let elapsed = @env.now() - started
  assert_true(raised)
  assert_true(elapsed < 30000UL)
  @process.close(client)
  @process.close(server)
  @process.close(listen_fd)
  @process.unlink(path)
}

///|
/// The receiver sizes its buffer from the announced length, so a peer that
/// lies about that length has to be refused by name instead of allocating.
test "an oversized announced message is refused by name" {
  let path = "/tmp/bm2-process-test-lie-\{@process.get_pid()}.sock"
  let listen_fd = @process.socket_listen(path)
  let client = @process.socket_connect(path)
  let server = @process.accept(listen_fd)
  // 5 MiB announced (0x00500000), no body at all: past MAX_MSG_BYTES (4 MiB).
  let header = Bytes::from_array([b'\x00', b'\x50', b'\x00', b'\x00'])
  @process.write_fd(client, header)
  let problem = try {
    ignore(@process.recv_msg(server))
    "accepted"
  } catch {
    e => e.to_string()
  } noraise {
    _ => "accepted"
  }
  assert_true(problem.contains("refused"))
  assert_true(problem.contains("5242880"))
  @process.close(client)
  @process.close(server)
  @process.close(listen_fd)
  @process.unlink(path)
}

///|
test "an empty message is a message" {
  let path = "/tmp/bm2-process-test-empty-\{@process.get_pid()}.sock"
  let listen_fd = @process.socket_listen(path)
  let client = @process.socket_connect(path)
  let server = @process.accept(listen_fd)
  @process.write_fd(
    client,
    Bytes::from_array([b'\x00', b'\x00', b'\x00', b'\x00']),
  )
  assert_eq(@process.recv_msg(server).length(), 0)
  @process.close(client)
  @process.close(server)
  @process.close(listen_fd)
  @process.unlink(path)
}

///|
/// A body that stops after the header must fail the read, not wait for bytes
/// that will never arrive.
test "a truncated message fails on the closed peer" {
  let path = "/tmp/bm2-process-test-trunc-\{@process.get_pid()}.sock"
  let listen_fd = @process.socket_listen(path)
  let client = @process.socket_connect(path)
  let server = @process.accept(listen_fd)
  // Announces 64 bytes (0x40), delivers 8, then hangs up.
  @process.write_fd(
    client,
    Bytes::from_array([b'\x00', b'\x00', b'\x00', b'\x40']),
  )
  @process.write_fd(client, @utf8.encode("12345678"))
  @process.close(client)
  let failed = try {
    ignore(@process.recv_msg(server))
    false
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(failed)
  @process.close(server)
  @process.close(listen_fd)
  @process.unlink(path)
}

///|
test "a silent peer is given up on at the read deadline" {
  let path = "/tmp/bm2-process-test-silent-\{@process.get_pid()}.sock"
  let listen_fd = @process.socket_listen(path)
  let client = @process.socket_connect(path)
  let server = @process.accept(listen_fd)
  // Connected but never sends a byte: the read deadline (5 s) has to win.
  let started = @env.now()
  let failed = try {
    ignore(@process.recv_msg(server))
    false
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  let elapsed = @env.now() - started
  assert_true(failed)
  assert_true(elapsed >= 4000UL)
  assert_true(elapsed < 30000UL)
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

///|
/// Log rotation runs over every registered instance, including ones that have
/// not written anything yet, so a missing file has to be a no-op rather than an
/// error that would be logged on every sweep.
test "rotating or truncating a missing log is a no-op" {
  let dir = "/tmp/bm2-process-test-missing-\{@process.get_pid()}"
  @process.mkdir_p(dir)
  @process.rotate(dir + "/none.log")
  @process.copytruncate(dir + "/none.log")
  assert_false(@fs.path_exists(dir + "/none.log"))
  assert_false(@fs.path_exists(dir + "/none.log.1"))
  @fs.remove_dir(dir)
}

///|
test "chmod reports a missing path" {
  let failed = try {
    @process.chmod("/tmp/bm2-no-such-file-\{@process.get_pid()}", 0o600)
    false
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(failed)
}

///|
/// read_small backs the /proc reads (environ, status, cmdline), which is why it
/// stops at the cap instead of growing a buffer to fit whatever it reads.
test "read_small stops at the cap" {
  let dir = "/tmp/bm2-process-test-cap-\{@process.get_pid()}"
  @process.mkdir_p(dir)
  let path = dir + "/big.txt"
  @fs.write_string_to_file(path, "x".repeat(100))
  assert_eq(@process.read_small(path, cap=10).length(), 10)
  assert_eq(@process.read_small(path, cap=1000).length(), 100)
  @process.unlink(path)
  @fs.remove_dir(dir)
}

///|
test "rotate keeps at most ten generations" {
  let dir = "/tmp/bm2-process-test-rotate"
  @process.mkdir_p(dir)
  let path = dir + "/app.log"
  for i in 0..<12 {
    @fs.write_string_to_file(path, "gen\{i}")
    @process.rotate(path)
  }
  assert_false(@fs.path_exists(path))
  assert_true(@fs.path_exists(path + ".1"))
  assert_true(@fs.path_exists(path + ".10"))
  assert_false(@fs.path_exists(path + ".11"))
  // Eleven generations were written; the oldest (gen1) fell off at the
  // twelfth rotation, so .10 holds gen2 and .1 holds gen11.
  assert_eq(@fs.read_file_to_string(path + ".10"), "gen2")
  assert_eq(@fs.read_file_to_string(path + ".1"), "gen11")
}

///|
test "copytruncate copies and truncates in place" {
  let dir = "/tmp/bm2-process-test-copytruncate"
  @process.mkdir_p(dir)
  let path = dir + "/app.log"
  @fs.write_string_to_file(path, "content")
  @process.copytruncate(path)
  assert_eq(@fs.read_file_to_string(path), "")
  assert_eq(@fs.read_file_to_string(path + ".1"), "content")
}

///|
test "file_size reports bytes and missing files" {
  let dir = "/tmp/bm2-process-test-size"
  @process.mkdir_p(dir)
  let path = dir + "/app.log"
  @fs.write_string_to_file(path, "12345")
  assert_eq(@process.file_size(path), Some(5L))
  assert_eq(@process.file_size(path + "/none"), None)
}
