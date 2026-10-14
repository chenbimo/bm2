///|
/// The instance count that will actually run: development is always one.
///
/// A development session is one process on one port, so the configured count is
/// not honored there. It is not dropped silently either — the mode is part of the
/// project's identity, and `bm2 list --json` reports both the mode and the
/// instance count that came out of it. The port range the config has to stay
/// inside is checked against this number rather than the written one, because
/// this is the layout that will exist.
fn effective_instances(configured : Int32, mode : Mode) -> Int32 {
  match mode {
    Development => 1
    Production => configured
  }
}

///|
/// The scanned project environment, as the key/value array the injector takes.
/// Injection only cares which keys exist; keys have no order dependency.
fn env_entries(vars : Map[String, String]) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for pair in vars.iter() {
    out.push(pair)
  }
  out
}

///|
let rootKeys : Array[String] = [
  "name", "cwd", "script", "runtime", "exec_mode", "instances", "port", "max_memory_mb",
  "max_restarts", "restart_delay_ms", "min_uptime_ms", "stop_timeout_ms", "notify",
  "logs", "lang",
]

///|
const DEFAULT_MAX_MEMORY_MB : Int32 = 512

///|
const DEFAULT_MAX_RESTARTS : Int32 = 10

///|
const DEFAULT_RESTART_DELAY_MS : Int32 = 1000

///|
const DEFAULT_MIN_UPTIME_MS : Int32 = 10000

///|
const DEFAULT_STOP_TIMEOUT_MS : Int32 = 10000

///|
/// A log rotates once it exceeds this size in megabytes. Ten is what the daemon
/// has always used; `[logs] max_size_mb` changes it per project.
const DEFAULT_LOG_MAX_SIZE_MB : Int32 = 10

///|
/// Generations kept by default: zero, meaning none are ever dropped — the
/// operator decides when disk usage has to stop, and `[logs] keep` is the place
/// to say so.
const DEFAULT_LOG_KEEP : Int32 = 0

///|
/// Parse a bm2.toml document. `base_dir` is the config file's directory: an
/// omitted `cwd` defaults to it, and the project's `.env` files are looked up
/// beside it.
///
/// `mode` decides which mode-specific env files load. `serve` means production
/// and `dev` means development — the same action with a different environment —
/// so production is what a plain service start assumes.
pub fn parse(
  doc : String,
  base_dir : String,
  mode~ : Mode = Production,
) -> Config raise ConfigError {
  // Scanned first: this one map feeds both the injection into instances and the
  // ${VAR} expansion below, so an application and the manager that supervises it
  // can never read different values for the same name.
  let vars = scan_env_files(base_dir, mode)
  // NODE_ENV belongs to the reserved set: bm2 decides it from the mode. A file
  // may restate the same value (most `.env.production` files do) but not
  // contradict it — otherwise "which environment am I in?" would depend on which
  // file happened to be read last.
  match vars.get("NODE_ENV") {
    Some(found) if found != mode.as_string() =>
      raise ConfigError::InvalidField(
        "NODE_ENV is \{mode.as_string()} in this mode, but a .env file sets \{found}",
      )
    _ => ()
  }
  let value = @toml.parse(doc) catch {
    e => raise ConfigError::InvalidDocument(e.to_string())
  }
  // Project environment first, process environment as the fallback: an operator
  // can still override one value for a single run without editing a file. This
  // runs over the parsed string values, so a placeholder can never make the
  // document itself unparseable.
  let value = expand_toml_tree(value, "", fn(name) {
    match vars.get(name) {
      Some(found) => Some(found)
      None => @env.get_env_var(name)
    }
  })
  guard value is @toml.TomlTable(table) else {
    raise ConfigError::InvalidDocument("bm2.toml root must be a table")
  }
  reject_unknown_keys(table, rootKeys, "root")
  let config : Config = {
    name: req_string(table, "name", "root"),
    cwd: opt_string(table, "cwd", "root", base_dir),
    script: req_string(table, "script", "root"),
    runtime: opt_string(table, "runtime", "root", "bun"),
    exec_mode: opt_string(table, "exec_mode", "root", "cluster"),
    instances: effective_instances(req_int(table, "instances", "root"), mode),
    port: req_int(table, "port", "root"),
    max_memory_mb: opt_int(
      table,
      "max_memory_mb",
      "root",
      DEFAULT_MAX_MEMORY_MB,
    ),
    max_restarts: opt_int(table, "max_restarts", "root", DEFAULT_MAX_RESTARTS),
    restart_delay_ms: opt_int(
      table,
      "restart_delay_ms",
      "root",
      DEFAULT_RESTART_DELAY_MS,
    ),
    min_uptime_ms: opt_int(
      table,
      "min_uptime_ms",
      "root",
      DEFAULT_MIN_UPTIME_MS,
    ),
    stop_timeout_ms: opt_int(
      table,
      "stop_timeout_ms",
      "root",
      DEFAULT_STOP_TIMEOUT_MS,
    ),
    notify: opt_notify(table, default_lang=project_lang_name(table)),
    logs: opt_logs(table),
    mode,
    lang: opt_project_lang(table),
    env: env_entries(vars),
  }
  validate(config)
  config
}

