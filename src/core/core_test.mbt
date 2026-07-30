///|
fn make_app_dir(root : String, name : String, script : String) -> String raise {
  let dir = root + "/" + name
  @process.mkdir_p(dir)
  @fs.write_string_to_file(dir + "/fixture.sh", script)
  dir
}

///|
fn app_config(
  name : String,
  cwd : String,
  base_port : Int,
  max_memory_mb? : Int = 512,
  max_restarts? : Int = 2,
  restart_delay_ms? : Int = 150,
  min_uptime_ms? : Int = 60000,
  stop_timeout_ms? : Int = 500,
) -> @config.AppConfig {
  {
    name,
    cwd,
    script: "fixture.sh",
    instances: 1,
    base_port,
    max_memory_mb,
    max_restarts,
    restart_delay_ms,
    min_uptime_ms,
    stop_timeout_ms,
  }
}

///|
fn make_sv(
  root : String,
  apps : Array[@config.AppConfig],
) -> @core.Supervisor raise {
  let config = @config.Config::{ apps, }
  @core.Supervisor::new(
    config,
    state_dir=root + "/state",
    bun_path="/bin/sh",
    memory_interval_ms=100,
  )
}

///|
fn drive(sv : @core.Supervisor, ms : Int) -> Unit {
  let end = @core.now_ms() + ms.to_uint64()
  while @core.now_ms() < end {
    sv.tick()
    @process.sleep_ms(20)
  }
}

///|
fn stop_all(sv : @core.Supervisor, app : String) -> Unit {
  try sv.stop_app(app) catch {
    _ => ()
  } noraise {
    _ => ()
  }
  drive(sv, 1200)
}

///|
test "crash loop restarts then reaches errored" {
  let root = "/tmp/bm2-core-test-errored"
  let dir = make_app_dir(root, "api", "exit 1\n")
  let sv = make_sv(root, [app_config("api", dir, 4100)])
  sv.start_app("api")
  let inst = sv.instance("api", 0)
  let deadline = @core.now_ms() + 5000UL
  while @core.now_ms() < deadline && !(inst.status is @core.Status::Errored) {
    sv.tick()
    @process.sleep_ms(20)
  }
  assert_eq(inst.status, @core.Status::Errored)
  assert_eq(inst.restart_count, 3)
  assert_eq(inst.last_exit_code, Some(1))
  let crash = @fs.read_file_to_string(root + "/state/api/logs/api-0.crash.log")
  assert_true(crash.contains("reason=exit_code"))
  assert_true(crash.contains("restartCount=3"))
}

///|
test "clean exit after min uptime restarts without count" {
  let root = "/tmp/bm2-core-test-clean"
  let dir = make_app_dir(root, "api", "exit 0\n")
  let sv = make_sv(root, [
    app_config("api", dir, 4110, min_uptime_ms=0, restart_delay_ms=100),
  ])
  sv.start_app("api")
  drive(sv, 800)
  let inst = sv.instance("api", 0)
  assert_eq(inst.restart_count, 0)
  assert_true(inst.status is (@core.Status::Online | @core.Status::Restarting))
  stop_all(sv, "api")
  assert_eq(sv.instance("api", 0).status, @core.Status::Stopped)
}

///|
test "stable run over min uptime resets restart count" {
  let root = "/tmp/bm2-core-test-reset"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, [app_config("api", dir, 4120, min_uptime_ms=300)])
  sv.start_app("api")
  drive(sv, 500)
  let inst = sv.instance("api", 0)
  assert_eq(inst.status, @core.Status::Online)
  inst.restart_count = 2
  sv.tick()
  assert_eq(inst.restart_count, 0)
  stop_all(sv, "api")
  assert_eq(sv.instance("api", 0).status, @core.Status::Stopped)
}

///|
test "memory limit terminates instance and counts restarts" {
  let root = "/tmp/bm2-core-test-memory"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, [
    app_config("api", dir, 4130, max_memory_mb=0, max_restarts=1),
  ])
  sv.start_app("api")
  drive(sv, 2500)
  let inst = sv.instance("api", 0)
  assert_eq(inst.status, @core.Status::Errored)
  assert_eq(inst.restart_count, 2)
  let crash = @fs.read_file_to_string(root + "/state/api/logs/api-0.crash.log")
  assert_true(crash.contains("reason=memory_limit"))
  assert_true(crash.contains("rssMb="))
}

///|
test "kill marks manual and never restarts" {
  let root = "/tmp/bm2-core-test-kill"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, [app_config("api", dir, 4140)])
  sv.start_app("api")
  drive(sv, 300)
  sv.kill_app("api")
  drive(sv, 800)
  let inst = sv.instance("api", 0)
  assert_eq(inst.status, @core.Status::Stopped)
  assert_eq(inst.last_reason, Some("manual_kill"))
  assert_eq(inst.restart_count, 0)
  assert_false(inst.alive())
}

///|
test "state file reflects online then stopped" {
  let root = "/tmp/bm2-core-test-state"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, [app_config("api", dir, 4150)])
  sv.start_app("api")
  drive(sv, 300)
  let path = root + "/state/api/api-0.json"
  let inst = sv.instance("api", 0)
  let online = @core.load_state(path)
  assert_eq(online.pid, inst.pid)
  assert_eq(online.pgid, inst.pid)
  assert_eq(online.status, "online")
  assert_eq(online.port, 4150)
  assert_eq(online.app_name, "api")
  stop_all(sv, "api")
  let stopped = @core.load_state(path)
  assert_eq(stopped.status, "stopped")
  assert_eq(stopped.pid, 0)
}

///|
test "start conflicts while full restart is pending" {
  let root = "/tmp/bm2-core-test-conflict"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, [app_config("api", dir, 4160, stop_timeout_ms=3000)])
  sv.start_app("api")
  drive(sv, 300)
  sv.start_app("api")
  try sv.start_app("api") catch {
    _ => ()
  } noraise {
    _ => fail("expected conflict with pending start")
  }
  sv.kill_app("api")
  drive(sv, 1000)
  stop_all(sv, "api")
}

///|
test "resolve_state_dir uses fixed home directory" {
  match @env.get_env_var("HOME") {
    Some(home) => assert_eq(@core.resolve_state_dir(), home + "/.bm2")
    None => assert_eq(@core.resolve_state_dir(), ".bm2")
  }
}

///|
test "iso8601 formats epoch and current time" {
  assert_eq(@core.iso8601(0UL), "1970-01-01T00:00:00.000Z")
  let now = @core.iso8601(@core.now_ms())
  assert_eq(now.length(), 24)
  assert_true(now.has_prefix("20"))
  assert_true(now.has_suffix("Z"))
}
