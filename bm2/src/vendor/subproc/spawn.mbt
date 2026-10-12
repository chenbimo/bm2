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
pub extend SpawnSpec with Debug::{to_repr}

///|
pub fn spawn(spec : SpawnSpec) -> Int32 raise ProcessError {
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
pub fn get_pid() -> Int32 {
  c_getpid()
}

///|
/// Open a pidfd pinned to `pid` (Linux >= 5.3). The fd always refers to
/// that original process, never to a pid-reused successor.
pub fn pidfd_open(pid : Int32) -> Int32 raise ProcessError {
  let fd = c_pidfd_open(pid)
  if fd < 0 {
    raise Failed(op="pidfd_open", errno=-fd)
  }
  fd
}

///|
/// True while the pidfd's process is alive; false once it has exited.
pub fn pidfd_alive(fd : Int32) -> Bool {
  c_pidfd_alive(fd) == 1
}

///|
/// True when the process behind the pidfd has really exited. The pidfd
/// becomes readable on exit, but also on stop events; confirming with
/// pid_alive (ESRCH) rules those out. waitid(P_PIDFD) itself only works
/// for child processes, so this poll-based check is the only reliable
/// exit signal for adopted (reparented) instances.
pub fn pidfd_exited(fd : Int32, pid : Int32) -> Bool {
  !pidfd_alive(fd) && !pid_alive(pid)
}

///|
pub fn sleep_ms(ms : Int32) -> Unit {
  c_sleep_ms(ms)
}
