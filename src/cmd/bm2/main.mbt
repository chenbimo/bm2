///|
async fn main {
  @util.exit(run())
}

///|
async fn run() -> Int32 {
  match @util.platform_error() {
    None => ()
    Some(msg) => {
      @util.eprintln("bm2: " + msg)
      return 1
    }
  }
  // 子命令注册:参数定义即文档,help 与错误提示由 core/argparse 自动渲染。
  let state_dir = @core.resolve_state_dir()
  let optional_name = fn(about : String) {
    @argparse.PositionArg(
      "name",
      about~,
      num_args=@argparse.ValueRange(lower=0, upper=1),
    )
  }
  let cmd = @argparse.Command(
    "bm2",
    about="Process manager for Bun / Node.js on Linux",
    version=VERSION,
    subcommands=[
      @argparse.Command(
        "start",
        about="Register and start the project in the current directory",
      ),
      @argparse.Command(
        "kill",
        about="Stop and unregister a project",
        flags=[
          @argparse.FlagArg(
            "all",
            short='y',
            about="Stop bm2d and all apps (skip confirmation)",
          ),
        ],
        positionals=[optional_name("Limit to this project")],
      ),
      @argparse.Command(
        "list",
        about="Show project status",
        flags=[@argparse.FlagArg("json", about="Machine-readable JSON output")],
        positionals=[optional_name("Limit to this project")],
      ),
      @argparse.Command(
        "check",
        about="Validate the bm2.toml in the current directory",
      ),
      @argparse.Command(
        "reload",
        about="Restart the daemon with a new binary; apps keep running",
      ),
      @argparse.Command(
        "notify",
        about="Send a test message to notification targets",
        positionals=[optional_name("Test only this target")],
      ),
      @argparse.Command("upgrade", about="Upgrade bm2 and apply it seamlessly"),
      @argparse.Command("version", about="Show version"),
    ],
  )
  let matches = try cmd.parse(env=Map([])) catch {
    err => {
      // argparse 已把错误与上下文 help 打到 stderr,这里只补退出码。
      println("\{err}")
      return 2
    }
  } noraise {
    parsed => parsed
  }
  let (command, sub) = match matches.subcommand {
    Some((name, sub)) => (name, sub)
    None => {
      println(cmd.render_help())
      return 2
    }
  }
  let json_flag = sub.flags.get("json") is Some(true)
  let confirmed = sub.flags.get("all") is Some(true)
  let app_arg : String? = match sub.values.get("name") {
    Some(names) if names.length() > 0 => Some(names[0])
    _ =>
      match sub.values.get("target") {
        Some(names) if names.length() > 0 => Some(names[0])
        _ => None
      }
  }
  match command {
    "upgrade" => return cmd_upgrade(state_dir)
    "version" => {
      println("bm2 " + VERSION)
      return 0
    }
    "check" => return cmd_check()
    _ => ()
  }
  // `-y` 专属于"停止 bm2d 与全部应用";与项目名同时出现视为用法错误。
  if confirmed && app_arg is Some(_) {
    println(cmd.render_help())
    return 2
  }
  // Bare `kill` stops bm2d and all apps, so it requires the -y flag.
  match (command, app_arg) {
    ("kill", None) if !confirmed => {
      @util.eprintln(
        "bm2: refusing to stop bm2d and all apps; use 'bm2 kill -y' to confirm",
      )
      return 1
    }
    _ => ()
  }
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => {
      @util.eprintln("bm2: cannot determine current directory")
      return 1
    }
  }
  let config_path = cwd + "/bm2.toml"
  // Only start needs a local bm2.toml: list/kill/reload address the
  // daemon's registered projects from any directory.
  let config = try @config.load(config_path) catch {
    e => {
      if command == "start" {
        @util.eprintln("bm2: " + e.to_string())
        return 1
      }
      None
    }
  } noraise {
    loaded => Some(loaded)
  }
  // start forces a full config verdict before registering: parsing already
  // ran above, and the filesystem cross-check (script presence) must pass
  // too, otherwise the project would enter a pointless crash-retry loop
  // against a script that was never there.
  if command == "start" {
    match config {
      Some(cfg) =>
        match check_project(cfg, @fs.path_exists) {
          Some(problem) => {
            @util.eprintln("bm2: " + problem)
            return 1
          }
          None => ()
        }
      None => ()
    }
  }
  // start targets the project itself (single-app config); kill filters by
  // name; notify takes a notification target name; kill -y has no target.
  let app : String? = if command == "start" {
    match config {
      Some(cfg) => Some(cfg.name)
      None => None
    }
  } else if command == "notify" {
    None
  } else {
    app_arg
  }
  let notify_target : String? = if command == "notify" { app_arg } else { None }
  // Requests must wait out the slowest possible daemon operation (a full
  // restart waiting on stop_timeout) plus margin, so a slow-but-healthy
  // daemon is never mistaken for a dead one. Without a config here the
  // slowest plausible stop timeout is assumed.
  let mut timeout_ms = 60000
  match config {
    Some(cfg) => {
      timeout_ms = 3000
      let need = cfg.stop_timeout_ms + 3000
      if need > timeout_ms {
        timeout_ms = need
      }
      if command == "notify" {
        // notify delivers synchronously, one target after another, so the CLI
        // has to wait out every target's own timeout.
        let mut targets = 0
        for report in cfg.notify.reports {
          targets += report.targets.length()
        }
        if targets == 0 {
          targets = 1
        }
        let notify_need = cfg.notify.timeout_ms * targets + 3000
        if notify_need > timeout_ms {
          timeout_ms = notify_need
        }
      }
    }
    None => ()
  }
  @core.log_event(state_dir, "bm2.events.jsonl", "daemon_connecting")
  // start carries the caller's config path so the daemon can register the
  // project; notify needs it to find the project's targets; other commands
  // leave it unset.
  let request_config_path : String? = if command == "start" ||
    command == "notify" {
    Some(config_path)
  } else {
    None
  }
  let req : @core.Request = {
    protocol: Some(@core.PROTOCOL_VERSION),
    command,
    app,
    config_path: request_config_path,
    notify_target,
  }
  let resp = try request_with_recovery(state_dir, req, timeout_ms) catch {
    NoDaemon => {
      if command == "list" {
        if json_flag {
          println("[]")
        } else {
          println("no instances")
        }
        return 0
      }
      @util.eprintln("bm2: bm2d did not start, see " + state_dir + "/bm2d.log")
      return 1
    }
    Unresponsive(message) => {
      @util.eprintln("bm2: " + message)
      return 1
    }
    other => raise other
  } noraise {
    response => response
  }
  match @core.protocol_problem(resp.protocol) {
    Some(problem) => {
      @util.eprintln("bm2: " + problem)
      return 1
    }
    None => ()
  }
  if resp.ok {
    if command == "list" {
      if json_flag {
        let parts = resp.instances.map(fn(info) {
          ToJson::to_json(info).stringify()
        })
        println("[" + parts.join(",") + "]")
      } else {
        print_list(resp.instances)
      }
      0
    } else if command == "reload" {
      // Swap in a fresh bm2d; the running apps are adopted unchanged.
      if swap_daemon(state_dir) {
        println("reloaded")
        0
      } else {
        1
      }
    } else {
      // start/kill <name> are async on the daemon side: poll `list` until
      // the target settles so the user sees the final state, while the
      // daemon loop never blocks on stop timeouts. kill -y only requests
      // the daemon shutdown and needs no polling.
      let infos = if command == "start" || app is Some(_) {
        poll_settled(state_dir, command, app, timeout_ms)
      } else {
        resp.instances
      }
      println(
        if settled(infos, app) {
          resp.message
        } else {
          resp.message + " (timed out waiting)"
        },
      )
      if app is Some(_) {
        print_list(infos)
      }
      0
    }
  } else {
    @util.eprintln(resp.message)
    1
  }
}

