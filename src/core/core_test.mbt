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
  port : Int,
  max_memory_mb? : Int = 512,
  max_restarts? : Int = 2,
  restart_delay_ms? : Int = 150,
  min_uptime_ms? : Int = 60000,
  stop_timeout_ms? : Int = 500,
  script? : String = "fixture.sh",
  instances? : Int = 1,
) -> @config.Config {
  {
    name,
    cwd,
    script,
    runtime: "bun",
    instances,
    port,
    max_memory_mb,
    max_restarts,
    restart_delay_ms,
    min_uptime_ms,
    stop_timeout_ms,
  }
}

///|
fn make_sv(root : String, config : @config.Config) -> @core.Supervisor raise {
  let sv = @core.Supervisor::new(
    state_dir=root + "/state",
    bun_path="/bin/sh",
    memory_interval_ms=100,
  )
  // Persist a real config file so load_projects can reload the project.
  @process.mkdir_p(root)
  @fs.write_string_to_file(
    root + "/bm2.toml",
    "name = \"\{config.name}\"\ncwd = \"\{config.cwd}\"\nscript = \"\{config.script}\"\ninstances = \{config.instances}\nport = \{config.port}\n",
  )
  sv.register(config, root + "/bm2.toml")
  sv
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
  let sv = make_sv(root, app_config("api", dir, 4100))
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
  let sv = make_sv(
    root,
    app_config("api", dir, 4110, min_uptime_ms=0, restart_delay_ms=100),
  )
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
  let sv = make_sv(root, app_config("api", dir, 4120, min_uptime_ms=300))
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
  let sv = make_sv(
    root,
    app_config("api", dir, 4130, max_memory_mb=0, max_restarts=1),
  )
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
test "kill marks manual, never restarts, and unregisters the project" {
  let root = "/tmp/bm2-core-test-kill"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, app_config("api", dir, 4140))
  sv.start_app("api")
  drive(sv, 300)
  assert_eq(sv.app_names().length(), 1)
  sv.kill_app("api")
  drive(sv, 800)
  // The project leaves the registry once its instance stopped.
  assert_eq(sv.app_names().length(), 0)
  assert_false(@fs.path_exists(root + "/state/api/project.json"))
  // More time must not resurrect the killed app.
  drive(sv, 800)
  assert_eq(sv.app_names().length(), 0)
}

///|
test "state file reflects online then stopped" {
  let root = "/tmp/bm2-core-test-state"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, app_config("api", dir, 4150))
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
  assert_eq(online.times, Some(1))
  stop_all(sv, "api")
  let stopped = @core.load_state(path)
  assert_eq(stopped.status, "stopped")
  assert_eq(stopped.pid, 0)
}

///|
test "start count increments with every launch" {
  let root = "/tmp/bm2-core-test-startcount"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, app_config("api", dir, 4340))
  sv.start_app("api")
  drive(sv, 300)
  assert_eq(sv.instance("api", 0).times, 1)
  // A full restart launches the instance again and keeps counting.
  sv.start_app("api")
  drive(sv, 1200)
  assert_eq(sv.instance("api", 0).times, 2)
  stop_all(sv, "api")
}

///|
test "start conflicts while full restart is pending" {
  let root = "/tmp/bm2-core-test-conflict"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, app_config("api", dir, 4160, stop_timeout_ms=3000))
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
test "kill during pending restart does not resurrect the app" {
  let root = "/tmp/bm2-core-test-kill-pending"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, app_config("api", dir, 4170, stop_timeout_ms=1000))
  sv.start_app("api")
  drive(sv, 300)
  // Trigger a full restart: the old instance is stopping and the fresh
  // spawn is still pending.
  sv.start_app("api")
  // Kill while the restart is pending; pending_restart must be cleared.
  sv.kill_app("api")
  drive(sv, 1500)
  // The project is gone entirely: a kill during a pending restart must
  // never be resurrected by check_pending.
  assert_eq(sv.app_names().length(), 0)
  assert_false(@fs.path_exists(root + "/state/api/project.json"))
  // More time must not bring it back.
  drive(sv, 1000)
  assert_eq(sv.app_names().length(), 0)
}

///|
test "kill clears a stale pid so removal never blocks" {
  let root = "/tmp/bm2-core-test-stale-pid"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, app_config("api", dir, 4330))
  sv.start_app("api")
  drive(sv, 300)
  let inst = sv.instance("api", 0)
  // Kill the process behind the instance without letting the supervisor
  // reap it first: the pidfd still exists, so alive() reads dead.
  @process.kill_group(inst.pid, @process.SIGKILL)
  sv.kill_app("api")
  drive(sv, 600)
  assert_eq(sv.app_names().length(), 0)
  assert_false(@fs.path_exists(root + "/state/api/project.json"))
}

