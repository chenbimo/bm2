///|
fn print_list(
  instances : Array[@protocol.InstanceInfo],
  lang : @i18n.Lang,
) -> Unit {
  if instances.length() == 0 {
    println(@i18n.no_instances(lang))
    return
  }
  // MODE is how the project was started (development / production); EXEC is how
  // its instances share the port (cluster / fork). Two different facts that both
  // answer "how is this running", and the column called MODE used to hold the
  // second one, so neither could be read off the table.
  let header = @i18n.list_headers(lang)
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
      @i18n.mode_value(lang, info.mode),
      @i18n.exec_value(lang, info.exec_mode),
      @i18n.status_value(lang, info.status),
      info.times.to_string(),
      memory,
      uptime,
      info.cwd,
    ])
  }
  println(render_table(header, rows))
}

///|
/// Render a table: every column is padded to its widest cell *as displayed*.
///
/// Widths come from `@utils.display_width`, not `String::length`. Length counts
/// UTF-16 code units, so a translated header like `运行时长` measured 4 while
/// occupying 8 columns, and the Chinese table came out ragged with everything
/// after it pulled left.
fn render_table(header : Array[String], rows : Array[Array[String]]) -> String {
  let widths : Array[Int32] = []
  for name in header {
    widths.push(@utils.display_width(name))
  }
  for row in rows {
    for i in 0..<row.length() {
      let width = @utils.display_width(row[i])
      if width > widths[i] {
        widths[i] = width
      }
    }
  }
  let lines = [table_line(header, widths)]
  for row in rows {
    lines.push(table_line(row, widths))
  }
  lines.join("\n")
}

///|
/// One table row. Every column is padded, the last included, so all lines of a
/// table are exactly as wide as each other — which is also what the test asserts.
fn table_line(cols : Array[String], widths : Array[Int32]) -> String {
  let buf = StringBuilder()
  for i in 0..<cols.length() {
    if i > 0 {
      buf.write_string("  ")
    }
    buf.write_string(@utils.pad_to(cols[i], widths[i]))
  }
  buf.to_string()
}

///|
/// Lay key/value pairs out in rows of `per_row` columns, each column as wide as its
/// widest cell, with the first row carrying the real prefix and the rest an indent
/// of the same width.
///
/// Written for the daemon summary: eight numbers that fit one line only by running
/// into each other, and in Chinese the labels and the English units made one soup.
fn render_pairs(
  pairs : Array[String],
  first_prefix : String,
  per_row : Int32,
) -> String {
  let rows = (pairs.length() + per_row - 1) / per_row
  let widths : Array[Int32] = []
  for i in 0..<per_row {
    let mut width = 0
    for r in 0..<rows {
      let index = r * per_row + i
      if index < pairs.length() {
        let cell = @utils.display_width(pairs[index])
        if cell > width {
          width = cell
        }
      }
    }
    widths.push(width)
  }
  let indent = @utils.pad_to("", first_prefix.length())
  let lines = []
  for r in 0..<rows {
    let buf = StringBuilder()
    buf.write_string(if r == 0 { first_prefix } else { indent })
    for i in 0..<per_row {
      let index = r * per_row + i
      if index >= pairs.length() {
        break
      }
      if i > 0 {
        buf.write_string("  ")
      }
      buf.write_string(@utils.pad_to(pairs[index], widths[i]))
    }
    lines.push(buf.to_string())
  }
  lines.join("\n")
}

///|
/// The daemon's own numbers, printed under the instance table: `list` is where an
/// operator looks first, and descriptor growth or a stalled command counter is
/// exactly what the table cannot show.
pub fn print_daemon(info : @protocol.DaemonInfo, lang : @i18n.Lang) -> Unit {
  let fds = try @fs.read_dir("/proc/\{info.pid}/fd").length() catch {
    _ => 0
  } noraise {
    count => count
  }
  let rss = match @proc.read_rss_kb(info.pid) {
    Some(kb) => kb
    None => 0
  }
  // Pairs, not one interpolated sentence: the summary is a row of numbers, and
  // only the few words around them have a translation.
  let labels = @i18n.daemon_labels(lang)
  let pairs = [
    "\{labels[0]} \{info.pid}",
    "\{labels[1]} \{fds}",
    "\{labels[2]} \{rss / 1024} \{labels[3]}",
    "\{labels[4]} \{@utils.human_duration(info.uptime_ms, pad=true)}",
    "\{labels[5]} \{info.instances}",
    "\{labels[6]} \{info.commands_applied}",
    "\{labels[7]} \{info.pending_restarts}",
    "\{labels[8]} \{info.pending_removals}",
  ]
  println(render_pairs(pairs, "daemon: ", 4))
}