///|
/// Upgrade bm2 from the release station: fetch the manifest, compare the
/// published version with the running one, download this platform's binaries,
/// verify their SHA256, swap them in place, then swap the daemon so the new
/// binary takes over without touching the running apps.
/// The manifest and the online layout are defined in yicode-tech
/// `specs/update-spec.md`.
async fn cmd_upgrade(state_dir : String) -> Int32 {
  let base = update_base()
  let manifest_url = base +
    "/products/bm2/latest.json?t=" +
    @util.now_ms().to_string()
  let text = try fetch_text(manifest_url) catch {
    _ => {
      @util.eprintln("bm2: cannot reach the release station " + base)
      return 1
    }
  } noraise {
    body => body
  }
  let (version, artifacts) = match parse_manifest(text) {
    Some(parsed) => parsed
    None => {
      @util.eprintln("bm2: cannot read the release manifest")
      return 1
    }
  }
  if @util.compare(@util.parse(version), @util.parse(VERSION)) <= 0 {
    println("bm2 is up to date (" + VERSION + ")")
    return 0
  }
  println("new version " + version + " available (current " + VERSION + ")")
  let target = self_target()
  // bm2 与 bm2d 必须同批取到,缺一不可,否则会出现半更新。
  let picked = match pick_artifacts(artifacts, target, ["bm2", "bm2d"]) {
    Some(items) => items
    None => {
      @util.eprintln("bm2: no release for " + target + " yet")
      return 1
    }
  }
  match install_artifacts(picked, self_dir()) {
    Some(reason) => {
      @util.eprintln("bm2: " + reason)
      return 1
    }
    None => ()
  }
  // Apply immediately when a daemon is running; a failed swap still
  // leaves the update installed, so only the message differs.
  apply_update(state_dir)
}

