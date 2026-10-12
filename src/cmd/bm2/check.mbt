///|
/// Cross-checks that go beyond parsing: the script must exist on disk,
/// otherwise `start` would fail later with a runtime error instead of a
/// config verdict. Returns the first problem found, None when usable.
fn check_project(
  config : @config.Config,
  path_exists : (String) -> Bool,
) -> String? {
  let script_path = config.cwd + "/" + config.script
  if !path_exists(script_path) {
    return Some("script not found: \{script_path}")
  }
  None
}

///|
/// One-paragraph human summary of an already validated config: identity,
/// instance layout, and a notify line with report/target/periodic counts.
fn check_summary(config : @config.Config) -> String {
  let buf = StringBuilder()
  buf.write_string(
    "config ok: project \"\{config.name}\", \{config.instances} x \{config.exec_mode} on port \{config.port}, runtime \{config.runtime}",
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
      "\nnotify: \{config.notify.reports.length()} report(s), \{targets} target(s), \{periodic} periodic",
    )
  } else {
    buf.write_string("\nnotify: disabled")
  }
  buf.to_string()
}

///|
/// `bm2 check`: validate the bm2.toml in the current directory without
/// touching the daemon, so a bad config is caught before a deploy. Purely
/// local: parsing, field validation and ${VAR} expansion all run in-process
/// via @config.load, then the filesystem gets the final word.
fn cmd_check() -> Int32 {
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => {
      @proc.eprintln("bm2: cannot determine current directory")
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
  match check_project(config, @fs.path_exists) {
    Some(problem) => {
      @proc.eprintln("bm2: " + problem)
      return 1
    }
    None => ()
  }
  println(check_summary(config))
  0
}
