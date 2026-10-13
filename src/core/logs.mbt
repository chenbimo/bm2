///|
/// One log file rotates once it exceeds this size; ten generations are
/// kept, bounding total log usage per file at ~100 MB.
const LOG_ROTATE_BYTES : Int64 = 10L * 1024L * 1024L

///|
/// How often the daemon checks log sizes for rotation.
const LOG_CHECK_INTERVAL_MS : UInt64 = 10000UL

///|
/// Ask the rotation task to sweep the logs that are past the size limit: app
/// stdout/stderr are held open by the app process (copytruncate), crash logs
/// and the daemon event logs are written by us (rename).
///
/// Building this list is pure string work. The sizes, the copy and the rename
/// all happen on the rotation task, so the tick never touches the filesystem
/// for rotation at all — a ten-megabyte copy on a slow disk cannot delay a
/// deadline, a delivery or an accept.
fn Supervisor::publish_rotation(self : Supervisor) -> Unit {
  let jobs : Array[(String, Bool)] = []
  for pair in self.instances.iter() {
    let (name, arr) = pair
    for inst in arr {
      let base = "\{self.state_dir}/\{name}/logs/\{name}-\{inst.instance_id}"
      jobs.push((base + ".out.log", true))
      jobs.push((base + ".error.log", true))
      jobs.push((base + ".crash.log", false))
    }
  }
  jobs.push(("\{self.state_dir}/bm2d.events.jsonl", false))
  // The other two daemon-level logs have no other writer that could bound
  // them: the CLI's own event log grows one line per invocation, and the
  // daemon's stderr is held open by the daemon itself (so it rotates by
  // copytruncate, the same trade-off as the app logs).
  jobs.push(("\{self.state_dir}/bm2.events.jsonl", false))
  jobs.push(("\{self.state_dir}/bm2d.log", true))
  // Capacity one, dropping put: a sweep the rotation task has not picked up yet
  // is superseded by this one, which re-checks every path anyway.
  @utils.discard(() => ignore(self.rotations.try_put(jobs)))
}

///|
/// Append one line to the instance crash log. The log is the operator's
/// only record of why an instance was restarted or parked in errored, so
/// it stays a plain text line rather than a nested structure.
fn Supervisor::write_crash(
  self : Supervisor,
  inst : Instance,
  reason : String,
) -> Unit {
  let buf = StringBuilder()
  buf.write_string("app=" + inst.app_name)
  buf.write_string(" instance=" + inst.instance_id.to_string())
  buf.write_string(" pid=" + inst.pid.to_string())
  buf.write_string(" reason=" + reason)
  match inst.last_exit_code {
    Some(code) => buf.write_string(" exitCode=" + code.to_string())
    None => ()
  }
  match inst.last_signal {
    Some(sig) => buf.write_string(" signal=" + signal_name(sig))
    None => ()
  }
  if reason == "memory_limit" {
    buf.write_string(" rssMb=" + (inst.last_rss_kb / 1024).to_string())
    let limit = match self.apps.get(inst.app_name) {
      Some(app) => app.max_memory_mb.to_string()
      None => "-"
    }
    buf.write_string(" limitMb=" + limit)
  }
  buf.write_string(" restartCount=" + inst.restart_count.to_string())
  let path = "\{self.state_dir}/\{inst.app_name}/logs/\{inst.app_name}-\{inst.instance_id}.crash.log"
  @utils.discard(() => @log.plain(path, buf.to_string()))
}
