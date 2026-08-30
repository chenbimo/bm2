///|
fn wb_setup(root : String, port : Int) -> Supervisor raise {
  @process.mkdir_p(root)
  let config : @config.Config = {
    name: "wbapp",
    cwd: root,
    script: "x.sh",
    runtime: "bun",
    exec_mode: "fork",
    instances: 1,
    port,
    max_memory_mb: 512,
    max_restarts: 2,
    restart_delay_ms: 100,
    min_uptime_ms: 60000,
    stop_timeout_ms: 200,
  }
  let sv = Supervisor::new(state_dir=root + "/state", bun_path="/bin/sh")
  sv.register(config, root + "/bm2.toml")
  sv
}

///|
test "spawn failures back off and exhaust the budget into errored" {
  let root = "/tmp/bm2-wbtest-spawn-\{@process.get_pid()}"
  let sv = wb_setup(root, 4451)
  let inst = sv.instance("wbapp", 0)
  sv.mark_spawn_failed(inst)
  assert_true(inst.status is Restarting)
  assert_eq(inst.restart_count, 1)
  let first_wait = inst.restart_at_ms - now_ms()
  assert_true(first_wait > 0UL)
  sv.mark_spawn_failed(inst)
  assert_eq(inst.restart_count, 2)
  // The backoff grows with the retry count: delay * restart_count.
  assert_true(inst.restart_at_ms - now_ms() >= first_wait)
  sv.mark_spawn_failed(inst)
  assert_true(inst.status is Errored)
  assert_eq(inst.restart_at_ms, 0UL)
  let crash = @fs.read_file_to_string(
    root + "/state/wbapp/logs/wbapp-0.crash.log",
  )
  assert_true(crash.contains("reason=spawn_failed"))
  assert_true(crash.contains("restartCount=3"))
}

///|
test "rotate_logs rotates oversized app logs with copytruncate" {
  let root = "/tmp/bm2-wbtest-rotate-\{@process.get_pid()}"
  let sv = wb_setup(root, 4452)
  let base = root + "/state/wbapp/logs/wbapp-0"
  // 11 MB exceeds the 10 MB rotation threshold.
  @process.append_file(base + ".out.log", Bytes::make(11 * 1024 * 1024, b'x'))
  @process.append_file(base + ".crash.log", @utf8.encode("small\n"))
  sv.rotate_logs()
  match @process.file_size(base + ".out.log.1") {
    Some(size) => assert_true(size > 10L * 1024L * 1024L)
    None => fail("expected rotated generation .out.log.1")
  }
  assert_eq(@process.file_size(base + ".out.log"), Some(0L))
  assert_false(@fs.path_exists(base + ".crash.log.1"))
}

///|
test "wait_settled gives up after the deadline" {
  let root = "/tmp/bm2-wbtest-settle-\{@process.get_pid()}"
  let sv = wb_setup(root, 4453)
  let inst = sv.instance("wbapp", 0)
  inst.status = Restarting
  inst.pid = 0
  inst.restart_at_ms = now_ms() + 60000UL
  assert_false(sv.wait_settled(["wbapp"]))
}
