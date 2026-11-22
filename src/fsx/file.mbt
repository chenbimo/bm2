///|
/// 逐级创建目录。x/fs 的 `create_dir` 只建一层，`-p` 的语义在这里补：
/// 碰到已存在的层级就跳过，最后用 `is_dir` 判一次，权限类错误不会被吞。
pub fn mkdir_p(path : String, mode~ : Int32 = 0o755) -> Unit raise FileError {
  let absolute = path.has_prefix("/")
  let mut acc = if absolute { "" } else { "" }
  for part in path.split("/") {
    if part == "" || part == "." {
      continue
    }
    // 逐段构建用显式分隔符：这里 acc 从空串起步，交给 Path 拼会丢掉
    // 绝对路径的前导 "/"（Path("") / Path("tmp") 得到 "tmp"）。
    acc = acc + "/" + part.to_owned()
    let made = try @fs.create_dir(acc) catch {
      _ => false
    } noraise {
      _ => true
    }
    if !made {
      let exists = try @fs.is_dir(acc) catch {
        _ => false
      } noraise {
        v => v
      }
      if !exists {
        raise Failed(op="mkdir_p", errno=0)
      }
    }
  }
  // 已存在的目录不会经过 create_dir，权限要显式对齐（状态目录不允许组/其他人可读）。
  chmod(path, mode)
}

///|
/// Write "<path>.tmp", fsync, then atomically rename over path.
pub fn write_atomic(path : String, data : Bytes) -> Unit raise FileError {
  let rc = c_write_atomic(cstr(path), data)
  if rc < 0 {
    raise Failed(op="write_atomic", errno=-rc)
  }
}

///|
/// The same atomic write without the directory fsync, for files that are
/// rewritten on every spawn and are reconstructible from the running state
/// (per-instance supervision state). Skips one fsync per write.
pub fn write_atomic_fast(path : String, data : Bytes) -> Unit raise FileError {
  let rc = c_write_atomic_fast(cstr(path), data)
  if rc < 0 {
    raise Failed(op="write_atomic_fast", errno=-rc)
  }
}

///|
/// 追加写：交给 x/fs 的 append 模式（O_APPEND），不再自己握一个 C 写入器。
///
/// 两个默认值必须显式覆盖，都与原来的 C 实现对齐：权限 0600（日志里可能
/// 有应用输出，默认的 0644 会让本机任何用户读到）与 NoSync（原实现不 fsync，
/// 事件日志是高频追加，每次 fdatasync 会把这个热点拖慢一个量级）。
pub fn append_file(path : String, data : Bytes) -> Unit raise FileError {
  try
    @fs.write_file(path, data, append=true, permission=0o600, sync=@fs.NoSync)
  catch {
    _ => raise Failed(op="append_file", errno=0)
  } noraise {
    _ => ()
  }
}

///|
/// Owner uid of a directory, None when the path is not a directory or cannot be
/// stat'ed. The state dir holds the control-plane token, so the daemon checks
/// this before trusting it.
pub fn dir_owner(path : String) -> Int32? {
  let uid = c_dir_owner(cstr(path))
  if uid < 0 {
    None
  } else {
    Some(uid)
  }
}

///|
pub fn unlink(path : String) -> Unit raise FileError {
  let rc = c_unlink(cstr(path))
  if rc < 0 {
    raise Failed(op="unlink", errno=-rc)
  }
}

///|
/// Set the mode of an existing path. `mkdir_p` only applies its mode to
/// directories it creates, so a state dir left behind by an older version
/// (or created by hand) needs an explicit chmod to stop being group or
/// world readable — it holds app logs.
pub fn chmod(path : String, mode : Int32) -> Unit raise FileError {
  let rc = c_chmod(cstr(path), mode)
  if rc < 0 {
    raise Failed(op="chmod", errno=-rc)
  }
}

///|
/// File size in bytes; None when the file does not exist or is unreadable.
///
/// 走 stat 而不是 open：调用方拿它当"存在性探测"，目录也要能返回
/// （x/fs 的 `File::size` 需要先 open，对目录会 EISDIR）。
pub fn file_size(path : String) -> Int64? {
  let size = c_file_size(cstr(path))
  if size < 0L {
    None
  } else {
    Some(size)
  }
}

///|
/// The canonical form of a path: symlinks resolved, `.` and `..` folded. None
/// when it cannot be resolved (the file is missing, or a permission problem), so
/// a caller can fall back to the spelling it had.
///
/// This is how the daemon decides whether two registrations name the same
/// project: the same config file reached through a symlink or a relative path has
/// to compare equal, or a legitimate `bm2 start` would look like a name conflict.
pub fn realpath(path : String) -> String? {
  let cap : Int32 = 4096
  let buf = Bytes::make(cap, b'\x00')
  let len = c_realpath(cstr(path), buf, cap)
  if len < 0 {
    None
  } else {
    Some(@utf8.decode_lossy(buf[:len]))
  }
}