///|
/// The `[notify]` table is optional: a project without one simply reports
/// nothing.
fn opt_notify(
  table : Map[String, @toml.TomlValue],
  default_lang~ : String,
) -> NotifyConfig raise ConfigError {
  match table.get("notify") {
    None => NotifyConfig::disabled()
    Some(@toml.TomlTable(section)) =>
      parse_notify_section(section, default_lang~)
    Some(_) => raise ConfigError::InvalidField("notify must be a table")
  }
}

///|
/// The language notification copy defaults to: the project's `lang`. Notices are
/// part of the project's voice, so a project that says `lang = "zh"` gets Chinese
/// notices; `[notify] lang` can still name a different one for the chat group.
fn project_lang_name(
  table : Map[String, @toml.TomlValue],
) -> String raise ConfigError {
  match opt_project_lang(table) {
    Some(lang) => lang.name()
    None => "en"
  }
}

///|
/// The `[logs]` table is optional: without one a project rotates at the built-in
/// size and keeps every generation.
fn opt_logs(
  table : Map[String, @toml.TomlValue],
) -> LogsConfig raise ConfigError {
  match table.get("logs") {
    None => LogsConfig::builtin()
    Some(@toml.TomlTable(section)) => {
      reject_unknown_keys(section, logKeys, "logs")
      {
        max_size_mb: opt_int(
          section,
          "max_size_mb",
          "logs",
          DEFAULT_LOG_MAX_SIZE_MB,
        ),
        keep: opt_int(section, "keep", "logs", DEFAULT_LOG_KEEP),
      }
    }
    Some(_) => raise ConfigError::InvalidField("logs must be a table")
  }
}

///|
let logKeys : Array[String] = ["max_size_mb", "keep"]

///|
fn req_string(
  table : Map[String, @toml.TomlValue],
  key : String,
  ctx : String,
) -> String raise ConfigError {
  match table.get(key) {
    Some(@toml.TomlString(value)) => value
    Some(_) => raise ConfigError::InvalidField("\{ctx}.\{key} must be a string")
    None => raise ConfigError::InvalidField("\{ctx}.\{key} is required")
  }
}

///|
fn opt_string(
  table : Map[String, @toml.TomlValue],
  key : String,
  ctx : String,
  default : String,
) -> String raise ConfigError {
  match table.get(key) {
    None => default
    Some(@toml.TomlString(value)) => value
    Some(_) => raise ConfigError::InvalidField("\{ctx}.\{key} must be a string")
  }
}

///|
fn opt_int(
  table : Map[String, @toml.TomlValue],
  key : String,
  ctx : String,
  default : Int32,
) -> Int32 raise ConfigError {
  match table.get(key) {
    None => default
    Some(_) => req_int(table, key, ctx)
  }
}

///|
/// An integer field. A quoted string is accepted when it *is* an integer, and
/// that is the only way a value from the environment can get here: `${VAR}`
/// expansion runs over strings, and TOML has no unquoted placeholder spelling,
/// so `port = "${APP_PORT}"` arrives as the string "3000". Rejecting it would
/// mean ports and limits could never come from a `.env` file.
fn req_int(
  table : Map[String, @toml.TomlValue],
  key : String,
  ctx : String,
) -> Int32 raise ConfigError {
  match table.get(key) {
    Some(@toml.TomlInteger(value)) => {
      guard value >= 0L && value <= 2147483647L else {
        raise ConfigError::InvalidField("\{ctx}.\{key} is out of range")
      }
      value.to_int()
    }
    Some(@toml.TomlString(text)) => parse_int_text(text, key, ctx)
    Some(_) =>
      raise ConfigError::InvalidField("\{ctx}.\{key} must be an integer")
    None => raise ConfigError::InvalidField("\{ctx}.\{key} is required")
  }
}

///|
/// The project's language, when it states one. An unknown name is refused rather
/// than downgraded to English: a config that asks for a language bm2 does not
/// speak is a mistake the operator wants to hear about.
fn opt_project_lang(
  table : Map[String, @toml.TomlValue],
) -> @i18n.Lang? raise ConfigError {
  match opt_string_opt(table, "lang", "root") {
    None => None
    Some(name) =>
      match @i18n.Lang::from_name(name) {
        Some(lang) => Some(lang)
        None =>
          raise ConfigError::InvalidField("root.lang is not supported: \{name}")
      }
  }
}

///|
/// A string that has to spell a non-negative integer. Whitespace is not
/// trimmed: a value with a stray space was written by hand, and guessing at it
/// would hide the typo instead of showing it.
fn parse_int_text(
  text : String,
  key : String,
  ctx : String,
) -> Int32 raise ConfigError {
  guard text.length() > 0 else {
    raise ConfigError::InvalidField("\{ctx}.\{key} must be an integer")
  }
  let mut value : Int64 = 0L
  for code in text {
    guard code >= '0' && code <= '9' else {
      raise ConfigError::InvalidField(
        "\{ctx}.\{key} must be an integer, but is \"\{text}\"",
      )
    }
    value = value * 10L + (code.to_int() - '0'.to_int()).to_int64()
    guard value <= 2147483647L else {
      raise ConfigError::InvalidField("\{ctx}.\{key} is out of range")
    }
  }
  value.to_int()
}

///|
fn reject_unknown_keys(
  table : Map[String, @toml.TomlValue],
  allowed : Array[String],
  ctx : String,
) -> Unit raise ConfigError {
  for key, _ in table {
    if !allowed.contains(key) {
      raise ConfigError::InvalidField("\{ctx} has unknown field \{key}")
    }
  }
}
