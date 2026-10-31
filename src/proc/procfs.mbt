///|
/// Read a file under /proc as text. `None` when it cannot be read, which for
/// /proc means the process is gone rather than that something went wrong.
///
/// procfs reports a size of 0 for its files, so the read has to go until EOF;
/// a size-then-read helper returns an empty string here. One buffer of
/// `PROC_READ_CAP` is enough for every file bm2 parses - `/proc/stat` on a
/// 128-core box is about 13 KB - and a longer file is simply truncated.
fn read_proc_text(path : String) -> String? {
  let buf = Bytes::make(PROC_READ_CAP, b'\x00')
  let len = c_read_file(cstr(path), buf, PROC_READ_CAP)
  if len < 0 {
    None
  } else {
    Some(@utf8.decode_lossy(buf[:len].to_owned()))
  }
}

///|
/// Upper bound for one /proc read, in bytes.
const PROC_READ_CAP : Int32 = 65536

///|
/// Read a directory listing under /proc. `None` when it cannot be read, which
/// for /proc means the process is gone.
///
/// Existence is checked first because the underlying `read_dir` reports a
/// missing directory through C `perror`, and a process that exits mid-walk is
/// ordinary here, not something to write to the daemon log.
fn read_proc_dir(path : String) -> Array[String]? {
  if !@fs.path_exists(path) {
    return None
  }
  try @fs.read_dir(path) catch {
    _ => None
  } noraise {
    entries => Some(entries.to_owned())
  }
}

///|
/// The first run of digits at or after `from`, as an Int32. `None` when there
/// is none, which only happens if the kernel changed a file layout.
fn digits_at(text : String, from : Int32) -> Int32? {
  let mut start = -1
  let mut index = from
  let length = text.length()
  while index < length {
    let code = text[index].to_int()
    let digit = code >= 48 && code <= 57
    if digit && start < 0 {
      start = index
    } else if !digit && start >= 0 {
      break
    }
    index += 1
  }
  if start < 0 {
    return None
  }
  let mut value = 0
  for i in start..<index {
    value = value * 10 + (text[i].to_int() - 48)
  }
  Some(value)
}

///|
/// Parse an unsigned decimal field. `None` when the text is not all digits.
fn u64_of(text : String) -> UInt64? {
  if text.is_empty() {
    return None
  }
  let mut value = 0UL
  for i in 0..<text.length() {
    let code = text[i].to_int()
    if code < 48 || code > 57 {
      return None
    }
    value = value * 10UL + (code - 48).to_uint64()
  }
  Some(value)
}

///|
/// Parse a plain decimal like "0.42", the shape /proc/loadavg reports. `None`
/// when the text is not a decimal number.
fn double_of(text : String) -> Double? {
  let mut whole = 0.0
  let mut frac = 0.0
  let mut scale = 1.0
  let mut seen_dot = false
  let mut seen_digit = false
  for i in 0..<text.length() {
    let code = text[i].to_int()
    if code == 46 {
      if seen_dot {
        return None
      }
      seen_dot = true
    } else if code >= 48 && code <= 57 {
      let digit = (code - 48).to_double()
      if seen_dot {
        scale = scale * 10.0
        frac = frac + digit / scale
      } else {
        whole = whole * 10.0 + digit
      }
      seen_digit = true
    } else {
      return None
    }
  }
  if !seen_digit {
    return None
  }
  Some(whole + frac)
}

///|
/// Split a /proc field line into its non-empty fields. `/proc` separates with
/// single spaces, but the leading separator after the comm leaves an empty
/// first element unless the text is trimmed first.
fn proc_fields(text : String) -> Array[String] {
  let fields : Array[String] = []
  for field in @utils.split(text.trim().to_owned(), " ") {
    if !field.is_empty() {
      fields.push(field)
    }
  }
  fields
}

///|
/// VmRSS in kB from /proc/<pid>/status, None when the process is gone.
pub fn read_rss_kb(pid : Int32) -> Int32? {
  match read_proc_text("/proc/\{pid}/status") {
    None => None
    Some(body) => {
      for line in @utils.split(body, "\n") {
        if line.has_prefix("VmRSS:") {
          return digits_at(line, 6)
        }
      }
      None
    }
  }
}

///|
/// utime + stime of a process in clock ticks, None when it is gone. A single
/// sample is meaningless on its own; CPU percent comes from two samples taken
/// `clk_tck()` apart.
///
/// /proc/<pid>/stat starts with `pid (comm) state ...`, and `comm` may itself
/// contain spaces and parentheses, so parsing resumes after the last ')'.
pub fn read_cpu_ticks(pid : Int32) -> UInt64? {
  let body = match read_proc_text("/proc/\{pid}/stat") {
    None => return None
    Some(text) => text
  }
  let mut close = body.length() - 1
  while close >= 0 && body[close] != ')' {
    close -= 1
  }
  if close < 0 {
    return None
  }
  // Field 3 is the state right after the comm, utime is field 14 and stime 15,
  // so they land at offsets 11 and 12 of the fields that follow the comm.
  let fields = proc_fields(body[close + 1:].to_owned())
  if fields.length() < 13 {
    return None
  }
  let utime = match u64_of(fields[11]) {
    None => return None
    Some(value) => value
  }
  let stime = match u64_of(fields[12]) {
    None => return None
    Some(value) => value
  }
  Some(utime + stime)
}

///|
/// Clock ticks per second for the values in /proc. The kernel reports them in
/// USER_HZ, which is 100 on every Linux architecture bm2 targets, so there is
/// nothing left to ask the C library about.
pub fn clk_tck() -> Int32 {
  100
}
