///|
/// The `[env]` table: application environment injected into every instance.
/// Values must be strings; keys follow environment-variable naming. bun and
/// node never let a .env file override an existing variable, so these values
/// beat whatever a project ships in its own env files.
fn opt_env(
  table : Map[String, @toml.TomlValue],
) -> Array[(String, String)] raise ConfigError {
  match table.get("env") {
    None => []
    Some(@toml.TomlTable(section)) => {
      let entries : Array[(String, String)] = []
      for pair in section.iter() {
        let (key, value) = pair
        guard value is @toml.TomlString(text) else {
          raise ConfigError::InvalidField("env.\{key} must be a string")
        }
        guard valid_env_name(key) else {
          raise ConfigError::InvalidField(
            "env.\{key} has an invalid variable name",
          )
        }
        entries.push((key, text))
      }
      entries
    }
    Some(_) => raise ConfigError::InvalidField("env must be a table")
  }
}

///|
let rootKeys : Array[String] = [
  "name", "cwd", "script", "runtime", "exec_mode", "instances", "port", "max_memory_mb",
  "max_restarts", "restart_delay_ms", "min_uptime_ms", "stop_timeout_ms", "notify",
  "logs", "env",
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
/// Parse a bm2.toml document. `base_dir` is the config file's directory:
/// an omitted `cwd` defaults to it. The resulting config is validated.
pub fn parse(doc : String, base_dir : String) -> Config raise ConfigError {
  let value = @toml.parse(doc) catch {
    e => raise ConfigError::InvalidDocument(e.to_string())
  }
  let value = expand_toml_tree(value, "")
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
    instances: req_int(table, "instances", "root"),
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
    notify: opt_notify(table),
    logs: opt_logs(table),
    env: opt_env(table),
  }
  validate(config)
  config
}

///|
/// The `[notify]` table is optional: a project without one simply reports
/// nothing.
fn opt_notify(
  table : Map[String, @toml.TomlValue],
) -> NotifyConfig raise ConfigError {
  match table.get("notify") {
    None => NotifyConfig::disabled()
    Some(@toml.TomlTable(section)) => parse_notify_section(section)
    Some(_) => raise ConfigError::InvalidField("notify must be a table")
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
    Some(_) =>
      raise ConfigError::InvalidField("\{ctx}.\{key} must be an integer")
    None => raise ConfigError::InvalidField("\{ctx}.\{key} is required")
  }
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
