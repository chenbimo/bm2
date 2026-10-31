///|
pub const SIGTERM : Int32 = 15

///|
pub const SIGKILL : Int32 = 9

///|
/// Ask for Ctrl+C and SIGTERM to be delivered to this process.
///
/// The MoonBit runtime sets the process-wide disposition for its own reasons -
/// SIGINT ignored, SIGTERM blocked - which is right for a library an embedder
/// wants to decide for. bm2 needs the opposite for a foreground command, so this
/// replaces the disposition and lifts the mask. Without it a follow loop can only
/// be stopped with SIGKILL.
///
/// The handler does nothing but set a flag, because nothing else is
/// async-signal-safe. `interrupted` is how a polling loop notices.
pub fn watch_interrupts() -> Unit raise ProcessError {
  let rc = c_watch_interrupts()
  if rc < 0 {
    raise Failed(op="watch_interrupts", errno=-rc)
  }
}

///|
/// The signal that has arrived since `watch_interrupts`, or 0 for none. One
/// process, one flag: the last signal wins, which is all a loop needs to know.
pub fn interrupted() -> Int32 {
  c_interrupted()
}

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
/// Signal the process a pidfd is pinned to. The kernel resolves the fd to the
/// process it was opened for, so a pid reused between a liveness check and the
/// send cannot receive this signal instead of the intended target.
pub fn signal_pidfd(fd : Int32, sig : Int32) -> Unit raise ProcessError {
  let rc = c_pidfd_send_signal(fd, sig)
  if rc < 0 {
    raise Failed(op="pidfd_send_signal", errno=-rc)
  }
}

///|
/// Best-effort signal for one supervised instance: the pidfd pins the leader
/// when we hold one, and the process group takes the children setsid() put in
/// the same group. Failures are ignored because every way this can fail means
/// the process is already gone.
pub fn signal_tree(pidfd : Int32, pgid : Int32, sig : Int32) -> Unit {
  if pidfd > 0 {
    try signal_pidfd(pidfd, sig) catch {
      _ => ()
    } noraise {
      _ => ()
    }
  }
  try kill_group(pgid, sig) catch {
    _ => ()
  } noraise {
    _ => ()
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
