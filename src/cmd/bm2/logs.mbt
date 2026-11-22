///|
/// `bm2 logs <项目> [-e] [-f]`：看项目的日志。
///
/// 一个项目只有两个文件（普通 + 错误），所有实例合并写在一起，所以这里不需要
/// 聚合、不需要猜实例，也不用算今天几号：直接 tail 那两个文件。

///|
/// 跟随一个文件到中断为止。返回类型是 Unit，与 `bm2 dev` 的跟随同一个形状。
///
/// 轮转不用在这里判断：`print_new` 发现文件变短就说明换过文件，从 0 接着读。
fn follow_one(file : String, name : String, lang : @i18n.Lang) -> Unit {
  @proc.print(@i18n.follow_started(lang, name))
  let mut seen = print_tail(file)
  while true {
    @proc.sleep_ms(FOLLOW_POLL_MS)
    seen = print_new(file, seen)
    if @proc.interrupted() != 0 {
      @proc.print(@i18n.follow_stopped(lang, name))
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
  let dir = @core.project_logs_dir(state_dir, name)
  let file = if error_only {
    @utils.join_path(dir, name + ".error.log")
  } else {
    @utils.join_path(dir, name + ".log")
  }
  if !@fs.path_exists(file) {
    @proc.eprintln(@i18n.logs_missing(lang, name))
    return 1
  }
  if follow {
    follow_one(file, name, lang)
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
