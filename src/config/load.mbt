///|
/// Read, parse and validate the bm2.toml at path. Read failures are
/// reported as InvalidDocument so callers deal with ConfigError only.
/// An omitted `cwd` defaults to the config file's directory, and the
/// project's `.env` files are looked up beside it. `mode` decides which of
/// those files load: `serve` means production and `dev` means development, so
/// production is what a caller that says nothing about mode gets.
pub fn load(
  path : String,
  mode~ : Mode = Production,
) -> Config raise ConfigError {
  let doc = try @fs.read_file_to_string(path) catch {
    _ => raise InvalidDocument("cannot read config file: " + path)
  } noraise {
    text => text
  }
  let mut last_slash = -1
  for i, c in path {
    if c == '/' {
      last_slash = i
    }
  }
  let base_dir = if last_slash >= 0 {
    path[:last_slash].to_owned()
  } else {
    "."
  }
  // parse validates the config before returning, so no second pass here.
  parse(doc, base_dir, mode~)
}
