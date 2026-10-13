///|
async fn main {
  @proc.exit(run())
}

///|
async fn run() -> Int32 {
  match @proc.platform_error() {
    None => ()
    Some(msg) => {
      @proc.eprintln("bm2: " + msg)
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
        "stop",
        about="Stop a project, leaving it registered and stopped",
        positionals=[optional_name("Project to stop")],
      ),
      @argparse.Command(
        "remove",
        about="Retire a project: stop it, free its name, keep its logs",
        positionals=[optional_name("Project to remove")],
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
      @proc.eprintln(
        "bm2: refusing to stop bm2d and all apps; use 'bm2 kill -y' to confirm",
      )
      return 1
    }
    _ => ()
  }
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => {
      @proc.eprintln("bm2: cannot determine current directory")
      return 1
    }
  }
  let config_path = cwd + "/bm2.toml"
  // Only start needs a local bm2.toml: list/kill/reload address the
  // daemon's registered projects from any directory.
  let config = try @config.load(config_path) catch {
    e => {
      if command == "start" {
        @proc.eprintln("bm2: " + e.to_string())
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
            @proc.eprintln("bm2: " + problem)
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
        // Targets are delivered in parallel, so the request has to outlast the
        // slowest of them, not their sum.
        let notify_need = cfg.notify.timeout_ms + 3000
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
  let req : @protocol.Request = {
    protocol: Some(@protocol.PROTOCOL_VERSION),
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
      @proc.eprintln("bm2: bm2d did not start, see " + state_dir + "/bm2d.log")
      return 1
    }
    Unresponsive(message) => {
      @proc.eprintln("bm2: " + message)
      return 1
    }
    other => raise other
  } noraise {
    response => response
  }
  match @protocol.protocol_problem(resp.protocol) {
    Some(problem) => {
      @proc.eprintln("bm2: " + problem)
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
        // The daemon line is the overview's context line: printed before the
        // table, and only for an unfiltered `list` — a query for one app keeps
        // exactly the shape it always had (scripts read it row by row).
        if app is None {
          match resp.daemon {
            Some(info) => print_daemon(info)
            None => ()
          }
        }
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
    @proc.eprintln(resp.message)
    1
  }
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
  Replied(@protocol.Response)
  Errored(String)
}
