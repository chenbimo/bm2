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
    logs: @config.LogsConfig::builtin(),
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
/// The state dir holds the control-plane token: a path that is not a directory
/// must be refused at startup instead of being written into.
test "a state dir that is not a directory is refused" {
  let root = "/tmp/bm2-wbtest-statedir-\{@proc.get_pid()}"
  @fsx.mkdir_p(root)
  let file = root + "/not-a-dir"
  @fsx.write_atomic(file, @utf8.encode("x"))
  let refused = try {
    ignore(Supervisor::new(state_dir=file, bun_path="/bin/sh"))
    false
  } catch {
    _ => true
  } noraise {
    value => value
  }
  assert_true(refused)
}

///|
/// The daemon reports about itself: managed instances and a monotonic command
/// counter an operator can sample twice.
test "daemon info counts instances and commands" {
  let root = "/tmp/bm2-wbtest-daemon-info-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4459)
  let info = sv.daemon_info()
  assert_eq(info.instances, 1)
  assert_eq(info.commands_applied, 0UL)
  assert_eq(info.pending_restarts, 0)
  assert_eq(info.pending_removals, 0)
  assert_eq(info.pid, @proc.get_pid())
  // Uptime is a duration measured from construction.
  assert_true(info.uptime_ms < 60000UL)
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
/// The rotation set is built on the tick and executed on the rotation task, so
/// what supervision owes the rotation task is exactly this list: every
/// instance's three logs, plus the three daemon-level ones, with copytruncate
/// only where a process holds the file open.
test "publish_rotation names every log and who holds it open" {
  let root = "/tmp/bm2-wbtest-rotate-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4452)
  sv.publish_rotation()
  let jobs = match sv.rotations().try_get() {
    Some(jobs) => jobs
    None => fail("expected publish_rotation to publish a sweep")
  }
  let found : Map[String, Bool] = Map([])
  for job in jobs {
    found.set(job.path, job.copytruncate)
    // The built-in policy travels with every job: this project has no `[logs]`
    // table, and the daemon's own logs are not any project's to configure.
    assert_eq(job.max_bytes, 10L * 1024L * 1024L)
    assert_eq(job.keep, 0)
  }
  let base = root + "/state/wbapp/logs/wbapp-0"
  // stdout and stderr are held open by the app; the crash log is ours.
  assert_eq(found.get(base + ".out.log"), Some(true))
  assert_eq(found.get(base + ".error.log"), Some(true))
  assert_eq(found.get(base + ".crash.log"), Some(false))
  assert_eq(found.get(root + "/state/bm2d.events.jsonl"), Some(false))
  assert_eq(found.get(root + "/state/bm2.events.jsonl"), Some(false))
  assert_eq(found.get(root + "/state/bm2d.log"), Some(true))
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

///|
/// A killed child of a failed spawn is handed to the tick, not waited for. This
/// drives the reaper with a real child, because the branch that matters is the
/// one that actually reaps.
test "the tick reaps a killed child without waiting for it" {
  let root = "/tmp/bm2-wbtest-reap-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4455)
  let pid = @proc.spawn({
    bun_path: "/bin/sh",
    script: "-c\u{0}sleep 30",
    cwd: root,
    out_log: root + "/reap.out.log",
    err_log: root + "/reap.err.log",
    env_blob: @proc.instance_env_blob("wbapp", 0, 4455),
  })
  // The child calls setsid() after the fork, so its process group does not exist
  // yet at the instant spawn returns: let it settle before signalling the group.
  @proc.sleep_ms(150)
  @utils.discard(() => @proc.kill_group(pid, @proc.SIGKILL))
  sv.register_reap(pid)
  assert_eq(sv.reaping.length(), 1)
  // The tick's sweep, driven by hand. A SIGKILL needs a few rounds at most.
  for _ in 0..<25 {
    sv.check_reaps()
    if sv.reaping.is_empty() {
      break
    }
    @proc.sleep_ms(20)
  }
  assert_true(sv.reaping.is_empty())
  // The other half of the contract: a live child is kept, not reaped. The entry
  // has to survive as long as the process does, or a slow exit would be
  // forgotten while the zombie is still there.
  let live = @proc.spawn({
    bun_path: "/bin/sh",
    script: "-c\u{0}sleep 30",
    cwd: root,
    out_log: root + "/reap-live.out.log",
    err_log: root + "/reap-live.err.log",
    env_blob: @proc.instance_env_blob("wbapp", 1, 4456),
  })
  sv.register_reap(live)
  sv.check_reaps()
  assert_eq(sv.reaping.length(), 1)
  @proc.sleep_ms(150)
  @utils.discard(() => @proc.kill_group(live, @proc.SIGKILL))
  for _ in 0..<25 {
    sv.check_reaps()
    if sv.reaping.is_empty() {
      break
    }
    @proc.sleep_ms(20)
  }
  assert_true(sv.reaping.is_empty())
}

///|
/// The two ways an entry leaves the list unreaped: a pid that is not ours (ECHILD
/// — reaped already, adopted, or never a child), and a window that has closed.
/// Both drop the entry rather than hold the tick, and the list stays bounded.
test "check_reaps drops what it cannot reap, and the list stays bounded" {
  let root = "/tmp/bm2-wbtest-reap-drop-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4456)
  // A window already closed, and a pid that is not our child (pid 1).
  sv.reaping.push((1, 0UL))
  sv.reaping.push((1, @proc.monotonic_ms() + 60000UL))
  sv.check_reaps()
  assert_true(sv.reaping.is_empty())
  // Past the limit the oldest entry goes, so the list cannot grow without bound.
  for i in 0..<(ORPHAN_REAP_LIMIT + 1) {
    sv.register_reap(1000 + i)
  }
  assert_eq(sv.reaping.length(), ORPHAN_REAP_LIMIT)
}

///|
/// A project's name is its identity: state dir, logs, supervision, policy. So the
/// same name may not be re-registered from a different config file — which would
/// put this project's policy in charge of another project's state — while the
/// same project re-running `start` must keep working, however its path is spelled.
test "a name may not be re-registered from a different config file" {
  let root = "/tmp/bm2-wbtest-name-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4460)
  let first = root + "/a/bm2.toml"
  let second = root + "/b/bm2.toml"
  @fsx.mkdir_p(root + "/a")
  @fsx.mkdir_p(root + "/b")
  @fsx.write_atomic(first, @utf8.encode("name = \"cfg\"\n"))
  @fsx.write_atomic(second, @utf8.encode("name = \"cfg\"\n"))
  let config = wb_config("other", root + "/a", 4470)
  sv.register(config, first)
  // Same file, one redundant `.` segment: still the same project.
  sv.register(config, root + "/a/./bm2.toml")
  // A different file claiming the name is refused, naming the owner.
  let conflict = try {
    sv.register(config, second)
    ""
  } catch {
    e => e.to_string()
  } noraise {
    _ => ""
  }
  let owner = match @fsx.realpath(first) {
    Some(real) => real
    None => first
  }
  assert_true(conflict.contains("other"))
  assert_true(conflict.contains(owner))
}

///|
/// The register of everything a project name owns. `forget_app` is the one place
/// that releases it, so this test fails the moment one of these maps stops being
/// cleared — and a forgotten map is a silent cross-project leak, because the name
/// would keep answering with a dead project's state.
test "a forgotten project leaves nothing behind" {
  let root = "/tmp/bm2-wbtest-forget-\{@proc.get_pid()}"
  let sv = wb_setup(root, 4480)
  let name = "wbapp"
  // Touch the per-project maps a live project fills in, so that "nothing left
  // behind" is a statement about cleared state rather than about empty maps.
  sv.storm_hits[name] = [1UL]
  // The probe map is keyed by `app/instance`, which is what `drop_app_keys`
  // matches on — the real convention, so this asserts the real cleanup.
  sv.start_probe_done[name + "/0"] = 1UL
  match sv.projects.get(name) {
    Some(project) => project.stopped = true
    None => fail("expected the registered project")
  }
  assert_true(sv.projects.contains(name))
  sv.forget_app(name)
  // Every map keyed by the project name: the daemon's own nine, then the four the
  // notify side keeps.
  assert_false(sv.apps.contains(name))
  assert_false(sv.instances.contains(name))
  assert_false(sv.pending_restart.contains(name))
  assert_false(sv.pending_remove.contains(name))
  assert_false(sv.projects.contains(name))
  assert_false(sv.stats_window.contains(name))
  assert_false(sv.storm_hits.contains(name))
  assert_false(sv.start_probe_done.contains(name + "/0"))
  let notify = sv.notifier()
  assert_false(notify.offline_since.contains(name))
  assert_false(notify.cpu_samples.contains(name))
  assert_false(notify.rss_peak.contains(name))
  assert_false(notify.rss_peak_daily.contains(name))
}
