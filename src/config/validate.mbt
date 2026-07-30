///|
pub fn validate(config : Config) -> Unit raise ConfigError {
  for app in config.apps {
    validate_app(app)
  }
  reject_duplicate_names(config.apps)
  reject_port_overlap(config.apps)
}

///|
fn validate_app(app : AppConfig) -> Unit raise ConfigError {
  if app.name.is_empty() {
    raise ConfigError::InvalidField("app name must not be empty")
  }
  for c in app.name {
    guard c is ('a'..='z') || c is ('0'..='9') || c == '-' else {
      raise ConfigError::InvalidField(
        "app \{app.name} has invalid name: only lowercase letters, digits and hyphens are allowed",
      )
    }
  }
  if !app.cwd.has_prefix("/") {
    raise ConfigError::InvalidField(
      "app \{app.name}: cwd must be an absolute path",
    )
  }
  validate_script(app)
  if app.instances < 1 {
    raise ConfigError::InvalidField(
      "app \{app.name}: instances must be at least 1",
    )
  }
  if app.base_port < 1 || app.base_port + app.instances - 1 > 65535 {
    raise ConfigError::InvalidField(
      "app \{app.name}: port range \{app.base_port} ~ \{app.base_port + app.instances - 1} is out of 1 ~ 65535",
    )
  }
  if app.max_memory_mb < 1 {
    raise ConfigError::InvalidField(
      "app \{app.name}: max_memory_mb must be at least 1",
    )
  }
  if app.max_restarts < 0 {
    raise ConfigError::InvalidField(
      "app \{app.name}: max_restarts must not be negative",
    )
  }
  if app.restart_delay_ms < 0 {
    raise ConfigError::InvalidField(
      "app \{app.name}: restart_delay_ms must not be negative",
    )
  }
  if app.min_uptime_ms < 0 {
    raise ConfigError::InvalidField(
      "app \{app.name}: min_uptime_ms must not be negative",
    )
  }
  if app.stop_timeout_ms < 1 {
    raise ConfigError::InvalidField(
      "app \{app.name}: stop_timeout_ms must be at least 1",
    )
  }
}

///|
fn validate_script(app : AppConfig) -> Unit raise ConfigError {
  let script = app.script
  if script.is_empty() || script.has_prefix("/") {
    raise ConfigError::InvalidField(
      "app \{app.name}: script must be a relative path inside cwd",
    )
  }
  for seg in script.split("/") {
    if seg == ".." {
      raise ConfigError::InvalidField(
        "app \{app.name}: script must not contain '..' segments",
      )
    }
  }
}

///|
fn reject_duplicate_names(apps : Array[AppConfig]) -> Unit raise ConfigError {
  for i, app in apps {
    for j in (i + 1)..<apps.length() {
      if apps[j].name == app.name {
        raise ConfigError::InvalidField("duplicate app name \{app.name}")
      }
    }
  }
}

///|
fn reject_port_overlap(apps : Array[AppConfig]) -> Unit raise ConfigError {
  let ranges : Array[(Int, Int, String)] = apps.map(fn(app) {
    (app.base_port, app.base_port + app.instances - 1, app.name)
  })
  ranges.sort_by(fn(a, b) { a.0.compare(b.0) })
  for i in 1..<ranges.length() {
    let (start, _, name) = ranges[i]
    let (_, prev_end, prev_name) = ranges[i - 1]
    if start <= prev_end {
      raise ConfigError::InvalidField(
        "app \{prev_name} and \{name} have overlapping port ranges",
      )
    }
  }
}
