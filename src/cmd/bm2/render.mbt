///|
fn print_list(instances : Array[@protocol.InstanceInfo]) -> Unit {
  if instances.length() == 0 {
    println("no instances")
    return
  }
  let header = [
    "NAME", "ID", "PID", "PORT", "MODE", "STATUS", "TIMES", "MEMORY", "UPTIME", "CWD",
  ]
  let rows = []
  for info in instances {
    let pid = if info.pid > 0 { info.pid.to_string() } else { "-" }
    let memory = if info.rss_kb >= 0 {
      (info.rss_kb / 1024).to_string() + " MB"
    } else {
      "-"
    }
    let uptime = if info.pid > 0 {
      @utils.human_duration(info.uptime_ms, pad=true)
    } else {
      "-"
    }
    rows.push([
      info.app_name,
      info.instance_id.to_string(),
      pid,
      info.port.to_string(),
      info.exec_mode,
      info.status,
      info.times.to_string(),
      memory,
      uptime,
      info.cwd,
    ])
  }
  let widths = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  for i in 0..<header.length() {
    widths[i] = header[i].length()
  }
  for row in rows {
    for i in 0..<row.length() {
      if row[i].length() > widths[i] {
        widths[i] = row[i].length()
      }
    }
  }
  print_row(header, widths)
  for row in rows {
    print_row(row, widths)
  }
}

///|
fn print_row(cols : Array[String], widths : Array[Int32]) -> Unit {
  let buf = StringBuilder()
  for i in 0..<cols.length() {
    if i > 0 {
      buf.write_string("  ")
    }
    buf.write_string(cols[i])
    for _ in 0..<(widths[i] - cols[i].length()) {
      buf.write_string(" ")
    }
  }
  println(buf.to_string())
}

///|
/// The daemon's own numbers, printed under the instance table: `list` is where an
/// operator looks first, and descriptor growth or a stalled command counter is
/// exactly what the table cannot show.
pub fn print_daemon(info : @protocol.DaemonInfo) -> Unit {
  let fds = try @fs.read_dir("/proc/\{info.pid}/fd").length() catch {
    _ => 0
  } noraise {
    count => count
  }
  let rss = match @proc.read_rss_kb(info.pid) {
    Some(kb) => kb
    None => 0
  }
  println(
    "daemon: pid \{info.pid} fds \{fds} rss \{rss / 1024} MB uptime \{@utils.human_duration(info.uptime_ms, pad=true)} instances \{info.instances} commands \{info.commands_applied} restarts \{info.pending_restarts} removals \{info.pending_removals}",
  )
}