///|
test "register writes the project registration file" {
  let root = "/tmp/bm2-core-test-register"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = @core.Supervisor::new(
    state_dir=root + "/state",
    bun_path="/bin/sh",
    memory_interval_ms=100,
  )
  sv.register(app_config("api", dir, 4180), "/srv/blog/bm2.toml")
  let info = @core.load_project(root + "/state/api/project.json")
  assert_eq(info.config_path, "/srv/blog/bm2.toml")
  assert_eq(sv.app_names(), ["api"])
}

///|
test "register rejects overlapping port ranges across projects" {
  let root = "/tmp/bm2-core-test-portconflict"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, app_config("api", dir, 4200))
  let rejected = try
    sv.register(app_config("other", dir, 4200), root + "/other.toml")
  catch {
    e => e.to_string()
  } noraise {
    _ => "no error"
  }
  assert_true(rejected.contains("port conflict"))
  assert_eq(sv.app_names(), ["api"])
  // A non-overlapping registration succeeds.
  sv.register(app_config("other", dir, 4300), root + "/other.toml")
  assert_eq(sv.app_names().length(), 2)
  stop_all(sv, "api")
  stop_all(sv, "other")
}

///|
test "register accepts structural change and restart applies it" {
  let root = "/tmp/bm2-core-test-reload-struct"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, app_config("api", dir, 4190))
  sv.start_app("api")
  drive(sv, 300)
  let before = sv.instance("api", 0).pid
  assert_true(before > 0)
  // A structural change (script) is accepted while instances are alive...
  let err = try
    sv.register(
      app_config("api", dir, 4190, script="other.sh"),
      root + "/bm2.toml",
    )
  catch {
    e => e.to_string()
  } noraise {
    _ => "ok"
  }
  assert_eq(err, "ok")
  assert_eq(sv.app_config("api").script, "other.sh")
  // ...and the full restart spawns from the new config.
  sv.start_app("api")
  drive(sv, 1000)
  assert_false(sv.instance("api", 0).alive())
  stop_all(sv, "api")
}

///|
test "restart rebuilds instances from the updated config" {
  let root = "/tmp/bm2-core-test-rebuild"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, app_config("api", dir, 4290))
  sv.start_app("api")
  drive(sv, 300)
  // Re-register with more instances; the array is rebuilt on restart.
  sv.register(app_config("api", dir, 4290, instances=2), root + "/bm2.toml")
  sv.start_app("api")
  drive(sv, 1500)
  assert_eq(sv.app_instances("api").length(), 2)
  assert_true(sv.instance("api", 1).port > 0)
  stop_all(sv, "api")
}

///|
test "load_projects restores registered projects" {
  let root = "/tmp/bm2-core-test-loadprojects"
  let dir = make_app_dir(root, "api", "sleep 30\n")
  let sv = make_sv(root, app_config("api", dir, 4220))
  sv.start_app("api")
  drive(sv, 300)
  let pid = sv.instance("api", 0).pid
  assert_true(pid > 0)
  // A fresh supervisor (like a restarted daemon) restores the project.
  let fresh = @core.Supervisor::new(
    state_dir=root + "/state",
    bun_path="/bin/sh",
    memory_interval_ms=100,
  )
  fresh.load_projects()
  fresh.recover()
  assert_eq(fresh.app_names(), ["api"])
  let inst = fresh.instance("api", 0)
  assert_eq(inst.pid, pid)
  assert_eq(inst.status, @core.Status::Online)
  fresh.kill_app("api")
  drive(fresh, 1200)
}

///|
test "resolve_state_dir uses fixed home directory" {
  match @env.get_env_var("HOME") {
    Some(home) if !home.is_empty() =>
      assert_eq(@core.resolve_state_dir(), home + "/.bm2")
    _ =>
      assert_eq(
        @core.resolve_state_dir(),
        "/tmp/bm2-" + @process.get_uid().to_string(),
      )
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

///|
test "protocol request and response round-trip" {
  let req : @core.Request = {
    command: "start",
    app: Some("api"),
    config_path: Some("/srv/blog/bm2.toml"),
  }
  assert_eq(@core.decode_request(@core.encode_request(req)), req)
  let bare : @core.Request = { command: "kill", app: None, config_path: None }
  assert_eq(@core.decode_request(@core.encode_request(bare)), bare)
  let resp = @core.Response::ok("started", [])
  assert_eq(@core.decode_response(@core.encode_response(resp)), resp)
  let err = @core.Response::error("boom")
  assert_eq(@core.decode_response(@core.encode_response(err)), err)
}

///|
test "protocol rejects garbage payloads" {
  let req_ok = try @core.decode_request(@utf8.encode("not json")) catch {
    _ => false
  } noraise {
    _ => true
  }
  assert_false(req_ok)
  let resp_ok = try @core.decode_response(@utf8.encode("{}")) catch {
    _ => false
  } noraise {
    _ => true
  }
  assert_false(resp_ok)
}
