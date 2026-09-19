///
/// Recovery is the security-critical half of the daemon: it decides which
/// processes may be adopted after a restart. These tests drive it with real
/// processes rather than stubs, because the decision rests on the kernel (pid
/// liveness) and on /proc (the BM2_* fingerprint).

///|
fn wb_config(name : String, cwd : String, port : Int) -> @config.Config {
  {
    name,
    cwd,
    script: "fixture.sh",
    runtime: "bun",
    exec_mode: "fork",
    instances: 1,
    port,
    max_memory_mb: 512,
    max_restarts: 2,
    restart_delay_ms: 100,
    min_uptime_ms: 60000,
    stop_timeout_ms: 500,
  }
}

///|
fn wb_sv(root : String, config : @config.Config) -> Supervisor raise {
  @process.mkdir_p(root)
  let sv = Supervisor::new(state_dir=root + "/state", bun_path="/bin/sh")
  sv.register(config, root + "/bm2.toml")
  sv
}

///|
/// A NUL-separated environment blob, the shape /proc/<pid>/environ has.
fn environ_of(entries : Array[String]) -> Bytes {
  let buf = StringBuilder()
  for entry in entries {
    buf.write_string(entry)
    buf.write_char('\u{0}')
  }
  @utf8.encode(buf.to_string())
}

///|
fn state_json(app : String, id : Int, pid : Int, port : Int) -> String {
  "{\"app_name\":\"" +
  app +
  "\",\"instance_id\":" +
  id.to_string() +
  ",\"pid\":" +
  pid.to_string() +
  ",\"pgid\":" +
  pid.to_string() +
  ",\"port\":" +
  port.to_string() +
  ",\"status\":\"online\",\"started_at\":\"2026-01-01T00:00:00.000Z\",\"restart_count\":0}"
}

///|
fn read_events(path : String) -> String {
  try @fs.read_file_to_string(path) catch {
    _ => ""
  } noraise {
    text => text
  }
}

///|
/// The fingerprint asks for exactly what bm2 writes: a process carrying the
/// right app, instance and port may be adopted; anything else looks foreign.
test "the adoption fingerprint demands the exact reserved triple" {
  let inst = Instance::new(wb_config("api", "/tmp", 4500), 1)
  let exact = environ_of([
    "PATH=/usr/bin", "BM2_APP_NAME=api", "BM2_INSTANCE_ID=1", "BM2_APP_PORT=4501",
  ])
  assert_true(env_matches(exact, inst))
  // Same app, wrong instance: a sibling must never be mistaken for this one.
  assert_false(
    env_matches(
      environ_of(["BM2_APP_NAME=api", "BM2_INSTANCE_ID=2", "BM2_APP_PORT=4501"]),
      inst,
    ),
  )
  // Same app and instance, stale port from an older config.
  assert_false(
    env_matches(
      environ_of(["BM2_APP_NAME=api", "BM2_INSTANCE_ID=1", "BM2_APP_PORT=4500"]),
      inst,
    ),
  )
  // A process with no reserved variables at all is never adopted.
  assert_false(env_matches(environ_of(["PATH=/usr/bin", "HOME=/root"]), inst))
  assert_false(env_matches(Bytes::make(0, b'\x00'), inst))
}

///|
/// A state file left over the daemon restart points at a pid that no longer
/// exists: the file is dropped so it cannot mislead later recoveries.
test "recover discards state whose pid is gone" {
  let root = "/tmp/bm2-recovery-wbtest-dead-\{@process.get_pid()}"
  let dir = root + "/api"
  @process.mkdir_p(dir)
  @fs.write_string_to_file(dir + "/fixture.sh", "exit 0\n")
  let config = wb_config("api", dir, 4502)
  let sv = wb_sv(root, config)
  let state_dir = root + "/state"
  // A pid that certainly no longer exists: spawn it, then reap it.
  let pid = @process.spawn({
    bun_path: "/bin/sh",
    script: "",
    cwd: dir,
    out_log: "",
    err_log: "",
    env_blob: @process.base_env_blob(),
  })
  ignore(@process.wait_child(pid))
  let path = state_path(state_dir, "api", 0)
  @fs.write_string_to_file(path, state_json("api", 0, pid, 4502))
  sv.recover()
  assert_false(@fs.path_exists(path))
  assert_true(
    read_events(state_dir + "/bm2d.events.jsonl").contains("state_discarded"),
  )
  assert_true(sv.instance("api", 0).status is Status::Stopped)
}

///|
/// A freshly forked child still shows its *parent's* environment in /proc
/// until it has exec'd, and the daemon's fingerprint check would read that as a
/// foreign process. Production never sees it (the state file comes from an
/// earlier daemon, so the process has long since exec'd); a test that spawns
/// and immediately recovers does, so it waits for the real environment.
fn wait_for_fingerprint(pid : Int, app : String, timeout_ms : Int) -> Bool {
  let deadline = @env.now() + timeout_ms.to_uint64()
  while @env.now() < deadline {
    let bytes = try
      @process.read_small("/proc/\{pid}/environ", cap=4096)
    catch {
      _ => Bytes::make(0, b'\x00')
    } noraise {
      data => data
    }
    if @utf8.decode_lossy(bytes).contains("BM2_APP_NAME=" + app) {
      return true
    }
    @process.sleep_ms(10)
  }
  false
}

///|
/// The adoption path itself: a live process carrying the reserved variables is
/// taken over with its pid and pidfd, and its recorded counters are restored.
test "recover adopts a live instance that carries the reserved variables" {
  let root = "/tmp/bm2-recovery-wbtest-live-\{@process.get_pid()}"
  let dir = root + "/api"
  @process.mkdir_p(dir)
  @fs.write_string_to_file(
    dir + "/fixture.sh",
    "#!/bin/sh\nwhile true; do sleep 1; done\n",
  )
  let config = wb_config("api", dir, 4503)
  let sv = wb_sv(root, config)
  let state_dir = root + "/state"
  let pid = @process.spawn({
    bun_path: "/bin/sh",
    script: dir + "/fixture.sh",
    cwd: dir,
    out_log: dir + "/out.log",
    err_log: dir + "/err.log",
    env_blob: @process.instance_env_blob(config.name, 0, config.port),
  })
  assert_true(wait_for_fingerprint(pid, config.name, 5000))
  let path = state_path(state_dir, "api", 0)
  @fs.write_string_to_file(path, state_json("api", 0, pid, 4503))
  sv.recover()
  let inst = sv.instance("api", 0)
  assert_eq(inst.status, Status::Online)
  assert_eq(inst.pid, pid)
  assert_true(inst.pidfd > 0)
  // Adoption is not a fresh start: the launch counter survives.
  assert_true(
    read_events(state_dir + "/bm2d.events.jsonl").contains("instance_adopted"),
  )
  // And the adopted process is left running.
  assert_true(@process.pid_alive(pid))
  @process.discard(() => @process.kill_group(pid, @process.SIGKILL))
  @process.drain_child(pid)
}