///|
/// Apply a freshly installed binary without touching running apps: wait
/// out the old daemon, start the replacement, adopt the survivors.
async fn apply_update(state_dir : String) -> Int32 {
  let running = match connect_daemon(state_dir) {
    Some((conn, _)) => {
      conn.close()
      true
    }
    None => false
  }
  if running && swap_daemon(state_dir) {
    println("updated and applied")
    0
  } else if running {
    println("updated; run 'bm2 reload' to apply")
    0
  } else {
    println("updated")
    0
  }
}

///|
/// Swap in a fresh daemon: wait out the old daemon's exit, then start
/// the replacement which adopts the running apps. Shared by the `reload`
/// command and the automatic apply after `upgrade`. True once the fresh
/// daemon answers; failure reasons go to stderr.
async fn swap_daemon(state_dir : String) -> Bool {
  // The old daemon removes its control-plane files just before exiting;
  // wait for it, then start the fresh daemon which adopts the running apps.
  if !wait_daemon_exit(state_dir) {
    @util.eprintln("bm2: bm2d did not exit; swap aborted")
    return false
  }
  @async.sleep(50)
  // The old daemon's flock is released on exit; retry briefly in case
  // it has not fully terminated yet.
  let mut fresh : (@socket.Tcp, String)? = None
  for _ in 0..<3 {
    fresh = try ensure_daemon(state_dir) catch {
      _ => None
    } noraise {
      result => Some(result)
    }
    match fresh {
      Some(_) => break
      None => @async.sleep(100)
    }
  }
  match fresh {
    Some((conn, _)) => {
      conn.close()
      true
    }
    None => {
      @util.eprintln("bm2: bm2d did not start, see " + state_dir + "/bm2d.log")
      false
    }
  }
}

///|
/// Directory containing the running bm2 binary; upgrades replace it and
/// bm2d in place.
fn self_dir() -> String {
  let exe = try @util.self_exe() catch {
    _ => return "."
  } noraise {
    found => found
  }
  let mut idx = -1
  for i, c in exe {
    if c == '/' {
      idx = i
    }
  }
  if idx >= 0 {
    exe[:idx].to_owned()
  } else {
    "."
  }
}

///|
/// Poll `list` until every instance of the target app reaches a terminal
/// status (or leaves the listing after a stop), or the deadline passes.
/// For a kill the goal state is the project disappearing: an unknown-app
/// error response means the daemon finished unregistering it.
async fn poll_settled(
  state_dir : String,
  command : String,
  app : String?,
  timeout_ms : Int32,
) -> Array[@core.InstanceInfo] {
  let deadline = @util.now_ms() + timeout_ms.to_uint64()
  let mut last : Array[@core.InstanceInfo] = []
  let poll_req : @core.Request = {
    protocol: Some(@core.PROTOCOL_VERSION),
    command: "list",
    app,
    config_path: None,
    notify_target: None,
  }
  while true {
    @async.sleep(200)
    let resp = try {
      match connect_daemon(state_dir) {
        Some(pair) => Some(send_request(pair, poll_req, 3000))
        None => None
      }
    } catch {
      _ => None
    } noraise {
      r => r
    }
    match resp {
      Some(r) if r.ok => {
        last = r.instances
        // For a start, terminal statuses finish the wait. For a kill the
        // instances disappear first; the project is only gone once the
        // daemon answers with unknown-app, so keep polling until then.
        if command != "kill" && settled(r.instances, app) {
          break
        }
      }
      Some(r) if !r.ok && command == "kill" => break
      _ => ()
    }
    if @util.now_ms() > deadline {
      break
    }
  }
  last
}

