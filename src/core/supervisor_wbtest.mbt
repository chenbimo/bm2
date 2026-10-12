///|
fn wb_setup(root : String, port : Int32) -> Supervisor raise {
  @fsx.mkdir_p(root)
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
    notify: @config.NotifyConfig::disabled(),
    env: [],
  }
  let sv = Supervisor::new(state_dir=root + "/state", bun_path="/bin/sh")
  sv.register(config, root + "/bm2.toml")
  sv
}

///|
/// A project that is unregistered leaves nothing behind: its stats window,
/// restart-storm history and start probes go with it, and the notify task is
/// told to drop its own copy.
test "unregistering a project drops its in-memory state" {
  let root = "/tmp/bm2-wbtest-forget-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4453)
  sv.stats_window["wbapp"] = { peak_kb: 1024, restarts: 2, }
  sv.storm_hits["wbapp"] = [1UL, 2UL]
  sv.start_probe_done["wbapp/0"] = 42UL
  sv.forget_app("wbapp")
  assert_true(sv.stats_window.get("wbapp") is None)
  assert_true(sv.storm_hits.get("wbapp") is None)
  assert_true(sv.start_probe_done.get("wbapp/0") is None)
  // The delivery side is reached by message, never by sharing state: the queue
  // must carry the Forget for this project.
  let notice = try sv.outbound().try_get() catch {
    _ => None
  } noraise {
    item => item
  }
  match notice {
    Some(Forget(owner)) => assert_eq(owner, "wbapp")
    _ => fail("expected a Forget message for the removed project")
  }
}

///|
/// A config that drops instances must not leave the dropped ones' state files
/// behind: a later recovery would read them.
test "a shrunk instance set loses its stale state files" {
  let root = "/tmp/bm2-wbtest-shrink-\{@proc.get_pid()}"
  @fsx.mkdir_p(root)
  let two = { ..wb_config("wbapp", root, 4455), instances: 2, }
  let sv = wb_sv(root, two)
  // A state file as if instance 1 had been running under a previous daemon.
  save_state(sv.state_dir, sv.instance("wbapp", 1))
  let path = state_path(sv.state_dir, "wbapp", 1)
  assert_true(@fs.path_exists(path))
  // The config shrinks to one instance and the restart rebuilds the set.
  sv.register({ ..two, instances: 1, }, root + "/bm2.toml")
  try sv.spawn_fresh("wbapp") catch {
    _ => ()
  } noraise {
    _ => ()
  }
  assert_false(@fs.path_exists(path))
}

///|
/// The runtime probe blocks this daemon's single thread, so its verdict is kept
/// per daemon. A fabricated runtime name proves the cache short-circuits the
/// probe: probing it would fail to spawn, with a different message.
test "a cached runtime verdict is reused instead of probing" {
  let root = "/tmp/bm2-wbtest-runtime-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4457)
  sv.runtime_checked["ghost-runtime"] = Some("ghost-runtime is too old")
  let message = try {
    sv.check_runtime("ghost-runtime")
    ""
  } catch {
    e => e.to_string()
  } noraise {
    value => value
  }
  assert_true(message.contains("ghost-runtime is too old"))
  // A cached pass is reused as well, so a restart never probes again.
  sv.runtime_checked["ghost-runtime"] = None
  let probed = try {
    sv.check_runtime("ghost-runtime")
    false
  } catch {
    _ => true
  } noraise {
    value => value
  }
  assert_false(probed)
}

///|
test "spawn failures back off and exhaust the budget into errored" {
  let root = "/tmp/bm2-wbtest-spawn-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4451)
  let inst = sv.instance("wbapp", 0)
  sv.mark_spawn_failed(inst)
  assert_true(inst.status is Restarting)
  assert_eq(inst.restart_count, 1)
  let first_wait = inst.restart_at_ms - @proc.monotonic_ms()
  assert_true(first_wait > 0UL)
  sv.mark_spawn_failed(inst)
  assert_eq(inst.restart_count, 2)
  // The backoff grows with the retry count: delay * restart_count.
  assert_true(inst.restart_at_ms - @proc.monotonic_ms() >= first_wait)
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
  let root = "/tmp/bm2-wbtest-rotate-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4452)
  let base = root + "/state/wbapp/logs/wbapp-0"
  // 11 MB exceeds the 10 MB rotation threshold.
  @fsx.append_file(base + ".out.log", Bytes::make(11 * 1024 * 1024, b'x'))
  @fsx.append_file(base + ".crash.log", @utf8.encode("small\n"))
  sv.rotate_logs()
  match @fsx.file_size(base + ".out.log.1") {
    Some(size) => assert_true(size > 10L * 1024L * 1024L)
    None => fail("expected rotated generation .out.log.1")
  }
  assert_eq(@fsx.file_size(base + ".out.log"), Some(0L))
  assert_false(@fs.path_exists(base + ".crash.log.1"))
}

