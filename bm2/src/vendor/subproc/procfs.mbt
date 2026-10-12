///|
/// VmRSS in kB from /proc/<pid>/status, None when the process is gone.
pub fn read_rss_kb(pid : Int32) -> Int32? {
  let kb = c_read_rss_kb(pid)
  if kb < 0 {
    None
  } else {
    Some(kb)
  }
}

///|
/// utime + stime of a process in clock ticks, None when it is gone. A single
/// sample is meaningless on its own; CPU percent comes from two samples taken
/// `clk_tck()` apart.
pub fn read_cpu_ticks(pid : Int32) -> UInt64? {
  let ticks = c_read_cpu_ticks(pid)
  if ticks < 0L {
    None
  } else {
    // Non-negative by the check above, so the bit-cast is the value.
    Some(ticks.reinterpret_as_uint64())
  }
}

///|
/// Clock ticks per second (sysconf(_SC_CLK_TCK)), the divisor for cpu ticks.
pub fn clk_tck() -> Int32 {
  c_clk_tck()
}
