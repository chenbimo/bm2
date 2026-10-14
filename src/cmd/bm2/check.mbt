///|
/// Cross-checks that go beyond parsing: the script must exist on disk,
/// otherwise `start` would fail later with a runtime error instead of a
/// config verdict. Returns the first problem found, None when usable.
fn check_project(
  config : @config.Config,
  path_exists : (String) -> Bool,
  lang : @i18n.Lang,
) -> String? {
  let script_path = config.cwd + "/" + config.script
  if !path_exists(script_path) {
    return Some(@i18n.check_script_missing(lang, script_path))
  }
  None
}

///|
/// One-paragraph human summary of an already validated config: identity,
/// instance layout, and a notify line with report/target/periodic counts.
fn check_summary(config : @config.Config, lang : @i18n.Lang) -> String {
  let buf = StringBuilder()
  buf.write_string(
    @i18n.check_ok(
      lang,
      config.name,
      config.instances,
      config.exec_mode,
      config.port,
      config.runtime,
    ),
  )
  if config.notify.enabled {
    let mut targets = 0
    let mut periodic = 0
    for report in config.notify.reports {
      targets += report.targets.length()
      if report.cron is Some(_) {
        periodic += 1
      }
    }
    buf.write_string(
      "\n" +
      @i18n.check_notify(
        lang,
        config.notify.reports.length(),
        targets,
        periodic,
      ),
    )
  } else {
    buf.write_string("\n" + @i18n.check_notify_disabled(lang))
  }
  // Pre-flight the listener ports: otherwise the first sign of a clash is the app
  // crashing on EADDRINUSE after a start. This project's own running instances
  // show up here too, which is why the wording stays neutral.
  let last_port = if config.exec_mode == "cluster" {
    config.port
  } else {
    config.port + config.instances - 1
  }
  let held = []
  for port in config.port..<(last_port + 1) {
    match @proc.probe_reuseport(port) {
      1 => held.push((port, "shared"))
      2 => held.push((port, "exclusive"))
      _ => ()
    }
  }
  if held.is_empty() {
    buf.write_string(
      "\n" + @i18n.check_ports_free(lang, config.port, last_port),
    )
  } else {
    for pair in held {
      let (port, kind) = pair
      buf.write_string(
        "\n" +
        @i18n.check_port_held(lang, port, @i18n.port_holder_kind(lang, kind)),
      )
    }
  }
  buf.to_string()
}

///|
/// `bm2 check`: validate the bm2.toml in the current directory without
/// touching the daemon, so a bad config is caught before a deploy. Purely
/// local: parsing, field validation and ${VAR} expansion all run in-process
/// via @config.load, then the filesystem gets the final word.
fn cmd_check(lang : @i18n.Lang) -> Int32 {
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => {
      @proc.eprintln("bm2: " + @i18n.cannot_determine_cwd(lang))
      return 1
    }
  }
  let config = try @config.load(cwd + "/bm2.toml") catch {
    e => {
      @proc.eprintln("bm2: " + e.to_string())
      return 1
    }
  } noraise {
    c => c
  }
  // A config verdict is a verdict about this project, so the project's own language
  // wins over the terminal's. Without one, the operator's stands.
  let lang = match config.lang {
    Some(configured) => configured
    None => lang
  }
  match check_project(config, @fs.path_exists, lang) {
    Some(problem) => {
      @proc.eprintln("bm2: " + problem)
      return 1
    }
    None => ()
  }
  // A dev start reads a different set of .env files, so a verdict from the
  // production view alone would not be a verdict: a project that passes as
  // production can still fail as development.
  try
    ignore(@config.load(cwd + "/bm2.toml", mode=@config.Mode::Development))
  catch {
    e => {
      @proc.eprintln("bm2: " + e.to_string())
      return 1
    }
  } noraise {
    _ => ()
  }
  println(check_summary(config, lang))
  0
}
