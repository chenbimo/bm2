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
#borrow(bun_path, script, cwd, out_path, err_path, env_blob)
extern "C" fn c_spawn(
  bun_path : Bytes,
  script : Bytes,
  cwd : Bytes,
  out_path : Bytes,
  err_path : Bytes,
  env_blob : Bytes,
) -> Int32 = "subproc_spawn"

///|
#borrow(out)
extern "C" fn c_waitpid(pid : Int32, nohang : Int32, out : Bytes) -> Int32 = "subproc_waitpid"

///|
extern "C" fn c_kill_pg(pgid : Int32, sig : Int32) -> Int32 = "subproc_kill_pg"

///|
extern "C" fn c_kill0(pid : Int32) -> Int32 = "subproc_kill0"

///|
extern "C" fn c_sleep_ms(ms : Int32) -> Unit = "subproc_sleep_ms"

///|
extern "C" fn c_getpid() -> Int32 = "subproc_getpid"

///|
extern "C" fn c_read_rss_kb(pid : Int32) -> Int32 = "subproc_read_rss_kb"

///|
extern "C" fn c_read_cpu_ticks(pid : Int32) -> Int64 = "subproc_read_cpu_ticks"

///|
extern "C" fn c_clk_tck() -> Int32 = "subproc_clk_tck"

///|
#borrow(buf)
extern "C" fn c_hostname(buf : Bytes, cap : Int32) -> Int32 = "subproc_hostname"

///|
extern "C" fn c_close(fd : Int32) -> Int32 = "subproc_close"

///|
/// Probe a port's SO_REUSEPORT status by binding: 0 = free (not listening
/// yet), 1 = joinable (the listener shares, reusePort on), 2 = held
/// exclusively (reusePort missing), negative = errno.
extern "C" fn c_probe_reuseport(port : Int32) -> Int32 = "subproc_probe_reuseport"

///|
extern "C" fn c_getuid() -> Int32 = "subproc_getuid"

///|
#borrow(buf)
extern "C" fn c_uname(buf : Bytes, cap : Int32) -> Int32 = "subproc_uname"

///|
extern "C" fn c_pidfd_open(pid : Int32) -> Int32 = "subproc_pidfd_open"

///|
#borrow(out)
extern "C" fn c_wait_pidfd(fd : Int32, nohang : Int32, out : Bytes) -> Int32 = "subproc_wait_pidfd"

///|
extern "C" fn c_pidfd_alive(fd : Int32) -> Int32 = "subproc_pidfd_alive"

///|
#borrow(buf)
extern "C" fn c_self_exe(buf : Bytes, cap : Int32) -> Int32 = "subproc_self_exe"

///|
extern "C" fn c_exit(code : Int32) -> Unit = "subproc_exit"

///|
#borrow(out)
extern "C" fn c_local_parts(epoch_ms : Int64, out : Bytes) -> Int32 = "subproc_local_parts"

///|
extern "C" fn c_load_1m() -> Double = "subproc_load_1m"

///|
#borrow(path)
extern "C" fn c_disk_free_kb(path : Bytes) -> Int64 = "subproc_disk_free_kb"

///|
#borrow(data)
extern "C" fn c_write_fd(fd : Int32, data : Bytes) -> Int32 = "subproc_write_fd"
