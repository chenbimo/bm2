///|
/// Environment placeholders in bm2.toml string values: `__NAME__`.
///
/// The marker lives inside a string because that is the only place TOML lets
/// arbitrary text live. An unquoted `__NAME__` — like an unquoted `${NAME}` — is
/// not a TOML value at all, so the file stops parsing and every editor, linter
/// and highlighter says so. A config file has to be TOML first and bm2's config
/// second.
///
/// Two underscores on each side is a shape that essentially never occurs by
/// accident. `$` is the opposite: it is common in URLs and passwords, so a stray
/// brace in a credential could be mistaken for a placeholder.
///
/// Expansion runs over the *parsed* string values, once, before field
/// extraction. Parsing first is what keeps it honest: a comment mentioning
/// `__PORT__` is not a string value and is never touched, and nothing this pass
/// does can turn a valid document into an invalid one. A placeholder with no
/// closing `__` is left as written — `a__b` is text, not a mistake — and an
/// unknown variable is a hard error naming it, never a silent empty value.

///|
/// Expand `__NAME__` against the environment. `ctx` is the config path of the
/// value being expanded, so an error can say where it came from.
pub fn expand_with(
  value : String,
  ctx : String,
  lookup : (String) -> String?,
) -> String raise ConfigError {
  if !value.contains("__") {
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
    if chars[i] == '_' && i + 1 < n && chars[i + 1] == '_' {
      // Read until the closing pair; a name may contain single underscores.
      let name = StringBuilder()
      let mut j = i + 2
      let mut closed = false
      while j + 1 < n {
        if chars[j] == '_' && chars[j + 1] == '_' {
          closed = true
          break
        }
        name.write_char(chars[j])
        j += 1
      }
      if !closed {
        // No closing pair: this is text that happens to contain underscores.
        buf.write_char(chars[i])
        i += 1
        continue
      }
      let var_name = name.to_string()
      if !valid_env_name(var_name) {
        raise ConfigError::InvalidField(
          "\{ctx} has an invalid environment variable name",
        )
      }
      match lookup(var_name) {
        Some(found) => buf.write_string(found)
        None =>
          raise ConfigError::InvalidField(
            "\{ctx} references environment variable \{var_name} which is not set",
          )
      }
      i = j + 2
    } else {
      buf.write_char(chars[i])
      i += 1
    }
  }
  buf.to_string()
}

///|
/// Recursively expand `__NAME__` across a parsed TOML tree: every string value,
/// at any depth, in any table. Done once before field extraction, so no field
/// ever needs to know that expansion exists.
///
/// Where a value comes from is the caller's decision, passed in as `lookup`: the
/// config loader resolves against the project's own `.env` files first and the
/// process environment second.
pub fn expand_toml_tree(
  value : @toml.TomlValue,
  path : String,
  lookup : (String) -> String?,
) -> @toml.TomlValue raise ConfigError {
  match value {
    @toml.TomlString(text) => @toml.TomlString(expand_with(text, path, lookup))
    @toml.TomlArray(items) => {
      let out : Array[@toml.TomlValue] = []
      for i, item in items {
        out.push(expand_toml_tree(item, "\{path}[\{i}]", lookup))
      }
      @toml.TomlArray(out)
    }
    @toml.TomlTable(section) => {
      let out : Map[String, @toml.TomlValue] = Map([])
      for pair in section.iter() {
        let (key, item) = pair
        let child_path = if path == "" { key } else { "\{path}.\{key}" }
        out[key] = expand_toml_tree(item, child_path, lookup)
      }
      @toml.TomlTable(out)
    }
    other => other
  }
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
