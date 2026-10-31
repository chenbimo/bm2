///|
pub(all) suberror ProcessError {
  Failed(op~ : String, errno~ : Int32)
}

///|
pub impl Show for ProcessError with fn output(self, logger) {
  match self {
    Failed(op~, errno~) => {
      logger.write_string(op)
      logger.write_string(" failed: errno ")
      logger.write_string(errno.to_string())
    }
  }
}

///|
pub extend ProcessError with Show::{to_string, output}

///|
/// 把命令参数转成 C 字符串。proc 包自用,与 fsx 的同名辅助各自独立。
fn cstr(s : String) -> Bytes {
  @utf8.encode(s + "\u{0}")
}

///|
#borrow(bun_path, script, cwd, out_path, err_path, env_blob)
extern "C" fn c_spawn(
  bun_path : Bytes,
  script : Bytes,
  cwd : Bytes,
  out_path : Bytes,
  err_path : Bytes,
  env_blob : Bytes,
) -> Int32 = "proc_spawn"

///|
#borrow(out)
extern "C" fn c_waitpid(pid : Int32, nohang : Int32, out : Bytes) -> Int32 = "proc_waitpid"

///|
extern "C" fn c_kill_pg(pgid : Int32, sig : Int32) -> Int32 = "proc_kill_pg"

///|
extern "C" fn c_kill0(pid : Int32) -> Int32 = "proc_kill0"

///|
extern "C" fn c_sleep_ms(ms : Int32) -> Unit = "proc_sleep_ms"

///|
#borrow(path, buf)
extern "C" fn c_read_file(path : Bytes, buf : Bytes, cap : Int32) -> Int32 = "proc_read_file"

///|
extern "C" fn c_getpid() -> Int32 = "proc_getpid"

///|
extern "C" fn c_close(fd : Int32) -> Int32 = "proc_close"

///|
/// Probe a port's SO_REUSEPORT status by binding: 0 = free (not listening
/// yet), 1 = joinable (the listener shares, reusePort on), 2 = held
/// exclusively (reusePort missing), negative = errno.
extern "C" fn c_probe_reuseport(port : Int32) -> Int32 = "proc_probe_reuseport"

///|
extern "C" fn c_pidfd_open(pid : Int32) -> Int32 = "proc_pidfd_open"

///|
#borrow(out)
extern "C" fn c_wait_pidfd(fd : Int32, nohang : Int32, out : Bytes) -> Int32 = "proc_wait_pidfd"

///|
extern "C" fn c_pidfd_alive(fd : Int32) -> Int32 = "proc_pidfd_alive"

///|
#borrow(buf)
extern "C" fn c_self_exe(buf : Bytes, cap : Int32) -> Int32 = "proc_self_exe"

///|
extern "C" fn c_exit(code : Int32) -> Unit = "proc_exit"

///|
extern "C" fn c_watch_interrupts() -> Int32 = "proc_watch_interrupts"

///|
extern "C" fn c_interrupted() -> Int32 = "proc_interrupted"

///|
/// Monotonic milliseconds, the clock every interval and deadline is measured
/// with. Never steps backwards, unlike the wall clock.
extern "C" fn c_monotonic_ms() -> Int64 = "proc_monotonic_ms"

///|
#borrow(out)
extern "C" fn c_local_parts(epoch_ms : Int64, out : Bytes) -> Int32 = "proc_local_parts"

///|
#borrow(path)
extern "C" fn c_disk_free_kb(path : Bytes) -> Int64 = "proc_disk_free_kb"

///|
#borrow(data)
extern "C" fn c_write_fd(fd : Int32, data : Bytes) -> Int32 = "proc_write_fd"

///|
extern "C" fn c_kill(pid : Int32, sig : Int32) -> Int32 = "proc_kill"

///|
extern "C" fn c_pidfd_send_signal(fd : Int32, sig : Int32) -> Int32 = "proc_pidfd_send_signal"
