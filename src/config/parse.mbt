///|
let rootKeys : Array[String] = [
  "name", "cwd", "script", "runtime", "instances", "port", "max_memory_mb", "max_restarts",
  "restart_delay_ms", "min_uptime_ms", "stop_timeout_ms", "env",
]

///|
const DEFAULT_MAX_MEMORY_MB : Int = 512

///|
const DEFAULT_MAX_RESTARTS : Int = 10

///|
const DEFAULT_RESTART_DELAY_MS : Int = 1000

///|
const DEFAULT_MIN_UPTIME_MS : Int = 10000

///|
const DEFAULT_STOP_TIMEOUT_MS : Int = 10000

///|
/// Parse a bm2.toml document. `base_dir` is the config file's directory:
/// an omitted `cwd` defaults to it. The resulting config is validated.
pub fn parse(doc : String, base_dir : String) -> Config raise ConfigError {
  let value = @toml.parse(doc) catch {
    e => raise ConfigError::InvalidDocument(e.to_string())
  }
  guard value is @toml.TomlTable(table) else {
    raise ConfigError::InvalidDocument("bm2.toml root must be a table")
  }
  reject_unknown_keys(table, rootKeys, "root")
  let config : Config = {
    name: req_string(table, "name", "root"),
    cwd: opt_string(table, "cwd", "root", base_dir),
    script: req_string(table, "script", "root"),
    runtime: opt_string(table, "runtime", "root", "bun"),
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
    env: opt_env(table, "root"),
  }
  validate(config)
  config
}

///|
/// App variables are string-only and cannot shadow bm2 instance metadata.
fn opt_env(
  table : Map[String, @toml.TomlValue],
  ctx : String,
) -> Map[String, String] raise ConfigError {
  match table.get("env") {
    None => Map([])
    Some(@toml.TomlTable(values)) => {
      let env : Map[String, String] = Map([])
      for name, value in values {
        validate_env_name(name, ctx)
        match value {
          @toml.TomlString(text) => {
            // A NUL in the value would break the C-side envp blob layout.
            if text.contains("\u{0}") {
              raise ConfigError::InvalidField(
                "\{ctx}.env.\{name} must not contain NUL characters",
              )
            }
            env[name] = text
          }
          _ =>
            raise ConfigError::InvalidField(
              "\{ctx}.env.\{name} must be a string",
            )
        }
      }
      env
    }
    Some(_) => raise ConfigError::InvalidField("\{ctx}.env must be a table")
  }
}

///|
fn validate_env_name(name : String, ctx : String) -> Unit raise ConfigError {
  if name.is_empty() {
    raise ConfigError::InvalidField("\{ctx}.env has invalid variable name")
  }
  if name == "BM2_APP_NAME" ||
    name == "BM2_INSTANCE_ID" ||
    name == "BM2_APP_INSTANCE" ||
    name == "BM2_APP_PORT" ||
    name == "NODE_ENV" ||
    name == "PATH" ||
    name == "HOME" ||
    name == "TMPDIR" {
    raise ConfigError::InvalidField("\{ctx}.env.\{name} is reserved")
  }
  for i, c in name {
    guard (i == 0 && (c is ('A'..='Z') || c is ('a'..='z') || c == '_')) ||
      (
        i > 0 &&
        (c is ('A'..='Z') || c is ('a'..='z') || c is ('0'..='9') || c == '_')
      ) else {
      raise ConfigError::InvalidField(
        "\{ctx}.env has invalid variable name \{name}",
      )
    }
  }
}

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
  default : Int,
) -> Int raise ConfigError {
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
) -> Int raise ConfigError {
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
