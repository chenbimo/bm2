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
/// 读一个小文件，最多 `cap` 字节。普通文件按大小决定读多少，/proc 这类
/// size 恒为 0 的虚拟文件读到 EOF——两条路径都不会把大文件整个读进内存。
pub fn read_small(path : String, cap~ : Int32 = 8192) -> Bytes raise FileError {
  let f = try @fs.open(path, mode=@fs.ReadOnly) catch {
    _ => raise Failed(op="read_small", errno=0)
  } noraise {
    f => f
  }
  let size = try f.size() catch {
    _ => 0L
  } noraise {
    n => n
  }
  let data = if size > cap.to_int64() {
    try f.read_exactly(cap) catch {
      _ => raise Failed(op="read_small", errno=0)
    } noraise {
      b => b
    }
  } else {
    try f.read_all() catch {
      _ => raise Failed(op="read_small", errno=0)
    } noraise {
      b => b
    }
  }
  f.close()
  data
}
