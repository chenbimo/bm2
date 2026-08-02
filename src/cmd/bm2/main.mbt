///|
fn main {
  @process.exit(run())
}

///|
/// bm2 is Linux-only; refuse to run elsewhere with a clear message
/// instead of failing on the first POSIX-specific syscall.
/// Returns None when the platform is supported.
fn platform_error() -> String? {
  try {
    let name = @process.uname()
    if name == "Linux" {
      None
    } else {
      Some("this build supports Linux only (detected: \{name})")
    }
  } catch {
    e => Some("cannot detect platform: \{e.to_string()}")
  } noraise {
    ok => ok
  }
}

///|
/// Keep in sync with moon.mod `version`.
const VERSION : String = "0.2.0"

///|
fn run() -> Int {
  match platform_error() {
    None => ()
    Some(msg) => {
      @process.eprintln("bm2: " + msg)
      return 1
    }
  }
  let args = @env.args()
  if args.length() < 2 || args.length() > 3 {
    usage()
    return 2
  }
  let command = args[1]
  let state_dir = @core.resolve_state_dir()
  match command {
    "start" | "kill" | "list" | "reload" => ()
    "upgrade" => {
      if args.length() != 2 {
        usage()
        return 2
      }
      return cmd_upgrade(state_dir)
    }
    "version" => {
      println("bm2 " + VERSION)
      return 0
    }
    _ => {
      usage()
      return 2
    }
  }
  // start/reload take no arguments; kill takes a name or -y; list may
  // filter by name.
  if (command == "start" || command == "reload") && args.length() != 2 {
    usage()
    return 2
  }
  let confirmed = command == "kill" && args.length() == 3 && args[2] == "-y"
  let app_arg : String? = if confirmed {
    None
  } else if args.length() == 3 {
    Some(args[2])
  } else {
    None
  }
  // Bare `kill` stops bm2d and all apps, so it requires the -y flag.
  match (command, app_arg) {
    ("kill", None) if !confirmed => {
      @process.eprintln(
        "bm2: refusing to stop bm2d and all apps; use 'bm2 kill -y' to confirm",
      )
      return 1
    }
    _ => ()
  }
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => {
      @process.eprintln("bm2: cannot determine current directory")
      return 1
    }
  }
  let config_path = cwd + "/bm2.toml"
  // Only start needs a local bm2.toml: list/kill/reload address the
  // daemon's registered projects from any directory.
  let config = try @config.load(config_path) catch {
    e => {
      if command == "start" {
        @process.eprintln("bm2: " + e.to_string())
        return 1
      }
      None
    }
  } noraise {
    loaded => Some(loaded)
  }
  // start targets the project itself (single-app config); kill filters by
  // name; kill -y has no target.
  let app : String? = if command == "start" {
    match config {
      Some(cfg) => Some(cfg.name)
      None => None
    }
  } else {
    app_arg
  }
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
    }
    None => ()
  }
  @core.log_event(state_dir, "bm2.events.jsonl", "daemon_connecting")
  let fd = try ensure_daemon(state_dir) catch {
    e => {
      @process.eprintln("bm2: " + e.to_string())
      return 1
    }
  } noraise {
    result => result
  }
  let fd = match fd {
    Some(connected) => connected
    None => {
      if command == "list" {
        println("no instances")
        return 0
      }
      @process.eprintln(
        "bm2: bm2d did not start, see " + state_dir + "/bm2d.log",
      )
      return 1
    }
  }
  @core.log_event(
    state_dir,
    "bm2.events.jsonl",
    "request_sent",
    app~,
    detail=command,
  )
  // start carries the caller's config path so the daemon can register the
  // project; other commands leave it unset.
  let request_config_path : String? = if command == "start" {
    Some(config_path)
  } else {
    None
  }
  let resp = try
    request(fd, command, app, request_config_path, timeout_ms)
  catch {
    e => {
      @process.close(fd)
      @core.log_event(
        state_dir,
        "bm2.events.jsonl",
        "protocol_failed",
        detail=e.to_string(),
      )
      // The daemon may simply be slow (waiting out a long stop timeout).
      // Only treat the socket as stale when nothing is listening anymore;
      // otherwise refuse instead of splitting the daemon in two.
      match connect(state_dir + "/bm2.sock") {
        Some(alive_fd) => {
          @process.close(alive_fd)
          @process.eprintln("bm2: daemon is busy; try again in a moment")
          return 1
        }
        None => ()
      }
      try @process.unlink(state_dir + "/bm2.sock") catch {
        _ => ()
      } noraise {
        _ => ()
      }
      @core.log_event(state_dir, "bm2.events.jsonl", "stale_socket_removed")
      let retry_fd = try ensure_daemon(state_dir) catch {
        retry => {
          @process.eprintln("bm2: " + retry.to_string())
          return 1
        }
      } noraise {
        connected => connected
      }
      let retry_fd = match retry_fd {
        Some(connected) => connected
        None => {
          @process.eprintln(
            "bm2: bm2d did not start, see " + state_dir + "/bm2d.log",
          )
          return 1
        }
      }
      @core.log_event(state_dir, "bm2.events.jsonl", "protocol_retry")
      try
        request(retry_fd, command, app, request_config_path, timeout_ms)
      catch {
        retry => {
          @process.eprintln("bm2: " + retry.to_string())
          @process.close(retry_fd)
          return 1
        }
      } noraise {
        response => response
      }
    }
  } noraise {
    response => response
  }
  if resp.ok {
    if command == "list" {
      print_list(resp.instances)
      0
    } else if command == "reload" {
      // The old daemon unlinks its socket just before exiting; wait for
      // it, then start the fresh daemon which adopts the running apps.
      if !wait_daemon_exit(state_dir) {
        @process.eprintln("bm2: bm2d did not exit; reload aborted")
        return 1
      }
      @process.sleep_ms(50)
      // The old daemon's flock is released on exit; retry briefly in case
      // it has not fully terminated yet.
      let mut fresh_fd : Int? = None
      for _ in 0..<3 {
        fresh_fd = try ensure_daemon(state_dir) catch {
          _ => None
        } noraise {
          result => result
        }
        match fresh_fd {
          Some(_) => break
          None => @process.sleep_ms(100)
        }
      }
      match fresh_fd {
        Some(fd) => {
          @process.close(fd)
          println("reloaded")
          0
        }
        None => {
          @process.eprintln(
            "bm2: bm2d did not start, see " + state_dir + "/bm2d.log",
          )
          1
        }
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
    @process.eprintln(resp.message)
    1
  }
}

///|
/// Upgrade bm2 itself: refresh the mooncakes index, compare the latest
/// published version with the running one, and run `moon install` into
/// bm2's own directory when a newer release exists. Requires the moon
/// toolchain (which is also how bm2 was installed).
fn cmd_upgrade(state_dir : String) -> Int {
  let home = match @env.get_env_var("HOME") {
    Some(h) if !h.is_empty() => h
    _ => {
      @process.eprintln("bm2: cannot determine HOME (moon toolchain required)")
      return 1
    }
  }
  if !run_moon(state_dir, "update" + "\u{0}") {
    @process.eprintln("bm2: 'moon update' failed; run it manually and retry")
    return 1
  }
  let index_path = home + "/.moon/registry/index/user/chensuiyi/bm2.index"
  let text = try @fs.read_file_to_string(index_path) catch {
    _ => {
      @process.eprintln("bm2: no release on mooncakes yet")
      return 1
    }
  } noraise {
    loaded => loaded
  }
  let latest = match latest_version(text) {
    Some(v) => v
    None => {
      @process.eprintln("bm2: cannot read the mooncakes index")
      return 1
    }
  }
  if semver_cmp(latest, VERSION) <= 0 {
    println("bm2 is up to date (" + VERSION + ")")
    return 0
  }
  println("new version " + latest + " available (current " + VERSION + ")")
  let args = "install" +
    "\u{0}" +
    "chensuiyi/bm2/..." +
    "\u{0}" +
    "--bin" +
    "\u{0}" +
    self_dir() +
    "\u{0}"
  if !run_moon(state_dir, args) {
    @process.eprintln(
      "bm2: 'moon install' failed; run it manually:\n  moon install chensuiyi/bm2/... --bin " +
      self_dir(),
    )
    return 1
  }
  println("updated to " + latest + "; run 'bm2 reload' to apply")
  0
}

///|
struct IndexEntry {
  version : String
} derive(FromJson)

///|
/// Latest version from the mooncakes index JSONL (last line wins).
fn latest_version(text : String) -> String? {
  let mut latest : String? = None
  for line in text.split("\n") {
    if line.trim().is_empty() {
      continue
    }
    let entry : IndexEntry = try @json.from_json(@json.parse(line)) catch {
      _ => continue
    } noraise {
      loaded => loaded
    }
    latest = Some(entry.version)
  }
  latest
}

///|
/// Compare two "x.y.z" versions: -1, 0, 1.
fn semver_cmp(a : String, b : String) -> Int {
  let pa = a.split(".").to_array()
  let pb = b.split(".").to_array()
  for i in 0..<3 {
    let x = if i < pa.length() { parse_num(pa[i].to_owned()) } else { 0 }
    let y = if i < pb.length() { parse_num(pb[i].to_owned()) } else { 0 }
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  0
}

///|
fn parse_num(s : String) -> Int {
  let mut n = 0
  for c in s {
    n = n * 10 + c.to_int() - 48
  }
  n
}

///|
/// Directory containing the running bm2 binary, where moon install
/// replaces it (and bm2d) in place.
fn self_dir() -> String {
  let exe = try @process.self_exe() catch {
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
/// Run moon with NUL-separated arguments; true on exit code 0. Output
/// goes to the state dir so a failure can be inspected there.
fn run_moon(state_dir : String, args_blob : String) -> Bool {
  let pid = try
    @process.spawn({
      bun_path: "moon",
      script: args_blob,
      cwd: "/",
      out_log: state_dir + "/upgrade.log",
      err_log: state_dir + "/upgrade.log",
      env_blob: @process.base_env_blob(),
    })
  catch {
    _ => return false
  } noraise {
    spawned => spawned
  }
  let reaped = try @process.wait_child(pid) catch {
    _ => None
  } noraise {
    result => result
  }
  match reaped {
    Some((_, @process.ChildExit::Exited(0))) => true
    _ => false
  }
}

///|
/// Poll `list` until every instance of the target app reaches a terminal
/// status (or leaves the listing after a stop), or the deadline passes.
/// For a kill the goal state is the project disappearing: an unknown-app
/// error response means the daemon finished unregistering it.
fn poll_settled(
  state_dir : String,
  command : String,
  app : String?,
  timeout_ms : Int,
) -> Array[@core.InstanceInfo] {
  let sock = state_dir + "/bm2.sock"
  let deadline = @core.now_ms() + timeout_ms.to_uint64()
  let mut last : Array[@core.InstanceInfo] = []
  while true {
    @process.sleep_ms(200)
    let resp = try {
      let fd = @process.socket_connect(sock)
      let result = request(fd, "list", app, None, 3000)
      Some(result)
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
    if @core.now_ms() > deadline {
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
/// Wait for the reloaded daemon to detach (it removes its socket on the
/// way out). Returns false when the daemon stays alive after five seconds.
fn wait_daemon_exit(state_dir : String) -> Bool {
  let sock = state_dir + "/bm2.sock"
  for _ in 0..<100 {
    match connect(sock) {
      None => return true
      Some(fd) => {
        @process.close(fd)
        @process.sleep_ms(50)
      }
    }
  }
  false
}

///|
/// Send one request and wait at most timeout_ms for the daemon's first
/// response byte. A stale Unix socket can accept a connection without a
/// server, so waiting unboundedly would leave the CLI hung forever.
fn request(
  fd : Int,
  command : String,
  app : String?,
  config_path : String?,
  timeout_ms : Int,
) -> @core.Response raise {
  @process.send_msg(fd, @core.encode_request({ command, app, config_path }))
  if !@process.poll_fd(fd, timeout_ms) {
    raise @process.ProcessError::Failed(op="recv_msg", errno=110)
  }
  let data = @process.recv_msg(fd)
  @process.close(fd)
  @core.decode_response(data)
}

///|
/// Connect to the running daemon, spawning bm2d when the socket is not
/// answering. bm2d is resolved through PATH (execvpe). Returns None when
/// the daemon did not come up in time.
fn ensure_daemon(state_dir : String) -> Int? raise {
  let sock = state_dir + "/bm2.sock"
  match connect(sock) {
    Some(fd) => {
      @core.log_event(state_dir, "bm2.events.jsonl", "daemon_connected")
      Some(fd)
    }
    None => {
      @core.log_event(state_dir, "bm2.events.jsonl", "daemon_spawn_requested")
      @process.mkdir_p(state_dir, mode=0o700)
      ignore(
        @process.spawn({
          bun_path: "bm2d",
          script: "",
          cwd: "/",
          out_log: state_dir + "/bm2d.log",
          err_log: state_dir + "/bm2d.log",
          env_blob: @process.base_env_blob(),
        }),
      )
      let mut connected : Int? = None
      for _ in 0..<60 {
        @process.sleep_ms(50)
        match connect(sock) {
          Some(fd) => {
            connected = Some(fd)
            break
          }
          None => ()
        }
      }
      connected
    }
  }
}

///|
fn connect(sock : String) -> Int? {
  try @process.socket_connect(sock) catch {
    _ => None
  } noraise {
    fd => Some(fd)
  }
}

///|
fn print_list(instances : Array[@core.InstanceInfo]) -> Unit {
  if instances.length() == 0 {
    println("no instances")
    return
  }
  let header = [
    "NAME", "ID", "PID", "PORT", "STATUS", "RESTARTS", "MEMORY", "UPTIME", "CWD",
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
      info.status,
      info.restart_count.to_string(),
      memory,
      uptime,
      info.cwd,
    ])
  }
  let widths = [0, 0, 0, 0, 0, 0, 0, 0, 0]
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
fn print_row(cols : Array[String], widths : Array[Int]) -> Unit {
  let buf = StringBuilder::new()
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
fn pad2(n : Int) -> String {
  if n < 10 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
fn usage() -> Unit {
  let text =
    #|usage: bm2 <command>
    #|
    #|commands:
    #|  start          register and start the project in the current directory
    #|  kill <name>    stop and unregister one project; use -y to stop everything
    #|  reload         restart the background service with a fresh binary; apps keep running
    #|  list [name]    show project status
    #|  upgrade        update bm2 to the latest mooncakes release
    #|  version        show version
  println(text)
}
