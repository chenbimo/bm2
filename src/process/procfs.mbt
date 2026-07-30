///|
/// VmRSS in kB from /proc/<pid>/status, None when the process is gone.
pub fn read_rss_kb(pid : Int) -> Int? {
  let kb = c_read_rss_kb(pid)
  if kb < 0 {
    None
  } else {
    Some(kb)
  }
}
