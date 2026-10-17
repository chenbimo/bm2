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
  // Take Ctrl+C and SIGTERM before anything that can take time. The MoonBit
  // runtime leaves them ignored and blocked (see proc/signal.mbt), and the slow
  // commands — `bm2 dev` above all — have to be interruptible. Failing here is
  // worth one line and nothing more: the worst case is the old behavior.
  try @proc.watch_interrupts() catch {
    e => @proc.eprintln("bm2: cannot take interrupts: " + e.to_string())
  } noraise {
    _ => ()
  }
  // Resolved once, from this process's environment, and sent with every request
  // so the daemon answers in the language this terminal is printing in.
  let lang = @i18n.resolve_env()
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
    about=@i18n.help_root(lang),
    version=VERSION,
    subcommands=[
      @argparse.Command("serve", about=@i18n.help_serve(lang)),
      @argparse.Command("dev", about=@i18n.help_dev(lang), flags=[
        @argparse.FlagArg("no-follow", about=@i18n.help_no_follow(lang)),
      ]),
      @argparse.Command("stop", about=@i18n.help_stop(lang), positionals=[
        optional_name(@i18n.arg_project_to_stop(lang)),
      ]),
      @argparse.Command(
        "remove",
        about=@i18n.help_remove(lang),
        flags=[
          @argparse.FlagArg("force", short='f', about=@i18n.help_force(lang)),
        ],
        positionals=[optional_name(@i18n.arg_project_to_remove(lang))],
      ),
      @argparse.Command(
        "kill",
        about=@i18n.help_kill(lang),
        flags=[@argparse.FlagArg("all", short='y', about=@i18n.help_all(lang))],
        positionals=[optional_name(@i18n.arg_limit_to_project(lang))],
      ),
      @argparse.Command(
        "list",
        about=@i18n.help_list(lang),
        flags=[@argparse.FlagArg("json", about=@i18n.help_json(lang))],
        positionals=[optional_name(@i18n.arg_limit_to_project(lang))],
      ),
      @argparse.Command("check", about=@i18n.help_check(lang)),
      @argparse.Command("reload", about=@i18n.help_reload(lang)),
      @argparse.Command("notify", about=@i18n.help_notify(lang), positionals=[
        optional_name(@i18n.arg_test_only_target(lang)),
      ]),
      @argparse.Command("clean", about=@i18n.help_clean(lang), flags=[
        @argparse.FlagArg("dry-run", about=@i18n.help_dry_run(lang)),
      ]),
      @argparse.Command("upgrade", about=@i18n.help_upgrade(lang)),
      @argparse.Command("version", about=@i18n.help_version(lang)),
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
  let dry_run_flag = sub.flags.get("dry-run") is Some(true) ||
    sub.flags.get("dry_run") is Some(true)
  let confirmed = sub.flags.get("all") is Some(true)
  let force_flag = sub.flags.get("force") is Some(true)
  let no_follow_flag = sub.flags.get("no-follow") is Some(true) ||
    sub.flags.get("no_follow") is Some(true)
  // `dev` and `serve` are the two start verbs: one supervision, two
  // environments. The verb travels as the command, so the daemon reads the mode
  // from it, and this load uses the same mode — otherwise the local verdict
  // could pass for a mode the daemon is not going to use.
  let mode = @config.Mode::of_command(command)
  let app_arg : String? = match sub.values.get("name") {
    Some(names) if names.length() > 0 => Some(names[0])
    _ =>
      match sub.values.get("target") {
        Some(names) if names.length() > 0 => Some(names[0])
        _ => None
      }
  }
  match command {
    "clean" => return cmd_clean(state_dir, dry_run_flag, lang)
    "upgrade" => return cmd_upgrade(state_dir, lang)
    "version" => {
      println("bm2 " + VERSION)
      return 0
    }
    "check" => return cmd_check(lang)
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
      @proc.eprintln("bm2: " + @i18n.kill_needs_confirmation(lang))
      return 1
    }
    _ => ()
  }
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => {
      @proc.eprintln("bm2: " + @i18n.cannot_determine_cwd(lang))
      return 1
    }
  }
  let config_path = cwd + "/bm2.toml"
  // Only start needs a local bm2.toml: list/kill/reload address the
  // daemon's registered projects from any directory.
  let config = try {
    match mode {
      Some(mode) => @config.load(config_path, mode~)
      None => @config.load(config_path)
    }
  } catch {
    e => {
      if mode is Some(_) {
        @proc.eprintln("bm2: " + e.to_string())
        return 1
      }
      None
    }
  } noraise {
    loaded => Some(loaded)
  }
  // A start verb forces a full config verdict before registering: parsing already
  // ran above, and the filesystem cross-check (script presence) must pass
  // too, otherwise the project would enter a pointless crash-retry loop
  // against a script that was never there.
  if mode is Some(_) {
    match config {
      Some(cfg) =>
        match check_project(cfg, @fs.path_exists, lang) {
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
  let app : String? = if mode is Some(_) {
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
  // A message about one project is written in that project's language, and a table
  // printed beside it has to match: a screen that says "已停止" above an English
  // table is two languages at once. So the project's language is used only when this
  // command is about the project whose config this process loaded. A table of
  // everything — or of some other project — stays in the operator's language,
  // because no single project could own it.
  let scoped_lang = match config {
    Some(cfg) =>
      if mode is Some(_) || app == Some(cfg.name) {
        match cfg.lang {
          Some(configured) => configured
          None => lang
        }
      } else {
        lang
      }
    None => lang
  }
  @core.log_event(state_dir, "bm2.events.jsonl", "daemon_connecting")
  // start carries the caller's config path so the daemon can register the
  // project; notify needs it to find the project's targets; other commands
  // leave it unset.
  let request_config_path : String? = if mode is Some(_) || command == "notify" {
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
    force: Some(force_flag),
    lang: Some(lang.name()),
  }
  let resp = try request_with_recovery(state_dir, req, timeout_ms) catch {
    NoDaemon => {
      if command == "list" {
        if json_flag {
          println("[]")
        } else {
          println(@i18n.no_instances(lang))
        }
        return 0
      }
      @proc.eprintln(@i18n.daemon_did_not_start(lang, state_dir))
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
            Some(info) => print_daemon(info, lang)
            None => ()
          }
        }
        print_list(resp.instances, scoped_lang)
      }
      0
    } else if command == "remove" && force_flag {
      // The daemon retires asynchronously: it unregisters once every instance has
      // stopped. Only after the project is gone from the registry is it safe to
      // delete its directory — before that we would be pulling files out from
      // under a project the daemon still supervises.
      match app {
        Some(name) =>
          if wait_project_gone(state_dir, name) {
            purge_project(state_dir, name)
            println(@i18n.removed(lang, name))
            0
          } else {
            @proc.eprintln(@i18n.retire_timeout(lang))
            1
          }
        None => 0
      }
    } else if command == "reload" {
      // Swap in a fresh bm2d; the running apps are adopted unchanged.
      if swap_daemon(state_dir, lang) {
        println(@i18n.reloaded(lang))
        0
      } else {
        1
      }
    } else {
      // A start verb or a named kill is async on the daemon side: poll `list`
      // until the target settles so the user sees the final state, while the
      // daemon loop never blocks on stop timeouts. kill -y only requests
      // the daemon shutdown and needs no polling.
      let infos = if mode is Some(_) || app is Some(_) {
        poll_settled(
          state_dir,
          command,
          app,
          timeout_ms,
          scoped_lang,
          !json_flag,
          resp.instances,
          command == "stop",
        )
      } else {
        resp.instances
      }
      println(
        if settled(infos, app, command == "stop") {
          resp.message
        } else {
          resp.message + @i18n.timed_out(scoped_lang)
        },
      )
      if app is Some(_) {
        print_list(infos, scoped_lang)
      }
      // `bm2 dev` is a development session, not just a start: it follows the
      // instance logs in this terminal until the user interrupts it. Following is
      // a view, not a leash — the app keeps running, and the first line printed
      // says how to stop it. `--no-follow` is for scripts and CI, where blocking
      // on a terminal would be a hang.
      if mode is Some(@config.Mode::Development) &&
        !no_follow_flag &&
        @proc.interrupted() == 0 &&
        settled(infos, app, false) {
        match app {
          Some(name) => follow_logs(state_dir, name, lang)
          None => ()
        }
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

///|
/// Wait for a retired project to leave the registry. The daemon does that once
/// every instance has stopped, and the signal is on disk: `project.json` is
/// removed as the removal finalizes. Watching the file keeps this to one request
/// and works even while the daemon is busy with something else.
fn wait_project_gone(state_dir : String, name : String) -> Bool {
  let marker = state_dir + "/" + name + "/project.json"
  for _ in 0..<300 {
    if !@fs.path_exists(marker) {
      return true
    }
    @proc.sleep_ms(100)
  }
  false
}

///|
/// Delete a retired project's state directory, logs included. `remove` keeps logs
/// on purpose, so this runs only for `bm2 remove -f`, and only after the daemon
/// has let go of the project. The layout is fixed: by then the state files are
/// already gone, so `logs/` is all that is left.
fn purge_project(state_dir : String, name : String) -> Unit {
  let root = state_dir + "/" + name
  let logs = root + "/logs"
  // The read is inside `discard`: a missing `logs/` is the normal case for a
  // project that never wrote anything, and the removals below then find nothing.
  if @fs.path_exists(logs) {
    @utils.discard(() => {
      for entry in @fs.read_dir(logs) {
        // Whether the directory lists bare names or joined paths is an x/fs
        // detail; accept either rather than depend on it.
        let path = if entry.has_prefix("/") {
          entry
        } else {
          logs + "/" + entry
        }
        @utils.discard(() => @fs.remove_file(path))
      }
    })
  }
  @utils.discard(() => @fs.remove_dir(logs))
  // The state files at the top level are ours as well: the daemon removes
  // `project.json` when it finalizes a removal, but the per-instance files are
  // not its business to unlink, so they are still here. Anything else in the
  // directory is not ours and stays — which is also why the final `remove_dir`
  // can still fail, and that failure is the honest outcome.
  if @fs.path_exists(root) {
    @utils.discard(() => {
      for entry in @fs.read_dir(root) {
        let ours = entry == "project.json" ||
          (entry.has_prefix(name + "-") && entry.has_suffix(".json"))
        if ours {
          let path = if entry.has_prefix("/") {
            entry
          } else {
            root + "/" + entry
          }
          @utils.discard(() => @fs.remove_file(path))
        }
      }
    })
  }
  @utils.discard(() => @fs.remove_dir(root))
}

///|
/// Sweep the state directory for ownerless projects. A directory without a
/// `project.json` is a project nobody claims any more: it was retired
/// (`bm2 remove` keeps logs on purpose) or its project directory was deleted
/// without unregistering. The daemon's own files sit at the top level, so only
/// directories are considered, and a registered project is never touched — the
/// test is deliberately conservative, because deleting the logs of a project that
/// is still in service is the one mistake this command must not be able to make.
fn cmd_clean(state_dir : String, dry_run : Bool, lang : @i18n.Lang) -> Int32 {
  let entries = try @fs.read_dir(state_dir) catch {
    _ => return 0
  } noraise {
    found => found
  }
  let mut swept = 0
  for entry in entries {
    let root = state_dir + "/" + entry
    let is_dir = try @fs.is_dir(root) catch {
      _ => false
    } noraise {
      it => it
    }
    if !is_dir || @fs.path_exists(root + "/project.json") {
      continue
    }
    swept += 1
    if dry_run {
      println(@i18n.would_remove(lang, root))
    } else {
      purge_project(state_dir, entry)
      // `purge_project` only sweeps what bm2 writes. Anything else in there is
      // not ours, so the directory stays and the operator is told why.
      if @fs.path_exists(root) {
        @proc.eprintln(@i18n.left_in_place(lang, root))
      } else {
        println(@i18n.removed(lang, root))
      }
    }
  }
  println(@i18n.ownerless_summary(lang, swept, dry_run))
  0
}
