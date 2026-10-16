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
/// 实例表交给 `chensuiyi/clitable` 渲染。
///
/// 列宽按显示宽度算，CJK 等全角字符占两列，这套算法不在 bm2 手写：那是
/// Unicode 数据的活，交给专门维护它的库做。ID、PID、PORT、TIMES 是数字列，
/// 右对齐；列的位置与语言无关，所以按下标声明。
///
/// `render()` 只在两种情况下报错：行数与列数不符，或者人为约束过总宽。
/// 这里两条都踩不到——行的构造就在上方，逐列填齐，总宽也没约束过。契约是
/// `raise`，所以不能吞：抓到了把原因打到 stderr 再离开。
fn render_table(header : Array[String], rows : Array[Array[String]]) -> String {
  let cols : Array[@clitable.Column] = []
  for i in 0..<header.length() {
    let col = @clitable.Column::new(header[i])
    if i == 1 || i == 2 || i == 3 || i == 8 {
      cols.push(col.align(@clitable.Right))
    } else {
      cols.push(col)
    }
  }
  try @clitable.Table::new(cols).push_rows(rows).render() catch {
    e => {
      let reason = match e {
        @clitable.TableError::Arity(rows_, cells_) =>
          "row count \{rows_} and cell count \{cells_} do not match"
        @clitable.TableError::TooNarrow(width_) =>
          "the table does not fit into \{width_} columns"
      }
      @proc.eprintln("bm2: instance table render failed: \{reason}")
      ""
    }
  } noraise {
    out => out
  }
}

///|
/// 守护进程摘要：一行标签做表头，一行数值做数据，同一张表里八条信息。
/// 表头来自翻译函数，换语言跟着变；宽度与对齐由 clitable 保证。
///
/// 数值条数必须与列数一致：clitable 不做静默补齐，少了会当场报 Arity。
fn render_summary(head : Array[String], values : Array[String]) -> String {
  let cols : Array[@clitable.Column] = []
  for label in head {
    cols.push(@clitable.Column::new(label))
  }
  try @clitable.Table::new(cols).push_rows([values]).render() catch {
    e => {
      let reason = match e {
        @clitable.TableError::Arity(rows_, cells_) =>
          "row count \{rows_} and cell count \{cells_} do not match"
        @clitable.TableError::TooNarrow(width_) =>
          "the table does not fit into \{width_} columns"
      }
      @proc.eprintln("bm2: daemon summary render failed: \{reason}")
      ""
    }
  } noraise {
    out => out
  }
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
  // 标签行与数值行分开收集：表头来自翻译函数，数值行是采集结果本身，
  // MB 这类单位跟着数值走，不进表头。
  let labels = @i18n.daemon_labels(lang)
  let values = [
    info.pid.to_string(),
    fds.to_string(),
    (rss / 1024).to_string() + " MB",
    @utils.human_duration(info.uptime_ms, pad=true),
    info.instances.to_string(),
    info.commands_applied.to_string(),
    info.pending_restarts.to_string(),
    info.pending_removals.to_string(),
  ]
  println(render_summary(labels, values))
}
