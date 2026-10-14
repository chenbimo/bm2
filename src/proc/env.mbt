///|
let whitelist : Array[String] = ["PATH", "HOME", "TMPDIR"]

///|
/// Minimal instance environment: whitelisted vars from the daemon's own
/// environment, the project's own scanned vars, then the reserved app vars —
/// encoded as a NUL-separated "KEY=VALUE" blob with a trailing extra NUL for
/// spawn. Reserved vars are written last, so nothing can override them.
///
/// NODE_ENV is reserved rather than the application's to set: `bm2 serve` and
/// `bm2 dev` mean production and development, and the config loader has already
/// refused any `.env` file that claims otherwise. The value is passed in as a
/// string so this layer stays free of config types.
pub fn instance_env_blob(
  app_name : String,
  instance_id : Int32,
  port : Int32,
  node_env~ : String,
  extra~ : Array[(String, String)] = [],
) -> Bytes {
  let reserved = [
    ("BM2_APP_NAME", app_name),
    ("BM2_INSTANCE_ID", instance_id.to_string()),
    ("BM2_APP_INSTANCE", instance_id.to_string()),
    ("BM2_APP_PORT", port.to_string()),
    ("NODE_ENV", node_env),
  ]
  build_blob(reserved, extra~)
}

///|
/// Whitelisted environment only; used to launch helper processes. BM2_*
/// passes through so notification credentials exported in the caller's
/// shell reach the daemon's ${VAR} expansion.
pub fn base_env_blob() -> Bytes {
  build_blob([])
}

///|
/// Whitelisted vars plus every BM2_* var from the given environment.
fn select_entries(vars : Map[String, String]) -> Array[(String, String)] {
  let selected : Array[(String, String)] = []
  for name in whitelist {
    match vars.get(name) {
      Some(value) => selected.push((name, value))
      None => ()
    }
  }
  for pair in vars.iter() {
    let (name, value) = pair
    if name.has_prefix("BM2_") {
      selected.push((name, value))
    }
  }
  selected
}

///|
fn build_blob(
  reserved : Array[(String, String)],
  extra~ : Array[(String, String)] = [],
) -> Bytes {
  let buf = StringBuilder()
  for entry in select_entries(@env.get_env_vars()) {
    let (name, value) = entry
    write_entry(buf, name, value)
  }
  for entry in extra {
    let (name, value) = entry
    write_entry(buf, name, value)
  }
  for entry in reserved {
    let (name, value) = entry
    write_entry(buf, name, value)
  }
  buf.write_char('\u{0}')
  @utf8.encode(buf.to_string())
}

///|
fn write_entry(buf : StringBuilder, name : String, value : String) -> Unit {
  buf.write_string(name)
  buf.write_char('=')
  buf.write_string(value)
  buf.write_char('\u{0}')
}
