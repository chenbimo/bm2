///|
pub(all) struct SpawnSpec {
  bun_path : String
  script : String
  cwd : String
  out_log : String
  err_log : String
  env_blob : Bytes
} derive(Debug)

///|
pub fn spawn(spec : SpawnSpec) -> Int raise ProcessError {
  let pid = c_spawn(
    cstr(spec.bun_path),
    cstr(spec.script),
    cstr(spec.cwd),
    cstr(spec.out_log),
    cstr(spec.err_log),
    spec.env_blob,
  )
  if pid < 0 {
    raise Failed(op="spawn", errno=-pid)
  }
  pid
}

///|
pub fn get_pid() -> Int {
  c_getpid()
}

///|
pub fn sleep_ms(ms : Int) -> Unit {
  c_sleep_ms(ms)
}
