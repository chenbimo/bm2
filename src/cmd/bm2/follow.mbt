///|
/// 跟随一个开发会话的日志,直到用户打断。
///
/// `bm2 dev` 只跑一个实例,所以正好两个文件要盯,而且就是 `serve` 写的那两个——
/// 日志不是另起一套机制,它就是应用自己的输出落在盘上。跟随只是看着,不是牵着:
/// Ctrl+C 只停止跟随,应用继续跑,所以第一行就告诉你怎么停它。
///
/// 起点是文件的当前末尾,免得一个会话把昨天的输出重播一遍。但会先补上末尾几行,
/// 因为"启动就崩了"恰好是开发者最需要看见的,而它可能发生在 start 请求返回与第一次
/// 读取之间。
const FOLLOW_LINES : Int32 = 10

///|
/// 轮询间隔。开发时人眼盯着终端,20 毫秒和 200 毫秒没有区别,而后者的空转开销
/// 小得可以忽略。
const FOLLOW_POLL_MS : Int32 = 200

///|
/// 每多少次轮询查一次项目还在不在(约 5 秒)。
const FOLLOW_CHECK_EVERY : Int32 = 25

///|
fn follow_logs(state_dir : String, name : String, lang : @i18n.Lang) -> Unit {
  let out_path = "\{state_dir}/\{name}/logs/\{name}-0.out.log"
  let err_path = "\{state_dir}/\{name}/logs/\{name}-0.error.log"
  // Written with the unbuffered writer: stdout to a pipe or a file is fully
  // buffered, so a session interrupted before the buffer flushed would lose the
  // one line that says what this command is doing.
  @proc.print(@i18n.follow_started(lang, name))
  let mut out_seen = print_tail(out_path)
  let mut err_seen = print_tail(err_path)
  let marker = "\{state_dir}/\{name}/project.json"
  let mut round = 0
  while true {
    @proc.sleep_ms(FOLLOW_POLL_MS)
    out_seen = print_new(out_path, out_seen)
    err_seen = print_new(err_path, err_seen)
    if @proc.interrupted() != 0 {
      @proc.print(@i18n.follow_stopped(lang, name))
      return
    }
    round += 1
    if round % FOLLOW_CHECK_EVERY == 0 && !@fs.path_exists(marker) {
      @proc.print(@i18n.follow_gone(lang, name))
      return
    }
  }
}

///|
/// 打印末尾若干行,返回文件当前长度作为下次的起点。
fn print_tail(path : String) -> Int32 {
  let text = read_if_exists(path)
  let n = text.length()
  if n > 0 {
    @proc.print(text[tail_start(text, FOLLOW_LINES):].to_owned())
  }
  n
}

///|
/// 打印上次之后新增的部分并返回新的长度。文件变短(被清空或重建)时从头算起,
/// 不假装什么都没发生。
///
/// 每次都是整读再切片:`moonbitlang/x/fs` 没有按偏移读的接口。日志上限由 `[logs]`
/// 的轮转兜住,而开发日志是人看的量级,所以这点重复读换来的是这里一个分支都不用写。
fn print_new(path : String, seen : Int32) -> Int32 {
  let text = read_if_exists(path)
  let n = text.length()
  if n < seen {
    @proc.print(text)
  } else if n > seen {
    @proc.print(text[seen:].to_owned())
  }
  n
}

///|
/// 末尾 `lines` 行的起始下标,按 UTF-16 码元计,和 `String::length` 同一套坐标系,
/// 这样切片与偏移永远对得上。
fn tail_start(text : String, lines : Int32) -> Int32 {
  let n = text.length()
  let mut index = n
  let mut seen = 0
  while index > 0 && seen < lines {
    index -= 1
    if text[index] == '\n' {
      seen += 1
    }
  }
  if index < n && text[index] == '\n' {
    index += 1
  }
  index
}

///|
/// 文件不在就当作空:开发会话刚起步时日志还没落盘是常态,不是错误。
fn read_if_exists(path : String) -> String {
  try @fs.read_file_to_string(path) catch {
    _ => ""
  } noraise {
    text => text
  }
}