///|
/// True when every instance of the target app is in a terminal status.
/// Stopped instances leave the listing entirely, so an empty match set
/// also counts as settled.
fn settled(infos : Array[@core.InstanceInfo], app : String?) -> Bool {
  let relevant = infos.filter(fn(info) {
    match app {
      None => true
      Some(name) => info.app_name == name
    }
  })
  if relevant.is_empty() {
    return true
  }
  relevant.all(fn(info) { info.status == "online" || info.status == "errored" })
}

///|
/// Wait for the reloaded daemon to detach (it removes its port/token files
/// on the way out). Returns false when the daemon stays alive after five
/// seconds.
async fn wait_daemon_exit(state_dir : String) -> Bool {
  for _ in 0..<100 {
    match connect_daemon(state_dir) {
      None => return true
      Some((conn, _)) => {
        conn.close()
        @async.sleep(50)
      }
    }
  }
  false
}

///|
/// How one CLI invocation talks to the daemon failed. Naming the two
/// failure modes keeps the caller's reporting honest: "nothing is running"
/// and "something is running but did not answer" need different advice.
suberror CliError {
  NoDaemon
  Unresponsive(String)
}

///|
/// One send attempt: the daemon's answer, or the reason there is none.
enum Send {
  Replied(@core.Response)
  Errored(String)
}

///|
/// Send one request, recovering once from a stale daemon: when the request
/// fails and nothing is listening on the recorded port anymore, remove the
/// leftover control-plane files, start a fresh daemon and retry. A daemon
/// that is merely busy (still inside a long stop timeout) keeps answering
/// connects, so it is reported instead of being split in two.
async fn request_with_recovery(
  state_dir : String,
  req : @core.Request,
  timeout_ms : Int32,
) -> @core.Response {
  let pair = match connect_or_start(state_dir) {
    Some(pair) => pair
    None => raise NoDaemon
  }
  @core.log_event(
    state_dir,
    "bm2.events.jsonl",
    "request_sent",
    app=req.app,
    detail=req.command,
  )
  let detail = match send_attempt(pair, req, timeout_ms) {
    Replied(response) => return response
    Errored(message) => message
  }
  @core.log_event(state_dir, "bm2.events.jsonl", "protocol_failed", detail~)
  match connect_daemon(state_dir) {
    Some((alive, _)) => {
      alive.close()
      raise Unresponsive(
        "bm2d is running but did not answer within \{timeout_ms}ms; try again in a moment",
      )
    }
    None => ()
  }
  @util.discard(() => @util.unlink(state_dir + "/" + @ipc.PORT_FILE))
  @util.discard(() => @util.unlink(state_dir + "/" + @ipc.TOKEN_FILE))
  @core.log_event(state_dir, "bm2.events.jsonl", "stale_socket_removed")
  let retry = match connect_or_start(state_dir) {
    Some(pair) => pair
    None => raise NoDaemon
  }
  @core.log_event(state_dir, "bm2.events.jsonl", "protocol_retry")
  match send_attempt(retry, req, timeout_ms) {
    Replied(response) => response
    Errored(message) => raise Unresponsive(message)
  }
}

///|
/// `ensure_daemon` with its failure collapsed to None: the CLI reports
/// "bm2d did not start" with the log path, so the underlying errno would
/// only add noise.
async fn connect_or_start(state_dir : String) -> (@socket.Tcp, String)? {
  try ensure_daemon(state_dir) catch {
    _ => None
  } noraise {
    pair => Some(pair)
  }
}

///|
async fn send_attempt(
  pair : (@socket.Tcp, String),
  req : @core.Request,
  timeout_ms : Int32,
) -> Send {
  try send_request(pair, req, timeout_ms) catch {
    e => Errored(e.to_string())
  } noraise {
    response => Replied(response)
  }
}

