///|
/// Live snapshot of one instance, taken by the supervisor and handed to the
/// protocol layer as plain data. Reading /proc lives here rather than in
/// protocol.mbt so the wire format stays free of side effects.
/// rss_kb is -1 when unavailable, uptime_ms is 0 when not running.
pub fn InstanceInfo::of(inst : Instance, now : UInt64) -> InstanceInfo {
  let rss_kb = if inst.status is Online {
    match @process.read_rss_kb(inst.pid) {
      Some(kb) => kb
      None => -1
    }
  } else {
    -1
  }
  // Saturating subtraction: a clock rollback must never show a huge uptime.
  let uptime_ms = if inst.pid > 0 && inst.started_at_ms > 0UL {
    if now >= inst.started_at_ms {
      now - inst.started_at_ms
    } else {
      0UL
    }
  } else {
    0UL
  }
  {
    app_name: inst.app_name,
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
