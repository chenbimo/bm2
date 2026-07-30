///|
pub(all) suberror ProcessError {
  Failed(op~ : String, errno~ : Int)
}

///|
pub impl Show for ProcessError with fn output(self, logger) {
  let Failed(op~, errno~) = self
  logger.write_string(op)
  logger.write_string(" failed: errno ")
  logger.write_string(errno.to_string())
}

///|
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
) -> Int = "bm2_spawn"

///|
#borrow(out)
extern "C" fn c_waitpid(pid : Int, nohang : Int, out : Bytes) -> Int = "bm2_waitpid"

///|
extern "C" fn c_kill_pg(pgid : Int, sig : Int) -> Int = "bm2_kill_pg"

///|
extern "C" fn c_kill0(pid : Int) -> Int = "bm2_kill0"

///|
extern "C" fn c_sleep_ms(ms : Int) -> Unit = "bm2_sleep_ms"

///|
extern "C" fn c_getpid() -> Int = "bm2_getpid"

///|
extern "C" fn c_read_rss_kb(pid : Int) -> Int = "bm2_read_rss_kb"

///|
#borrow(path)
extern "C" fn c_mkdir_p(path : Bytes, mode : Int) -> Int = "bm2_mkdir_p"

///|
#borrow(path, data)
extern "C" fn c_write_atomic(path : Bytes, data : Bytes) -> Int = "bm2_write_atomic"

///|
#borrow(path, data)
extern "C" fn c_append_file(path : Bytes, data : Bytes) -> Int = "bm2_append_file"

///|
#borrow(path)
extern "C" fn c_unlink(path : Bytes) -> Int = "bm2_unlink"

///|
#borrow(path)
extern "C" fn c_socket_listen(path : Bytes) -> Int = "bm2_socket_listen"

///|
#borrow(path)
extern "C" fn c_socket_connect(path : Bytes) -> Int = "bm2_socket_connect"

///|
extern "C" fn c_poll_fd(fd : Int, timeout_ms : Int) -> Int = "bm2_poll_fd"

///|
extern "C" fn c_accept(listen_fd : Int) -> Int = "bm2_accept"

///|
extern "C" fn c_close(fd : Int) -> Int = "bm2_close"

///|
#borrow(data)
extern "C" fn c_send_msg(fd : Int, data : Bytes) -> Int = "bm2_send_msg"

///|
#borrow(buf)
extern "C" fn c_recv_msg(fd : Int, buf : Bytes, cap : Int) -> Int = "bm2_recv_msg"

///|
extern "C" fn c_peer_uid(fd : Int) -> Int = "bm2_peer_uid"

///|
extern "C" fn c_getuid() -> Int = "bm2_getuid"

///|
#borrow(buf)
extern "C" fn c_self_exe(buf : Bytes, cap : Int) -> Int = "bm2_self_exe"

///|
#borrow(path, buf)
extern "C" fn c_read_small(path : Bytes, buf : Bytes, cap : Int) -> Int = "bm2_read_small"

///|
extern "C" fn c_install_term_handler() -> Unit = "bm2_install_term_handler"

///|
extern "C" fn c_term_flag() -> Int = "bm2_term_flag"

///|
extern "C" fn c_exit(code : Int) -> Unit = "bm2_exit"

///|
#borrow(data)
extern "C" fn c_write_fd(fd : Int, data : Bytes) -> Int = "bm2_write_fd"
