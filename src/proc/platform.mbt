///|
/// Host name from the kernel, or "unknown" when it cannot be read. Used to say
/// which machine a notification came from.
pub fn hostname() -> String {
  match read_proc_text("/proc/sys/kernel/hostname") {
    None => "unknown"
    Some(text) => {
      let name = text.trim().to_owned()
      if name.is_empty() {
        "unknown"
      } else {
        name
      }
    }
  }
}

///|
/// The library is Linux-only. Host binaries refuse to run elsewhere with a
/// clear reason instead of failing later on the first POSIX-specific
/// syscall. Returns None when the platform is supported.
pub fn platform_error() -> String? {
  let name = match ostype() {
    None => return Some("cannot detect platform")
    Some(value) => value
  }
  if name == "Linux" {
    None
  } else {
    Some("this build supports Linux only (detected: \{name})")
  }
}

///|
/// Close a pidfd or lock fd. Owned by the supervision layer.
pub fn close(fd : Int32) -> Unit {
  ignore(c_close(fd))
}

///|
/// Ask the kernel whether `port` accepts a SO_REUSEPORT join: 0 = free
/// (nothing listening yet), 1 = joinable (listener enables reusePort),
/// 2 = held exclusively (reusePort missing), negative = errno.
pub fn probe_reuseport(port : Int32) -> Int32 {
  c_probe_reuseport(port)
}

///|
/// Real user id, from the `Uid:` line of /proc/self/status. `-1` when the file
/// cannot be read, which never happens for the daemon's own process and leaves
/// a value no comparison or path can mistake for a real uid.
pub fn get_uid() -> Int32 {
  let body = match read_proc_text("/proc/self/status") {
    None => return -1
    Some(text) => text
  }
  for line in @utils.split(body, "\n") {
    if line.has_prefix("Uid:") {
      return match digits_at(line, 4) {
        Some(value) => value
        None => -1
      }
    }
  }
  -1
}

///|
/// Monotonic milliseconds since an unspecified origin. All supervision
/// intervals and deadlines are measured with this clock, so a system time
/// change (an NTP step, a manual `date`) can never desynchronise them or
/// underflow an unsigned subtraction. `@utils.now_ms` stays the wall clock,
/// used only where a human needs an absolute time.
pub fn monotonic_ms() -> UInt64 {
  let ms = c_monotonic_ms()
  if ms <= 0L {
    0UL
  } else {
    ms.reinterpret_as_uint64()
  }
}

///|
/// Local-time components of `epoch_ms` in the system timezone:
/// (year, month 1-12, day, weekday 0=Sunday..6, hour 0-23, minute 0-59).
/// None when the conversion fails.
///
/// 时区换算交给官方包：`@time.local_zone()` 读 /etc/localtime，夏令时与
/// 历史时区偏移都由它处理，比自己调 localtime_r 少一个 C 函数要维护。
pub fn local_parts(
  epoch_ms : UInt64,
) -> (Int32, Int32, Int32, Int32, Int32, Int32)? {
  let sec = (epoch_ms / 1000UL).reinterpret_as_int64()
  let nanos : Int32 = (epoch_ms % 1000UL).to_int() * 1000000
  let zone = try @time.local_zone() catch {
    _ => return None
  } noraise {
    z => z
  }
  let zdt = try
    @time.ZonedDateTime::from_unix_second(sec, nanosecond=nanos, zone~)
  catch {
    _ => return None
  } noraise {
    z => z
  }
  // 0=Sunday..6，与调用方（每日统计的分钟闸）依赖的语义一致。
  let weekday = match zdt.weekday() {
    @time.Weekday::Sunday => 0
    @time.Weekday::Monday => 1
    @time.Weekday::Tuesday => 2
    @time.Weekday::Wednesday => 3
    @time.Weekday::Thursday => 4
    @time.Weekday::Friday => 5
    @time.Weekday::Saturday => 6
  }
  Some((zdt.year(), zdt.month(), zdt.day(), weekday, zdt.hour(), zdt.minute()))
}

///|
/// One-minute load average from /proc/loadavg, None when unavailable.
pub fn load_1m() -> Double? {
  let body = match read_proc_text("/proc/loadavg") {
    None => return None
    Some(text) => text
  }
  let fields = proc_fields(body)
  if fields.is_empty() {
    return None
  }
  double_of(fields[0])
}

///|
/// Free space in KiB on the filesystem holding `path`, None on error.
pub fn disk_free_kb(path : String) -> Int64? {
  let kb = c_disk_free_kb(cstr(path))
  if kb < 0L {
    None
  } else {
    Some(kb)
  }
}

///|
/// Kernel name from /proc/sys/kernel/ostype, e.g. "Linux". None when the file
/// cannot be read, which on a kernel that runs bm2 never happens.
pub fn ostype() -> String? {
  match read_proc_text("/proc/sys/kernel/ostype") {
    None => None
    Some(text) => Some(text.trim().to_owned())
  }
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
/// Exit the process immediately with the given code.
pub fn exit(code : Int32) -> Unit {
  c_exit(code)
}

///|
/// Write a line to stderr (for CLI diagnostics; stdout stays machine-usable).
pub fn eprintln(text : String) -> Unit {
  ignore(c_write_fd(2, @utf8.encode(text + "\n")))
}

///|
/// Write text to stdout as-is: no added newline, no stdio buffering.
///
/// `bm2 dev` follows a log file with this. Both conveniences that `println` adds
/// would be wrong there — an invented newline misreports where the app's line
/// ended, and a buffer that only flushes on newlines hides the last partial line
/// of a process that is still running.
pub fn print(text : String) -> Unit {
  ignore(c_write_fd(1, @utf8.encode(text)))
}
