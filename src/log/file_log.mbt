///|
/// 一个日志流 = 一组「按天 + 按大小」切分的文件。
///
/// 文件命名（`base` 是项目名，`kind` 是空串或 ".error"）：
///
/// ```text
/// api-2026-11-22.log            当天普通日志，正在写
/// api-2026-11-22.1.log          当天第 1 个分片（更旧）
/// api-2026-11-22.error.log      当天错误日志
/// api-2026-11-22.error.1.log
/// ```
///
/// 主日志只有 bm2 一个写者，所以轮转用 rename 换文件，不 copytruncate，
/// 换文件那一刻写进来的字节不会丢。
///
/// 全部操作走异步文件 API：跑在收集任务里，永远不占 tick。

///|
/// 一条日志流的写状态：当前写到哪个文件、它多大。
pub struct LogStream {
  dir : String
  base : String
  /// 空串是普通日志，".error" 是错误日志。
  kind : String
  max_bytes : Int64
  /// 保留最近几个「有日志的日期」。0 表示不清理。
  keep_days : Int32
  /// 当前正在写的日期（`2026-11-22`），空串表示还没写过。
  mut day : String
  mut path : String
  mut size : Int64
}

///|
pub fn LogStream::new(
  dir : String,
  base : String,
  kind : String,
  max_bytes : Int64,
  keep_days : Int32,
) -> LogStream {
  { dir, base, kind, max_bytes, keep_days, day: "", path: "", size: 0L, }
}

///|
/// 某一天、第 `slice` 个分片的路径。`slice` 为 0 时是当天主文件。
pub fn LogStream::file_of(
  self : LogStream,
  day : String,
  slice : Int32,
) -> String {
  let stem = self.base + "-" + day + self.kind
  if slice == 0 {
    self.dir + "/" + stem + ".log"
  } else {
    self.dir + "/" + stem + "." + slice.to_string() + ".log"
  }
}

///|
/// 当前文件改名成 `.1`，旧的 `.1` 往后挪。从最远的分片往回搬，避免互相覆盖。
async fn LogStream::shift_chain(self : LogStream, day : String) -> Unit {
  let mut highest = 0
  for slice in 1..<10000 {
    let there = try @fs.exists(self.file_of(day, slice)) catch {
      _ => false
    } noraise {
      v => v
    }
    if !there {
      break
    }
    highest = slice
  }
  let mut index = highest
  while index >= 1 {
    ignore(
      try
        @fs.rename(
          self.file_of(day, index),
          self.file_of(day, index + 1),
          replace=true,
        )
      catch {
        _ => ()
      } noraise {
        _ => ()
      },
    )
    index -= 1
  }
  ignore(
    try
      @fs.rename(self.file_of(day, 0), self.file_of(day, 1), replace=true)
    catch {
      _ => ()
    } noraise {
      _ => ()
    },
  )
}

///|
/// 写一批行（每行已带换行）。写之前处理两件事：跨天换文件、超限换分片。
///
/// 成批写而不是逐行写：十万行逐行 open/write/close 就是十万次系统调用，
/// 成批之后按 64KB 一块，系统调用数量差三个数量级。
async fn LogStream::append(
  self : LogStream,
  day : String,
  block : String,
) -> Unit {
  if block.length() == 0 {
    return
  }
  let bytes = @utf8.encode(block)
  let new_day = day != self.day
  if new_day {
    self.day = day
    self.path = self.file_of(day, 0)
    self.size = try @fs.file_size(self.path) catch {
      _ => 0L
    } noraise {
      n => n
    }
  } else if self.size > 0L &&
    self.size + bytes.length().to_int64() > self.max_bytes {
    self.shift_chain(day)
    self.path = self.file_of(day, 0)
    self.size = 0L
  }
  let ok = try {
    @fs.write_binary(
      self.path,
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
/// 删掉多出来的日期文件：保留最近 `keep_days` 个「有日志的日期」，更早的连同
/// 分片一起删。按文件名里的日期分组，不 stat 文件时间。
///
/// 只处理本流自己的文件，另一条流由它自己清理。
pub async fn LogStream::prune(self : LogStream) -> Unit {
  if self.keep_days <= 0 {
    return
  }
  let names = try @fs.readdir(self.dir, sort=true) catch {
    _ => return
  } noraise {
    entries => entries
  }
  let prefix = self.base + "-"
  let days : Array[String] = []
  for name in names {
    if !name.has_prefix(prefix) || !name.has_suffix(".log") {
      continue
    }
    let rest = name[prefix.length():].to_owned()
    if rest.length() < 10 {
      continue
    }
    let day = rest[:10].to_owned()
    let tail = rest[10:].to_owned()
    // 普通流不能把 error 流的文件算进来，反之亦然。
    let mine = if self.kind == "" {
      !tail.has_prefix(".error")
    } else {
      tail.has_prefix(self.kind)
    }
    if mine && !days.contains(day) {
      days.push(day)
    }
  }
  if days.length() <= self.keep_days {
    return
  }
  days.sort()
  let drop = days.length() - self.keep_days
  for index in 0..<drop {
    let day = days[index]
    for name in names {
      let rest = if name.has_prefix(prefix) {
        name[prefix.length():].to_owned()
      } else {
        continue
      }
      if !rest.has_prefix(day) {
        continue
      }
      let tail = rest[day.length():].to_owned()
      let mine = if self.kind == "" {
        !tail.has_prefix(".error")
      } else {
        tail.has_prefix(self.kind)
      }
      if !mine {
        continue
      }
      ignore(
        try @fs.remove(self.dir + "/" + name, allow_missing=true) catch {
          _ => ()
        } noraise {
          _ => ()
        },
      )
    }
  }
}

///|
/// 一次落盘的块大小上限：够大能摊薄系统调用，够小不至于让单块轻易跨过
/// `max_size_mb` 的边界。
pub const BLOCK_BYTES : Int32 = 64 * 1024
