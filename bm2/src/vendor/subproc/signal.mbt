///|
pub const SIGTERM : Int32 = 15

///|
pub const SIGKILL : Int32 = 9

///|
pub fn kill_group(pgid : Int32, sig : Int32) -> Unit raise ProcessError {
  let rc = c_kill_pg(pgid, sig)
  if rc < 0 {
    raise Failed(op="kill_group", errno=-rc)
  }
}

///|
/// kill(pid, 0): true when the pid exists and we may signal it.
pub fn pid_alive(pid : Int32) -> Bool {
  c_kill0(pid) == 0
}
