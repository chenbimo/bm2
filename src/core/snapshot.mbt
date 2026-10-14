///|
/// Live snapshot of one instance, taken by the supervisor and handed to the
/// protocol layer as plain data. Reading /proc lives here rather than in
/// protocol.mbt so the wire format stays free of side effects.
/// `now_mono` is monotonic milliseconds; rss_kb is -1 when unavailable and
/// uptime_ms is 0 when not running. `mode` belongs to the project rather than
/// to the instance, and is passed in for the same reason the instance's cwd is:
/// the row has to answer "how is this running?" on its own.
pub fn instance_info_of(
  inst : Instance,
  now_mono : UInt64,
  mode : String,
) -> @protocol.InstanceInfo {
  let rss_kb = if inst.status is Online {
    match @proc.read_rss_kb(inst.pid) {
      Some(kb) => kb
      None => -1
    }
  } else {
    -1
  }
  // Uptime is a duration, so it is measured on the monotonic clock: a system
  // time change can neither inflate nor hide how long an instance has run.
  let uptime_ms = if inst.pid > 0 && inst.started_mono_ms > 0UL {
    if now_mono >= inst.started_mono_ms {
      now_mono - inst.started_mono_ms
    } else {
      0UL
    }
  } else {
    0UL
  }
  {
    app_name: inst.app_name,
    mode,
    cwd: inst.cwd,
    instance_id: inst.instance_id,
    pid: inst.pid,
    port: inst.port,
    exec_mode: inst.exec_mode,
    status: inst.status.as_string(),
    times: inst.times,
    restart_count: inst.restart_count,
    rss_kb,
    uptime_ms,
    last_reason: inst.last_reason,
  }
}
