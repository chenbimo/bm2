///|
/// bm2 is Linux-only. Both binaries refuse to run elsewhere with a clear
/// reason instead of failing later on the first POSIX-specific syscall.
/// Returns None when the platform is supported.
pub fn platform_error() -> String? {
  let name = try uname() catch {
    _ => return Some("cannot detect platform")
  } noraise {
    name => name
  }
  if name == "Linux" {
    None
  } else {
    Some("this build supports Linux only (detected: \{name})")
  }
}
