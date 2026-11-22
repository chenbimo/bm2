///|
/// 一个日志流 = 一组按大小切分的文件，不带日期维度。
///
/// 文件命名（`stem` 是 `<项目>` 或 `<项目>.error`）：
///
/// ```text
/// api.log                 当前在写
/// api.1.log               上一代（数字越大越旧）
/// api.2.log
/// api.error.log
/// api.error.1.log
/// ```
///
/// 代数两条流各算各的：普通日志用满不影响错误日志。
///
/// 项目日志只有 bm2 一个写者，轮转用 rename 换文件，不做 copytruncate，换文件
/// 那一刻写进来的字节不会丢。命名与 daemon 侧不同：那边是 `bm2d.events.log.1`
/// 这样的结尾后缀，这里把代数放在 `.log` 之前，同一项目的文件 `ls` 时挨在一起。
/// `keep = 0` 时直接清空当前文件，不留一个永远只剩一行的 `.1`
///
/// 全部操作走异步文件 API：跑在收集任务里，永远不占 tick。

///|
/// 一条日志流的写状态：写到哪个文件、它多大。
pub struct LogStream {
  dir : String
  /// 文件名主干，不含 `.log` 与代数，如 `api`、`api.error`。
  stem : String
  max_bytes : Int64
  /// 保留几代历史，0 表示不留。
  keep : Int32
  mut size : Int64
  /// 第一次写之前为 false：靠 stat 现有文件拿初始大小，进程重启后接着算。
  mut sized : Bool
}

///|
pub fn LogStream::new(
  dir : String,
  base : String,
  kind : String,
  max_bytes : Int64,
  keep : Int32,
) -> LogStream {
  { dir, stem: base + kind, max_bytes, keep, size: 0L, sized: false, }
}

///|
/// 当前在写的那个文件。
pub fn LogStream::path(self : LogStream) -> String {
  @utils.join_path(self.dir, self.stem + ".log")
}

///|
/// 第 `n` 代历史文件：`api.1.log`、`api.error.2.log`。代数是文件名中间的
/// 一段，不是结尾后缀——`ls` 排序时同一项目的文件挨在一起。
fn LogStream::generation(self : LogStream, n : Int32) -> String {
  @utils.join_path(self.dir, self.stem + "." + n.to_string() + ".log")
}

///|
/// 写一批行（每行已带换行）。写之前看一件事：加上这批会不会超限。
///
/// 成批写而不是逐行写：十万行逐行 open/write/close 就是十万次系统调用，
/// 成批之后按 64KB 一块，系统调用数量差三个数量级。
async fn LogStream::append(self : LogStream, block : String) -> Unit {
  if block.length() == 0 {
    return
  }
  let bytes = @utf8.encode(block)
  if !self.sized {
    self.sized = true
    self.size = try @fs.file_size(self.path()) catch {
      _ => 0L
    } noraise {
      n => n
    }
  }
  if self.size > 0L && self.size + bytes.length().to_int64() > self.max_bytes {
    self.rotate()
  }
  let ok = try {
    @fs.write_binary(
      self.path(),
      bytes,
      append=true,
      permission=0o600,
      sync=@fs.NoSync,
    )
    true
  } catch {
    _ => false
  } noraise {
    _ => true
  }
  if ok {
    self.size += bytes.length().to_int64()
  }
}

///|
/// 轮转：当前文件满 `max_bytes` 之后换一份空的。
async fn LogStream::rotate(self : LogStream) -> Unit {
  if self.keep <= 0 {
    // 不留历史：清空即可，否则会留下一个永远只有一行内容、之后再也用不上的 `.1`。
    ignore(
      try
        @fs.write_binary(
          self.path(),
          b"",
          create_mode=@fs.TruncateExisting,
          permission=0o600,
          sync=@fs.NoSync,
        )
      catch {
        _ => ()
      } noraise {
        _ => ()
      },
    )
  } else {
    self.shift()
  }
  self.size = 0L
}

///|
/// 整链后移一代：丢掉最旧的一份，`.n-1 → .n` 依次挪，当前文件变 `.1`。
///
/// 从最远处往回搬，避免互相覆盖；文件不存在就跳过，轮转不该因为「上一代本来就
/// 没有」而失败。
async fn LogStream::shift(self : LogStream) -> Unit {
  move_if_exists(self.generation(self.keep), "")
  let mut index = self.keep - 1
  while index >= 1 {
    move_if_exists(self.generation(index), self.generation(index + 1))
    index -= 1
  }
  move_if_exists(self.path(), self.generation(1))
}

///|
/// 改名；源不存在（或目标为空串表示删除）时安静跳过。
async fn move_if_exists(from : String, to : String) -> Unit {
  ignore(
    try {
      if to == "" {
        @fs.remove(from, allow_missing=true)
      } else {
        @fs.rename(from, to, replace=true)
      }
      true
    } catch {
      _ => false
    } noraise {
      _ => true
    },
  )
}

///|
/// 删掉超出代数的旧文件。正常轮转自己会收尾，这里只处理「配置被调小」那种
/// 情形：把 `keep` 改小之后，多出来的代数由每分钟一次的清理带走。
///
/// 只认纯数字后缀，所以这条流不会误删另一条流（`api.error.1.log` 对普通流
/// 来说后缀是 `error.1`，不是数字）。
pub async fn LogStream::prune(self : LogStream) -> Unit {
  let names = try @fs.readdir(self.dir, sort=false) catch {
    _ => return
  } noraise {
    entries => entries
  }
  let prefix = self.stem + "."
  for name in names {
    if !name.has_prefix(prefix) || !name.has_suffix(".log") {
      continue
    }
    let middle = name[prefix.length():name.length() - 4].to_owned()
    if middle.length() == 0 {
      continue
    }
    let mut value = 0
    let mut numeric = true
    for ch in middle {
      if ch is ('0'..<='9') {
        value = value * 10 + (ch.to_int() - 48)
      } else {
        numeric = false
        break
      }
    }
    if !numeric {
      continue
    }
    if self.keep > 0 && value <= self.keep {
      continue
    }
    ignore(
      try
        @fs.remove(@utils.join_path(self.dir, name), allow_missing=true)
      catch {
        _ => ()
      } noraise {
        _ => ()
      },
    )
  }
}

///|
/// 一次落盘的块大小上限：够大能摊薄系统调用，够小不至于让单块轻易跨过
/// `max_size_mb` 的边界。
pub const BLOCK_BYTES : Int32 = 64 * 1024
