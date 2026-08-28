///|
let whitelist : Array[String] = ["PATH", "HOME", "TMPDIR"]

///|
/// Minimal instance environment: whitelisted vars from bm2d's own
/// environment plus the reserved bm2 vars, encoded as a NUL-separated
/// "KEY=VALUE" blob with a trailing extra NUL for bm2_spawn. Reserved
/// vars are written last, so nothing can override them.
pub fn instance_env_blob(
  app_name : String,
  instance_id : Int,
  port : Int,
) -> Bytes {
  let reserved = [
    ("BM2_APP_NAME", app_name),
    ("BM2_INSTANCE_ID", instance_id.to_string()),
    ("BM2_APP_INSTANCE", instance_id.to_string()),
    ("BM2_APP_PORT", port.to_string()),
    ("NODE_ENV", "production"),
  ]
  build_blob(reserved)
}

///|
/// Whitelisted environment only; used to launch bm2d itself.
pub fn base_env_blob() -> Bytes {
  build_blob([])
}

///|
fn build_blob(reserved : Array[(String, String)]) -> Bytes {
  let buf = StringBuilder::new()
  let vars = @env.get_env_vars()
  for name in whitelist {
    match vars.get(name) {
      Some(value) => write_entry(buf, name, value)
      None => ()
    }
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
