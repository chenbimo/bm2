///|
pub fn validate(config : Config) -> Unit raise ConfigError {
  if config.name.is_empty() {
    raise ConfigError::InvalidField("name must not be empty")
  }
  // Project name: letter first, then letters/digits/underscores only.
  // It doubles as the directory name under the state dir, so no other
  // characters are allowed.
  for i, c in config.name {
    guard (i == 0 && (c is ('A'..='Z') || c is ('a'..='z'))) ||
      (
        i > 0 &&
        (c is ('A'..='Z') || c is ('a'..='z') || c is ('0'..='9') || c == '_')
      ) else {
      raise ConfigError::InvalidField(
        "project \{config.name} has invalid name: letter first, then letters, digits and underscores only",
      )
    }
  }
  if !config.cwd.has_prefix("/") {
    raise ConfigError::InvalidField(
      "project \{config.name}: cwd must be an absolute path",
    )
  }
  validate_script(config)
  if config.runtime != "bun" && config.runtime != "node" {
    raise ConfigError::InvalidField(
      "project \{config.name}: runtime must be \"bun\" or \"node\"",
    )
  }
  if config.instances < 1 || config.instances > 1024 {
    raise ConfigError::InvalidField(
      "project \{config.name}: instances must be between 1 and 1024",
    )
  }
  if config.base_port < 1 || config.base_port + config.instances - 1 > 65535 {
    raise ConfigError::InvalidField(
      "project \{config.name}: port range \{config.base_port} ~ \{config.base_port + config.instances - 1} is out of 1 ~ 65535",
    )
  }
  if config.max_memory_mb < 1 {
    raise ConfigError::InvalidField(
      "project \{config.name}: max_memory_mb must be at least 1",
    )
  }
  // max_restarts/restart_delay_ms/min_uptime_ms are guaranteed >= 0 by the
  // parser's range check (0 ..= 2^31-1), so no negative checks are needed.
  // stop_timeout_ms is bounded so CLI request timeouts and daemon settle
  // waits never grow to pathological durations.
  if config.stop_timeout_ms < 1 || config.stop_timeout_ms > 60000 {
    raise ConfigError::InvalidField(
      "project \{config.name}: stop_timeout_ms must be between 1 and 60000",
    )
  }
}

///|
fn validate_script(config : Config) -> Unit raise ConfigError {
  let script = config.script
  if script.is_empty() || script.has_prefix("/") {
    raise ConfigError::InvalidField(
      "project \{config.name}: script must be a relative path inside cwd",
    )
  }
  for seg in script.split("/") {
    if seg == ".." {
      raise ConfigError::InvalidField(
        "project \{config.name}: script must not contain '..' segments",
      )
    }
  }
}
