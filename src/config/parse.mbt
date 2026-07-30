///|
let rootKeys : Array[String] = ["apps"]

///|
let appKeys : Array[String] = [
  "name", "cwd", "script", "instances", "base_port", "max_memory_mb", "max_restarts",
  "restart_delay_ms", "min_uptime_ms", "stop_timeout_ms",
]

///|
pub fn parse(doc : String) -> Config raise ConfigError {
  let value = @toml.parse(doc) catch {
    e => raise ConfigError::InvalidDocument(e.to_string())
  }
  guard value is @toml.TomlTable(root) else {
    raise ConfigError::InvalidDocument("bm2.toml root must be a table")
  }
  reject_unknown_keys(root, rootKeys, "root")
  guard root.get("apps") is Some(@toml.TomlArray(app_values)) else {
    raise ConfigError::InvalidField("apps is required and must be an array")
  }
  if app_values.is_empty() {
    raise ConfigError::InvalidField("apps must contain at least one app")
  }
  let apps : Array[AppConfig] = []
  for i, app_value in app_values {
    apps.push(parse_app(app_value, i))
  }
  let config = { apps, }
  validate(config)
  config
}

///|
fn parse_app(
  value : @toml.TomlValue,
  index : Int,
) -> AppConfig raise ConfigError {
  let ctx = "apps[\{index}]"
  guard value is @toml.TomlTable(table) else {
    raise ConfigError::InvalidField("\{ctx} must be a table")
  }
  reject_unknown_keys(table, appKeys, ctx)
  {
    name: req_string(table, "name", ctx),
    cwd: req_string(table, "cwd", ctx),
    script: req_string(table, "script", ctx),
    instances: req_int(table, "instances", ctx),
    base_port: req_int(table, "base_port", ctx),
    max_memory_mb: req_int(table, "max_memory_mb", ctx),
    max_restarts: req_int(table, "max_restarts", ctx),
    restart_delay_ms: req_int(table, "restart_delay_ms", ctx),
    min_uptime_ms: req_int(table, "min_uptime_ms", ctx),
    stop_timeout_ms: req_int(table, "stop_timeout_ms", ctx),
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
