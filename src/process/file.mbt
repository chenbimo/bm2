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

///|
/// File size in bytes; None when the file does not exist or is unreadable.
pub fn file_size(path : String) -> Int64? {
  let size = c_file_size(cstr(path))
  if size < 0L {
    None
  } else {
    Some(size)
  }
}

///|
/// Shift the rotation chain and rename path to path.1 (drops path.10).
/// For logs written by this daemon, where no fd survives the rename.
pub fn rotate(path : String) -> Unit raise ProcessError {
  let rc = c_rotate(cstr(path))
  if rc < 0 {
    raise Failed(op="rotate", errno=-rc)
  }
}

///|
/// Copy path into path.1 (shifting the chain) and truncate path to zero.
/// For logs held open by app processes, which keep writing to the old
/// inode; a few bytes written during the copy are lost.
pub fn copytruncate(path : String) -> Unit raise ProcessError {
  let rc = c_copytruncate(cstr(path))
  if rc < 0 {
    raise Failed(op="copytruncate", errno=-rc)
  }
}
