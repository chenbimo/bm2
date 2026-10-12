///|
/// Take a non-blocking exclusive flock on `path`; the returned fd must be
/// kept open for the lock to be held (released on close or process exit).
pub fn lock_exclusive(path : String) -> Int32 raise FileError {
  let fd = c_lock_exclusive(cstr(path))
  if fd < 0 {
    raise Failed(op="lock_exclusive", errno=-fd)
  }
  fd
}

///|
/// Read a small file into a buffer; works on /proc virtual files.
pub fn read_small(path : String, cap~ : Int32 = 8192) -> Bytes raise FileError {
  let buf = Bytes::make(cap, b'\x00')
  let len = c_read_small(cstr(path), buf, cap)
  if len < 0 {
    raise Failed(op="read_small", errno=-len)
  }
  buf[:len].to_owned()
}
