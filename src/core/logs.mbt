///|
/// One log file rotates once it exceeds this size; ten generations are
/// kept, bounding total log usage per file at ~100 MB.
const LOG_ROTATE_BYTES : Int64 = 10L * 1024L * 1024L

///|
/// How often the daemon checks log sizes for rotation.
const LOG_CHECK_INTERVAL_MS : UInt64 = 10000UL

///|
/// Rotate logs past the size limit: app stdout/stderr are held open by
/// the app process (copytruncate), crash logs and the daemon event log
/// are written by us (rename). Failures are logged, never fatal.
fn Supervisor::rotate_logs(self : Supervisor) -> Unit {
  for pair in self.instances.iter() {
    let (name, arr) = pair
    for inst in arr {
      let base = "\{self.state_dir}/\{name}/logs/\{name}-\{inst.instance_id}"
      self.rotate_log(base + ".out.log", copytruncate=true)
      self.rotate_log(base + ".error.log", copytruncate=true)
      self.rotate_log(base + ".crash.log", copytruncate=false)
    }
  }
  self.rotate_log("\{self.state_dir}/bm2d.events.jsonl", copytruncate=false)
}

///|
fn Supervisor::rotate_log(
  self : Supervisor,
  path : String,
  copytruncate~ : Bool,
) -> Unit {
  match @process.file_size(path) {
    Some(size) if size > LOG_ROTATE_BYTES =>
      try {
        if copytruncate {
          @process.copytruncate(path)
        } else {
          @process.rotate(path)
        }
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "log_rotated",
          detail=path,
        )
      } catch {
        e =>
          log_event(
            self.state_dir,
            "bm2d.events.jsonl",
            "log_rotate_failed",
            detail=path + ": " + e.to_string(),
          )
      } noraise {
        _ => ()
      }
    _ => ()
  }
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
  buf.write_string(iso8601(now_ms()))
  buf.write_string(" app=" + inst.app_name)
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
  buf.write_string("\n")
  let path = "\{self.state_dir}/\{inst.app_name}/logs/\{inst.app_name}-\{inst.instance_id}.crash.log"
  @process.discard(() => {
    @process.append_file(path, @utf8.encode(buf.to_string()))
  })
}
