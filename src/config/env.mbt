///|
/// `${VAR}` expansion for the notification credential fields: a bm2.toml that
/// goes into a repository carries placeholders, the real endpoint and secret
/// live in the environment of whichever process parses the config (the CLI
/// for `bm2 start` / `bm2 notify`, the daemon for supervised reporting).
/// Only [notify] goes through this — script paths and ports have no business
/// depending on the shell.

///|
/// Expand `${VAR}` references against the process environment. A variable
/// that is not set is a hard error naming the variable, never a silent empty
/// value — an empty URL must not turn into a delivery attempt.
pub fn expand_env(value : String, ctx : String) -> String raise ConfigError {
  expand_with(value, ctx, fn(name) { @env.get_env_var(name) })
}

///|
/// The expansion itself, with the environment lookup injected so tests can
/// drive it without touching the real process environment.
pub fn expand_with(
  value : String,
  ctx : String,
  lookup : (String) -> String?,
) -> String raise ConfigError {
  if !value.contains("${") {
    return value
  }
  let chars : Array[Char] = []
  for c in value {
    chars.push(c)
  }
  let n = chars.length()
  let buf = StringBuilder()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == '$' && i + 1 < n && chars[i + 1] == '{' {
      let name = StringBuilder()
      let mut j = i + 2
      let mut closed = false
      while j < n {
        let nc = chars[j]
        if nc == '}' {
          closed = true
          break
        }
        name.write_char(nc)
        j += 1
      }
      if !closed {
        raise ConfigError::InvalidField(
          "\{ctx} has an unterminated ${ reference",
        )
      }
      let var_name = name.to_string()
      if !valid_env_name(var_name) {
        raise ConfigError::InvalidField(
          "\{ctx} has an invalid environment variable name",
        )
      }
      match lookup(var_name) {
        Some(v) => buf.write_string(v)
        None =>
          raise ConfigError::InvalidField(
            "\{ctx} references environment variable \{var_name} which is not set",
          )
      }
      i = j + 1
    } else {
      buf.write_char(c)
      i += 1
    }
  }
  buf.to_string()
}

///|
/// Environment variable names: letters, digits and underscores, not starting
/// with a digit. Anything else is a config mistake, not a lookup miss.
fn valid_env_name(name : String) -> Bool {
  if name.is_empty() {
    return false
  }
  for index, c in name {
    let v = c.to_int()
    let letter = (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95
    let ok = if index == 0 { letter } else { letter || (v >= 48 && v <= 57) }
    if !ok {
      return false
    }
  }
  true
}

///|
/// Recursively expand ${VAR} across an entire parsed TOML tree: every
/// string value, at any depth, in any table. Done once before field
/// extraction, so no field ever needs to know about expansion.
pub fn expand_toml_tree(
  value : @toml.TomlValue,
  path : String,
) -> @toml.TomlValue raise ConfigError {
  match value {
    @toml.TomlString(text) => @toml.TomlString(expand_env(text, path))
    @toml.TomlArray(items) => {
      let out : Array[@toml.TomlValue] = []
      for i, item in items {
        out.push(expand_toml_tree(item, "\{path}[\{i}]"))
      }
      @toml.TomlArray(out)
    }
    @toml.TomlTable(section) => {
      let out : Map[String, @toml.TomlValue] = Map([])
      for pair in section.iter() {
        let (key, item) = pair
        let child_path = if path == "" { key } else { "\{path}.\{key}" }
        out[key] = expand_toml_tree(item, child_path)
      }
      @toml.TomlTable(out)
    }
    other => other
  }
}
