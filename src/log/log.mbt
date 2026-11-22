///|
/// Append one plain text line, prefixed with the current ISO timestamp:
/// `2026-10-03T08:15:30.123Z <text>`. Failures raise so the caller stays
/// in charge of best-effort handling.
pub fn plain(path : String, text : String) -> Unit raise @fsx.FileError {
  @fsx.append_file(
    path,
    @utf8.encode(@utils.iso8601(@utils.now_ms()) + " " + text + "\n"),
  )
}

///|
/// Append one management event, in the same shape as every other log line:
///
/// ```text
/// 2026-11-22T10:55:48.536Z instance_exited app=demo instance=0 detail=exit_code=1
/// ```
///
/// 与项目日志同一种格式（时间 + 内容），所以 `tail`、编辑器高亮、`grep` 都按
/// 一套规则来。事件名与字段名保持语言中立，脚本按 ` event_name ` 精确匹配，
/// 再按 `key=value` 取值。值里有空格或引号才加双引号。
pub fn event(
  path : String,
  event : String,
  fields : Array[(String, String)],
) -> Unit raise @fsx.FileError {
  let buf = StringBuilder()
  buf.write_string(@utils.iso8601(@utils.now_ms()))
  buf.write_string(" ")
  buf.write_string(event)
  for pair in fields {
    let (key, value) = pair
    buf.write_string(" ")
    buf.write_string(key)
    buf.write_char('=')
    if needs_quotes(value) {
      buf.write_char('"')
      buf.write_string(value.replace_all(old="\"", new="\\\""))
      buf.write_char('"')
    } else {
      buf.write_string(value)
    }
  }
  buf.write_char('\n')
  @fsx.append_file(path, @utf8.encode(buf.to_string()))
}

///|
/// 值里有空格、引号或等号时才加引号，让最常见的行保持最少标点。
fn needs_quotes(text : String) -> Bool {
  text.contains(" ") ||
  text.contains("\"") ||
  text.contains("=") ||
  text.contains("\t")
}
