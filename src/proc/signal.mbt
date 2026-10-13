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

///|
/// Signal one pid. The group signal cannot reach a child that has not called
/// setsid() yet, while its pid exists from the moment it is forked.
pub fn kill(pid : Int32, sig : Int32) -> Unit raise ProcessError {
  let rc = c_kill(pid, sig)
  if rc < 0 {
    raise Failed(op="kill", errno=-rc)
  }
}

///|
/// Kill a freshly spawned process: its group first, then the pid itself. Between
/// the fork and the child's own setsid() the group does not exist yet, so a group
/// signal alone can miss and leave the process running, while the pid is always
/// there. Failures are ignored on purpose: this is best-effort cleanup, and every
/// way it can fail means the process is already gone or was never ours.
pub fn kill_fresh(pid : Int32, sig : Int32) -> Unit {
  try kill_group(pid, sig) catch {
    _ => ()
  } noraise {
    _ => ()
  }
  try kill(pid, sig) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}
