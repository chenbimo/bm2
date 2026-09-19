///|
pub(all) enum ChildExit {
  Exited(Int)
  Signaled(Int)
} derive(Debug, Eq)

///|
fn get_i32_le(bytes : Bytes, offset : Int) -> Int {
  bytes[offset].to_int() |
  (bytes[offset + 1].to_int() << 8) |
  (bytes[offset + 2].to_int() << 16) |
  (bytes[offset + 3].to_int() << 24)
}

///|
/// Reap a process through a pidfd (waitid P_PIDFD). Works for adopted
/// (non-child) processes too. ECHILD means the exit was already reaped,
/// which is reported as None rather than an error.
pub fn wait_pidfd(
  fd : Int,
  nohang? : Bool = false,
) -> (Int, ChildExit)? raise ProcessError {
  let out = Bytes::make(12, b'\x00')
  ignore(c_wait_pidfd(fd, if nohang { 1 } else { 0 }, out))
  let reaped = get_i32_le(out, 0)
  if reaped == 0 {
    return None
  }
  if reaped < 0 {
    let errno = get_i32_le(out, 8)
    if errno == 10 {
      // ECHILD: exit already reaped earlier; treat as no event.
      return None
    }
    raise Failed(op="wait_pidfd", errno~)
  }
  // Linux wait status ABI: low 7 bits select the exit kind.
  let status = get_i32_le(out, 4)
  let kind = status & 0x7f
  if kind == 0 {
    Some((reaped, Exited((status >> 8) & 0xff)))
  } else {
    Some((reaped, Signaled(kind)))
  }
}

///|
/// Reap a just-killed child until it is gone (bounded), so a failed spawn
/// attempt never leaves a zombie behind. Returns immediately when the
/// child is not reapable (already reaped, adopted, or not ours).
pub fn drain_child(pid : Int) -> Unit {
  for _ in 0..<50 {
    let reaped = try wait_child(pid, nohang=true) catch {
      _ => return
    } noraise {
      r => r
    }
    match reaped {
      Some(_) => return
      None => sleep_ms(10)
    }
  }
}

///|
/// Wait for a child with a hard deadline, through a pidfd so the wait
/// cannot be fooled by pid reuse. When the deadline passes the whole
/// process group is SIGKILLed and the reap is retried for a short bounded
/// window, so a helper that hangs (a stuck mount, a wrapper script) can
/// never freeze the single-threaded daemon forever. Returns None when no
/// exit could be observed in time.
pub fn wait_child_timeout(pid : Int, timeout_ms : Int) -> (Int, ChildExit)? {
  let pidfd = try pidfd_open(pid) catch {
    _ => return None
  } noraise {
    fd => fd
  }
  let deadline = @env.now() + timeout_ms.to_uint64()
  let mut result : (Int, ChildExit)? = None
  while result is None {
    result = wait_pidfd_nohang(pidfd)
    if result is None {
      if @env.now() >= deadline {
        discard(() => kill_group(pid, SIGKILL))
        // Bounded post-kill reap: a process stuck in uninterruptible sleep
        // is reported as a timeout rather than blocking the caller.
        for _ in 0..<100 {
          result = wait_pidfd_nohang(pidfd)
          if result is Some(_) {
            break
          }
          sleep_ms(20)
        }
        break
      }
      sleep_ms(20)
    }
  }
  close(pidfd)
  result
}

///|
/// Non-blocking wait on a pidfd; a failed call is reported as "nothing
/// reaped yet" so the caller's deadline stays in charge of the loop.
fn wait_pidfd_nohang(fd : Int) -> (Int, ChildExit)? {
  try wait_pidfd(fd, nohang=true) catch {
    _ => None
  } noraise {
    r => r
  }
}

///|
/// Reap a child with waitpid. `pid = -1` reaps any child.
/// Returns None when `nohang` is set and no child has exited.
pub fn wait_child(
  pid : Int,
  nohang? : Bool = false,
) -> (Int, ChildExit)? raise ProcessError {
  let out = Bytes::make(12, b'\x00')
  ignore(c_waitpid(pid, if nohang { 1 } else { 0 }, out))
  let reaped = get_i32_le(out, 0)
  if reaped == 0 {
    return None
  }
  if reaped < 0 {
    raise Failed(op="waitpid", errno=get_i32_le(out, 8))
  }
  // Linux wait status ABI: low 7 bits select the exit kind.
  let status = get_i32_le(out, 4)
  let kind = status & 0x7f
  if kind == 0 {
    Some((reaped, Exited((status >> 8) & 0xff)))
  } else {
    Some((reaped, Signaled(kind)))
  }
}
