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
const VERSION : String = "0.1.0"

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
  match command {
    "start" | "kill" | "list" | "refresh" => ()
    "version" => {
      println("bm2 " + VERSION)
      return 0
    }
    _ => {
      usage()
      return 2
    }
  }
  if command == "refresh" && args.length() != 2 {
    usage()
    return 2
  }
  let confirmed = command == "kill" && args.length() == 3 && args[2] == "-y"
  let app : String? = if confirmed {
    None
  } else if args.length() == 3 {
    Some(args[2])
  } else {
    None
  }
  // Bare `kill` stops bm2d and all apps, so it requires the -y flag.
  match (command, app) {
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
  // list/kill/refresh work from any directory while a daemon is running;
  // only start requires a bm2.toml here (they may need to spawn the
  // daemon from this config).
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
  // Requests must wait out the slowest possible daemon operation (a full
  // restart waiting on stop_timeout) plus margin, so a slow-but-healthy
  // daemon is never mistaken for a dead one. Without a config here the
  // slowest plausible stop timeout is assumed.
  let mut timeout_ms = 60000
  match config {
    Some(cfg) => {
      timeout_ms = 3000
      for app in cfg.apps {
        let need = app.stop_timeout_ms + 3000
        if need > timeout_ms {
          timeout_ms = need
        }
      }
    }
    None => ()
  }
  let state_dir = @core.resolve_state_dir()
  @core.log_event(state_dir, "bm2.events.jsonl", "daemon_connecting")
  let fd = match config {
    Some(_) =>
      try ensure_daemon(state_dir, config_path) catch {
        e => {
          @process.eprintln("bm2: " + e.to_string())
          return 1
        }
      } noraise {
        result => result
      }
    None =>
      // No config here: auto-restore the daemon from the config path it
      // was last started with, when one exists.
      match remembered_config_path(state_dir) {
        Some(path) =>
          try ensure_daemon(state_dir, path) catch {
            _ => connect(state_dir + "/bm2.sock")
          } noraise {
            result => result
          }
        None => connect(state_dir + "/bm2.sock")
      }
  }
  let fd = match fd {
    Some(connected) => connected
    None => {
      if command == "list" {
        println("no instances")
        return 0
      }
      @process.eprintln(
        if config is None {
          "bm2: no daemon is running; run bm2 start from the project directory"
        } else {
          "bm2: bm2d did not start, see " + state_dir + "/bm2d.log"
        },
      )
      return 1
    }
  }
  // Resolve the daemon's own config path before the refresh request:
  // the daemon removes its pid file the moment it detaches, so reading
  // it after the response would race with the detach.
  let refresh_config = if command == "refresh" {
    match daemon_config_path(state_dir) {
      Some(path) => Some(path)
      None =>
        match config {
          Some(_) => Some(config_path)
          None => None
        }
    }
  } else {
    None
  }
  @core.log_event(
    state_dir,
    "bm2.events.jsonl",
    "request_sent",
    app~,
    detail=command,
  )
  let resp = try request(fd, command, app, timeout_ms) catch {
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
      // Without a config here there is nothing to rebuild the daemon
      // from, so the retry can only work when a config is available.
      let retry_fd = match config {
        Some(_) =>
          try ensure_daemon(state_dir, config_path) catch {
            retry => {
              @process.eprintln("bm2: " + retry.to_string())
              return 1
            }
          } noraise {
            connected => connected
          }
        None => None
      }
      let retry_fd = match retry_fd {
        Some(connected) => connected
        None => {
          @process.eprintln(
            if config is None {
              "bm2: daemon stopped; run bm2 start from the project directory"
            } else {
              "bm2: bm2d did not start, see " + state_dir + "/bm2d.log"
            },
          )
          return 1
        }
      }
      @core.log_event(state_dir, "bm2.events.jsonl", "protocol_retry")
      try request(retry_fd, command, app, timeout_ms) catch {
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
    } else if command == "refresh" {
      // refresh_config was resolved before the request was sent: it is
      // the daemon's own config path (local bm2.toml as a fallback).
      if !wait_daemon_exit(state_dir) {
        @process.eprintln("bm2: bm2d did not exit; refresh aborted")
        return 1
      }
      // The old daemon unlinks its socket just before exiting; give its
      // process a moment to fully terminate so its flock is released
      // before the fresh daemon tries to take it.
      @process.sleep_ms(50)
      let config_path = match refresh_config {
        Some(path) => path
        None => {
          @process.eprintln(
            "bm2: cannot determine daemon config; run bm2 start from the project directory",
          )
          return 1
        }
      }
      let fresh_fd = try ensure_daemon(state_dir, config_path) catch {
        e => {
          @process.eprintln("bm2: " + e.to_string())
          return 1
        }
      } noraise {
        result => result
      }
      match fresh_fd {
        Some(fd) => {
          @process.close(fd)
          println("refreshed")
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
      println(resp.message)
      // A successful start shows the resulting state right away.
      if command == "start" {
        print_list(resp.instances)
      }
      0
    }
  } else {
    @process.eprintln(resp.message)
    1
  }
}

///|
/// Wait for the refreshed daemon to detach (it removes its socket on the
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
/// The config path recorded by the last daemon start (bm2d.config).
/// Kept across crashes so the daemon can be auto-restored from any
/// directory; removed on explicit shutdown.
fn remembered_config_path(state_dir : String) -> String? {
  let text = try @fs.read_file_to_string(state_dir + "/bm2d.config") catch {
    _ => return None
  } noraise {
    data => data
  }
  let path = text.trim().to_owned()
  if path.is_empty() {
    None
  } else {
    Some(path)
  }
}

///|
/// Parse the leading decimal digits of `text` (a pid file's content).
fn parse_leading_int(text : String) -> Int {
  let mut pid = 0
  for c in text {
    if c is ('0'..='9') {
      pid = pid * 10 + c.to_int() - 48
    } else {
      break
    }
  }
  pid
}

///|
/// The config path the running daemon was started with, read from its
/// process cmdline (`bm2d <config-path>`). Lets refresh rebuild the
/// daemon from any directory, using the same config the daemon actually
/// runs. None when no daemon is running.
fn daemon_config_path(state_dir : String) -> String? {
  let pid_text = try @fs.read_file_to_string(state_dir + "/bm2d.pid") catch {
    _ => return None
  } noraise {
    text => text
  }
  let pid = parse_leading_int(pid_text.trim().to_owned())
  if pid <= 0 {
    return None
  }
  let cmdline = try @process.read_small("/proc/\{pid}/cmdline") catch {
    _ => return None
  } noraise {
    data => data
  }
  // argv: "bm2d\0<config-path>\0"; take the second NUL-separated entry.
  let mut count = 0
  let mut result : String? = None
  for part in @utf8.decode_lossy(cmdline).split("\u{0}") {
    count += 1
    if count == 2 {
      result = Some(part.to_owned())
      break
    }
  }
  result
}

///|
/// Send one request and wait at most timeout_ms for the daemon's first
/// response byte. A stale Unix socket can accept a connection without a
/// server, so waiting unboundedly would leave the CLI hung forever.
fn request(
  fd : Int,
  command : String,
  app : String?,
  timeout_ms : Int,
) -> @core.Response raise {
  @process.send_msg(fd, @core.encode_request({ command, app }))
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
fn ensure_daemon(state_dir : String, config_path : String) -> Int? raise {
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
          script: config_path,
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
    #|usage: bm2 <command> [app]
    #|
    #|commands:
    #|  start [app]    start apps (restart if already running)
    #|  kill [app]     stop one app; use -y to stop everything
    #|  refresh        restart the background service; apps keep running
    #|  list [app]     show app status
    #|  version        show version
  println(text)
}
