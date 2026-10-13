///|
/// Bytes in a megabyte: the configured size is in megabytes, the rotation
/// compares it against a byte count.
const MIB : Int64 = 1024L * 1024L

///|
/// How often the daemon checks log sizes for rotation.
const LOG_CHECK_INTERVAL_MS : UInt64 = 10000UL

///|
/// Ask the rotation task to sweep the logs that are past their size limit: app
/// stdout/stderr are held open by the app process (copytruncate), crash logs
/// and the daemon event logs are written by us (rename).
///
/// Building this list is pure string work: each job carries the project's own
/// `[logs]` policy, and the sizes, the copy and the rename all happen on the
/// rotation task. So the tick never touches the filesystem for rotation at all —
/// a ten-megabyte copy on a slow disk cannot delay a deadline, a delivery or an
/// accept.
fn Supervisor::publish_rotation(self : Supervisor) -> Unit {
  let jobs : Array[@log.RotateJob] = []
  for pair in self.instances.iter() {
    let (name, arr) = pair
    // The project owns its rotation policy. A project registered before the
    // `[logs]` table existed, or one that omits it, gets the built-in policy.
    let policy = match self.config_of(name) {
      Some(app) => app.logs
      None => @config.LogsConfig::builtin()
    }
    let max_bytes = policy.max_size_mb.to_int64() * MIB
    for inst in arr {
      let base = "\{self.state_dir}/\{name}/logs/\{name}-\{inst.instance_id}"
      for
        suffix in [
          (".out.log", true),
          (".error.log", true),
          (".crash.log", false),
        ] {
        let (tail, copytruncate) = suffix
        jobs.push({
          path: base + tail,
          copytruncate,
          max_bytes,
          keep: policy.keep,
        })
      }
    }
  }
  // The daemon's own logs belong to no single project, so they use the built-in
  // policy. Two of them have no other writer that could bound them: the CLI's own
  // event log grows one line per invocation, and the daemon's stderr is held open
  // by the daemon itself (so it rotates by copytruncate, the same trade-off as
  // the app logs).
  let builtin = @config.LogsConfig::builtin()
  let daemon_bytes = builtin.max_size_mb.to_int64() * MIB
  let daemon_keep = builtin.keep
  for
    suffix in [
      ("bm2d.events.jsonl", false),
      ("bm2.events.jsonl", false),
      ("bm2d.log", true),
    ] {
    let (name, copytruncate) = suffix
    jobs.push({
      path: self.state_dir + "/" + name,
      copytruncate,
      max_bytes: daemon_bytes,
      keep: daemon_keep,
    })
  }
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
    let limit = match self.config_of(inst.app_name) {
      Some(app) => app.max_memory_mb.to_string()
      None => "-"
    }
    buf.write_string(" limitMb=" + limit)
  }
  buf.write_string(" restartCount=" + inst.restart_count.to_string())
  let path = "\{self.state_dir}/\{inst.app_name}/logs/\{inst.app_name}-\{inst.instance_id}.crash.log"
  @utils.discard(() => @log.plain(path, buf.to_string()))
}