///|
async test "wait_settled gives up after the deadline" {
  let root = "/tmp/bm2-wbtest-settle-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4453)
  let inst = sv.instance("wbapp", 0)
  inst.status = Restarting
  inst.pid = 0
  inst.restart_at_ms = @proc.monotonic_ms() + 60000UL
  assert_false(sv.wait_settled(["wbapp"]))
}

///|
/// OOM attribution: SIGKILL with the last sample near the limit; anything
/// else (other signals, low-RSS kills, missing samples) stays a plain crash.
test "oom kill attribution needs signal 9 and a near-limit sample" {
  // 100 MB limit = 102400 kB; the 90% boundary is 92160 kB.
  // Signal 9 at 95% of the limit.
  assert_eq(is_oom_kill(Some(9), 97280, 100), true)
  // Exactly at the 90% boundary counts.
  assert_eq(is_oom_kill(Some(9), 92160, 100), true)
  // Below the boundary is a plain crash.
  assert_eq(is_oom_kill(Some(9), 90000, 100), false)
  // Other signals and unknown exits never attribute to the OOM killer.
  assert_eq(is_oom_kill(Some(15), 99000, 100), false)
  assert_eq(is_oom_kill(None, 99000, 100), false)
  // An instance never sampled has last_rss_kb 0.
  assert_eq(is_oom_kill(Some(9), 0, 100), false)
}

///|
/// Storm counting only looks inside the window and prunes what fell out.
test "storm window counts recent restarts and prunes old ones" {
  let hits : Array[UInt64] = [1000UL, 2000UL, 9000UL]
  // Window 5s at t=10000: only t=9000 is inside; the rest is pruned.
  assert_eq(storm_hit_count(hits, 10000UL, 5000UL), 1)
  assert_eq(hits.length(), 1)
  // A later pass over the pruned array keeps the count stable while the
  // entry is still inside the window.
  assert_eq(storm_hit_count(hits, 12000UL, 5000UL), 1)
}

///|
/// The restart array must stay bounded by the window whether or not storm
/// alerts are configured: pruning happens on the write, not in the alert path.
test "recorded storm hits are pruned on write" {
  let root = "/tmp/bm2-wbtest-storm-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4454)
  for i in 0..<200 {
    sv.record_storm_hit("wbapp", 1000UL + i.to_uint64())
  }
  let hits = match sv.storm_hits.get("wbapp") {
    Some(hits) => hits
    None => []
  }
  assert_eq(hits.length(), 200)
  // One restart further than the window's width past the last hit (1199 ms)
  // drops every entry that fell out of it.
  sv.record_storm_hit("wbapp", 1199UL + 600001UL)
  assert_eq(hits.length(), 1)
}

///|
/// Notification copy renders per project language; unknown falls back to en.
test "notification copy renders in the configured language" {
  let (en_title, en_body) = render_msg("en", ProjectStarted(4, "cluster", 3020))
  assert_eq(en_title, "Project started")
  assert_eq(
    en_body, "Started 4 instance(s) as configured (cluster mode, port 3020).",
  )
  let (zh_title, zh_body) = render_msg("zh", ProjectStarted(4, "cluster", 3020))
  assert_eq(zh_title, "项目已启动")
  assert_eq(
    zh_body, "已按配置启动 4 个实例（cluster 模式，端口 3020）。",
  )
  // Unknown language falls back to English.
  let (fb_title, _) = render_msg("fr", ProjectStopped("api"))
  assert_eq(fb_title, "Project stopped")
  // Crash cause sentence carries the port-conflict note in both languages.
  assert_eq(
    crash_cause("zh", "signal", "（signal=SIGKILL）", true),
    "原因：signal（signal=SIGKILL）；端口已被其他进程独占",
  )
  assert_eq(
    crash_cause("en", "signal", " (signal=SIGKILL)", true),
    "Cause: signal (signal=SIGKILL); the port is held exclusively by another process",
  )
  // Report titles render in both languages.
  let (h, _) = render_msg("zh", HealthReport("api", false))
  assert_eq(h, "bm2 健康报告 · api")
  let (s, _) = render_msg("zh", StatsReport("api"))
  assert_eq(s, "bm2 统计报告 · api")
  assert_eq(s != h, true)
  let (dt, _) = render_msg("zh", DaemonAdopted(4))
  assert_eq(dt, "bm2d 已启动")
}
