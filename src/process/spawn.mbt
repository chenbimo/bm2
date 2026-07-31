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
/// Open a pidfd pinned to `pid` (Linux >= 5.3). The fd always refers to
/// that original process, never to a pid-reused successor.
pub fn pidfd_open(pid : Int) -> Int raise ProcessError {
  let fd = c_pidfd_open(pid)
  if fd < 0 {
    raise Failed(op="pidfd_open", errno=-fd)
  }
  fd
}

///|
/// True while the pidfd's process is alive; false once it has exited.
pub fn pidfd_alive(fd : Int) -> Bool {
  c_pidfd_alive(fd) == 1
}

///|
/// True when the process behind the pidfd has really exited. The pidfd
/// becomes readable on exit, but also on stop events; confirming with
/// pid_alive (ESRCH) rules those out. waitid(P_PIDFD) itself only works
/// for child processes, so this poll-based check is the only reliable
/// exit signal for adopted (reparented) instances.
pub fn pidfd_exited(fd : Int, pid : Int) -> Bool {
  !pidfd_alive(fd) && !pid_alive(pid)
}

///|
/// Take a non-blocking exclusive flock on `path`; the returned fd must be
/// kept open for the lock to be held (released on close or process exit).
pub fn lock_exclusive(path : String) -> Int raise ProcessError {
  let fd = c_lock_exclusive(cstr(path))
  if fd < 0 {
    raise Failed(op="lock_exclusive", errno=-fd)
  }
  fd
}

///|
pub fn sleep_ms(ms : Int) -> Unit {
  c_sleep_ms(ms)
}
