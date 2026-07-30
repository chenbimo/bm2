///|
/// Max payload of one length-prefixed protocol message.
pub const MSG_CAP : Int = 65536

///|
/// Listen on a fresh AF_UNIX socket (stale path unlinked, mode 0600).
pub fn socket_listen(path : String) -> Int raise ProcessError {
  let fd = c_socket_listen(cstr(path))
  if fd < 0 {
    raise Failed(op="socket_listen", errno=-fd)
  }
  fd
}

///|
pub fn socket_connect(path : String) -> Int raise ProcessError {
  let fd = c_socket_connect(cstr(path))
  if fd < 0 {
    raise Failed(op="socket_connect", errno=-fd)
  }
  fd
}

///|
/// True when the fd is readable within timeout_ms.
pub fn poll_fd(fd : Int, timeout_ms : Int) -> Bool raise ProcessError {
  let rc = c_poll_fd(fd, timeout_ms)
  if rc < 0 {
    raise Failed(op="poll", errno=-rc)
  }
  rc == 1
}

///|
pub fn accept(listen_fd : Int) -> Int raise ProcessError {
  let fd = c_accept(listen_fd)
  if fd < 0 {
    raise Failed(op="accept", errno=-fd)
  }
  fd
}

///|
pub fn close(fd : Int) -> Unit {
  ignore(c_close(fd))
}

///|
/// Send one length-prefixed message (4-byte BE length + payload).
pub fn send_msg(fd : Int, data : Bytes) -> Unit raise ProcessError {
  let rc = c_send_msg(fd, data)
  if rc < 0 {
    raise Failed(op="send_msg", errno=-rc)
  }
}

///|
/// Receive one length-prefixed message.
pub fn recv_msg(fd : Int, cap? : Int = MSG_CAP) -> Bytes raise ProcessError {
  let buf = Bytes::make(cap, b'\x00')
  let len = c_recv_msg(fd, buf, cap)
  if len < 0 {
    raise Failed(op="recv_msg", errno=-len)
  }
  buf[:len].to_owned()
}

///|
/// uid of the connected peer (SO_PEERCRED).
pub fn peer_uid(fd : Int) -> Int raise ProcessError {
  let uid = c_peer_uid(fd)
  if uid < 0 {
    raise Failed(op="peer_uid", errno=-uid)
  }
  uid
}

///|
pub fn get_uid() -> Int {
  c_getuid()
}

///|
/// Absolute path of the running executable (/proc/self/exe).
pub fn self_exe() -> String raise ProcessError {
  let buf = Bytes::make(4096, b'\x00')
  let len = c_self_exe(buf, 4096)
  if len < 0 {
    raise Failed(op="self_exe", errno=-len)
  }
  @utf8.decode_lossy(buf[:len])
}

///|
/// Read a small file into a buffer; works on /proc virtual files.
pub fn read_small(path : String, cap? : Int = 8192) -> Bytes raise ProcessError {
  let buf = Bytes::make(cap, b'\x00')
  let len = c_read_small(cstr(path), buf, cap)
  if len < 0 {
    raise Failed(op="read_small", errno=-len)
  }
  buf[:len].to_owned()
}

///|
/// Install SIGTERM/SIGINT handlers that only set a pollable flag.
pub fn install_term_handler() -> Unit {
  c_install_term_handler()
}

///|
pub fn term_requested() -> Bool {
  c_term_flag() != 0
}

///|
/// Exit the process immediately with the given code.
pub fn exit(code : Int) -> Unit {
  c_exit(code)
}

///|
/// Write a line to stderr (for CLI diagnostics; stdout stays machine-usable).
pub fn eprintln(text : String) -> Unit {
  ignore(c_write_fd(2, @utf8.encode(text + "\n")))
}
