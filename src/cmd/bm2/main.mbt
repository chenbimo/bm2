///|
fn main {
  @process.exit(run())
}

///|
fn run() -> Int {
  let args = @env.args()
  if args.length() < 2 || args.length() > 3 {
    usage()
    return 2
  }
  let command = args[1]
  match command {
    "start" | "kill" | "list" => ()
    _ => {
      usage()
      return 2
    }
  }
  let app : String? = if args.length() == 3 { Some(args[2]) } else { None }
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => {
      @process.eprintln("bm2: cannot determine current directory")
      return 1
    }
  }
  let config_path = cwd + "/bm2.toml"
  try @config.load(config_path) catch {
    e => {
      @process.eprintln("bm2: " + e.to_string())
      return 1
    }
  } noraise {
    _ => ()
  }
  let state_dir = @core.resolve_state_dir()
  @core.log_event(state_dir, "bm2.events.jsonl", "daemon_connecting")
  let fd = try ensure_daemon(state_dir, config_path) catch {
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
  let resp = try request(fd, command, app) catch {
    e => {
      @process.close(fd)
      @core.log_event(
        state_dir,
        "bm2.events.jsonl",
        "protocol_failed",
        detail=e.to_string(),
      )
      try @process.unlink(state_dir + "/bm2.sock") catch {
        _ => ()
      } noraise {
        _ => ()
      }
      @core.log_event(state_dir, "bm2.events.jsonl", "stale_socket_removed")
      let retry_fd = try ensure_daemon(state_dir, config_path) catch {
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
      try request(retry_fd, command, app) catch {
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
    } else {
      println(resp.message)
    }
    0
  } else {
    @process.eprintln(resp.message)
    1
  }
}

///|
/// Send one request and wait at most three seconds for the daemon's first
/// response byte. A stale Unix socket can accept a connection without a
/// server, so waiting unboundedly would leave the CLI hung forever.
fn request(fd : Int, command : String, app : String?) -> @core.Response raise {
  @process.send_msg(fd, @core.encode_request({ command, app }))
  if !@process.poll_fd(fd, 3000) {
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
    #|  start [app]    start (or fully restart) one app or all apps
    #|  kill [app]     SIGKILL one app, or stop bm2d and all apps
    #|  list [app]     show instance list
  println(text)
}