///|
/// Send one request over an authenticated channel and wait at most
/// timeout_ms for the daemon's answer, so a busy-but-healthy daemon can
/// never hang the CLI forever.
async fn send_request(
  pair : (@socket.Tcp, String),
  req : @core.Request,
  timeout_ms : Int32,
) -> @core.Response {
  let (conn, token) = pair
  let response = @ipc.round_trip(conn, token, req, timeout_ms)
  conn.close()
  response
}

///|
/// Open an authenticated channel to the running daemon. None when there is
/// nothing to talk to: no port file, no listener, or no token file.
async fn connect_daemon(state_dir : String) -> (@socket.Tcp, String)? {
  let token = match @ipc.read_token(state_dir) {
    Some(token) => token
    None => return None
  }
  let conn = try @ipc.dial(state_dir) catch {
    _ => None
  } noraise {
    opened => Some(opened)
  }
  match conn {
    Some(conn) => Some((conn, token))
    None => None
  }
}

///|
/// Connect to the running daemon, spawning bm2d when the recorded endpoint
/// is not answering. bm2d is resolved through PATH (execvpe). Raises when
/// the daemon did not come up in time.
async fn ensure_daemon(state_dir : String) -> (@socket.Tcp, String) {
  match connect_daemon(state_dir) {
    Some(pair) => {
      @core.log_event(state_dir, "bm2.events.jsonl", "daemon_connected")
      pair
    }
    None => {
      @core.log_event(state_dir, "bm2.events.jsonl", "daemon_spawn_requested")
      @util.mkdir_p(state_dir, mode=0o700)
      ignore(
        @util.spawn({
          bun_path: "bm2d",
          script: "",
          cwd: "/",
          out_log: state_dir + "/bm2d.log",
          err_log: state_dir + "/bm2d.log",
          env_blob: @util.base_env_blob(),
        }),
      )
      for _ in 0..<60 {
        @async.sleep(50)
        match connect_daemon(state_dir) {
          Some(pair) => return pair
          None => ()
        }
      }
      raise @util.ProcessError::Failed(op="ensure_daemon", errno=2)
    }
  }
}

///|
fn print_list(instances : Array[@core.InstanceInfo]) -> Unit {
  if instances.length() == 0 {
    println("no instances")
    return
  }
  let header = [
    "NAME", "ID", "PID", "PORT", "MODE", "STATUS", "TIMES", "MEMORY", "UPTIME", "CWD",
  ]
  let rows = []
  for info in instances {
    let pid = if info.pid > 0 { info.pid.to_string() } else { "-" }
    let memory = if info.rss_kb >= 0 {
      (info.rss_kb / 1024).to_string() + " MB"
    } else {
      "-"
    }
    let uptime = if info.pid > 0 { format_uptime(info.uptime_ms) } else { "-" }
    rows.push([
      info.app_name,
      info.instance_id.to_string(),
      pid,
      info.port.to_string(),
      info.exec_mode,
      info.status,
      info.times.to_string(),
      memory,
      uptime,
      info.cwd,
    ])
  }
  let widths = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  for i in 0..<header.length() {
    widths[i] = header[i].length()
  }
  for row in rows {
    for i in 0..<row.length() {
      if row[i].length() > widths[i] {
        widths[i] = row[i].length()
      }
    }
  }
  print_row(header, widths)
  for row in rows {
    print_row(row, widths)
  }
}

///|
fn print_row(cols : Array[String], widths : Array[Int32]) -> Unit {
  let buf = StringBuilder()
  for i in 0..<cols.length() {
    if i > 0 {
      buf.write_string("  ")
    }
    buf.write_string(cols[i])
    for _ in 0..<(widths[i] - cols[i].length()) {
      buf.write_string(" ")
    }
  }
  println(buf.to_string())
}

///|
fn format_uptime(ms : UInt64) -> String {
  let s = (ms / 1000UL).to_int()
  if s < 60 {
    return "\{s}s"
  }
  let m = s / 60
  if m < 60 {
    return "\{m}m \{pad2(s % 60)}s"
  }
  let h = m / 60
  if h < 24 {
    return "\{h}h \{pad2(m % 60)}m"
  }
  "\{h / 24}d \{pad2(h % 24)}h"
}

///|
fn pad2(n : Int32) -> String {
  if n < 10 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}
