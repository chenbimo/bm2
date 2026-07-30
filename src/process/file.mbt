///|
pub fn mkdir_p(path : String, mode? : Int = 0o755) -> Unit raise ProcessError {
  let rc = c_mkdir_p(cstr(path), mode)
  if rc < 0 {
    raise Failed(op="mkdir_p", errno=-rc)
  }
}

///|
/// Write "<path>.tmp", fsync, then atomically rename over path.
pub fn write_atomic(path : String, data : Bytes) -> Unit raise ProcessError {
  let rc = c_write_atomic(cstr(path), data)
  if rc < 0 {
    raise Failed(op="write_atomic", errno=-rc)
  }
}

///|
pub fn append_file(path : String, data : Bytes) -> Unit raise ProcessError {
  let rc = c_append_file(cstr(path), data)
  if rc < 0 {
    raise Failed(op="append_file", errno=-rc)
  }
}

///|
pub fn unlink(path : String) -> Unit raise ProcessError {
  let rc = c_unlink(cstr(path))
  if rc < 0 {
    raise Failed(op="unlink", errno=-rc)
  }
}
