///|
/// Read, parse and validate the bm2.toml at path. Read failures are
/// reported as InvalidDocument so callers deal with ConfigError only.
pub fn load(path : String) -> Config raise ConfigError {
  let doc = try @fs.read_file_to_string(path) catch {
    _ => raise InvalidDocument("cannot read config file: " + path)
  } noraise {
    text => text
  }
  let config = parse(doc)
  validate(config)
  config
}
