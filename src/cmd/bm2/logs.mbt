///|
/// `bm2 logs <项目> [-e] [-f]`：看当天那份日志。
///
/// 一个项目每天只有两个文件（普通 + 错误），所以这里不需要聚合、不需要猜
/// 实例：直接 tail 当天那份。`-f` 沿用 `bm2 dev` 的跟随逻辑。

///|
/// 跟随一个文件到中断为止。返回类型是 Unit，与 `bm2 dev` 的跟随同一个形状。
fn follow_one(
  file : String,
  name : String,
  day : String,
  lang : @i18n.Lang,
) -> Unit {
  @proc.print(@i18n.follow_started(lang, name))
  let mut seen = print_tail(file)
  while true {
    @proc.sleep_ms(FOLLOW_POLL_MS)
    seen = print_new(file, seen)
    if @proc.interrupted() != 0 {
      @proc.print(@i18n.follow_stopped(lang, name))
      return
    }
    // 跨天了就停在这里：新一天的日志是另一个文件，接着跟会读到旧 inode。
    if @core.local_day(@utils.now_ms()) != day {
      @proc.eprintln(@i18n.logs_missing(lang, name, day))
      return
    }
  }
}

///|
pub fn cmd_logs(
  state_dir : String,
  name : String,
  error_only : Bool,
  follow : Bool,
  lang : @i18n.Lang,
) -> Int32 {
  let day = @core.local_day(@utils.now_ms())
  let dir = @core.project_logs_dir(state_dir, name)
  let file = if error_only {
    dir + "/" + name + "-" + day + ".error.log"
  } else {
    dir + "/" + name + "-" + day + ".log"
  }
  if !@fs.path_exists(file) {
    @proc.eprintln(@i18n.logs_missing(lang, name, day))
    return 1
  }
  if follow {
    follow_one(file, name, day, lang)
    return 0
  }
  let text = try @fs.read_file_to_string(file) catch {
    _ => ""
  } noraise {
    content => content
  }
  @proc.print(text)
  0
}
