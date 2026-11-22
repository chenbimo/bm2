///|
/// 把实例暂存日志搬进项目日志。
///
/// 应用一直往 `.tempLogs/<项目>-<实例>.out.log` 追加（截断是安全的：spawn 时
/// 用 O_APPEND 打开，清空之后下一次写自动落在偏移 0）。搬运靠「先落盘副本、
/// 再清空源、最后处理副本」三步：
///
/// 1. 读源 → 写成 `.copy`（先写 `.tmp` 再 rename，半截副本不会被当成完整的）
/// 2. 清空源；清空之前再核一次大小，期间写进来的字节记成丢弃
/// 3. 逐行处理 `.copy` 写进主日志，成功后再删掉
///
/// 任何一步崩了都能重来：副本还在就处理副本，源还在就重做副本，不会丢也不会重复。

///|
/// 一次搬运的结果：搬了多少行、清了源之后又写进来多少字节（丢弃）。
pub(all) struct DrainResult {
  lines : Int32
  dropped_bytes : Int32
}

///|
/// 读一个副本文件，逐行加前缀写进日志流，然后删掉副本。返回写了几行。
async fn flush_copy(
  copy : String,
  stream : LogStream,
  prefix : String,
) -> Int32 {
  let data = try @fs.read_binary(copy) catch {
    _ => return 0
  } noraise {
    bytes => bytes
  }
  if data.length() == 0 {
    ignore(
      try @fs.remove(copy, allow_missing=true) catch {
        _ => ()
      } noraise {
        _ => ()
      },
    )
    return 0
  }
  let text = @utf8.decode_lossy(data)
  let mut count = 0
  // 攒够一块再落盘：逐行 open/write/close 在十万行级别会慢到肉眼可见。
  // 块只有 64KB，字符串拼接的拷贝成本远小于系统调用。
  let mut block = ""
  for piece in text.split("\n") {
    let line = piece.to_owned()
    // split 会在结尾多给一个空串；应用写的空行本身没有内容，跳过。
    if line == "" {
      continue
    }
    block = block + @utils.iso8601(@utils.now_ms()) + " " + prefix + line + "\n"
    count += 1
    if block.length() >= BLOCK_BYTES {
      stream.append(block)
      block = ""
    }
  }
  if block.length() > 0 {
    stream.append(block)
  }
  ignore(
    try @fs.remove(copy, allow_missing=true) catch {
      _ => ()
    } noraise {
      _ => ()
    },
  )
  count
}

///|
/// 搬一个暂存文件。`prefix` 是行前缀（`[0] ` 或 `[bm2] `）。
async fn drain_staging(
  staging : String,
  stream : LogStream,
  prefix : String,
) -> DrainResult {
  let copy = staging + ".copy"
  let mut lines = 0
  let mut dropped = 0
  // 上一轮留下的副本先处理：它是已经确认落盘的数据，比源更该先搬。
  let has_copy = try @fs.exists(copy) catch {
    _ => false
  } noraise {
    v => v
  }
  if has_copy {
    lines += flush_copy(copy, stream, prefix)
  }

  let has_source = try @fs.exists(staging) catch {
    _ => false
  } noraise {
    v => v
  }
  if !has_source {
    return { lines, dropped_bytes: dropped, }
  }
  let data = try @fs.read_binary(staging) catch {
    _ => return { lines, dropped_bytes: dropped, }
  } noraise {
    bytes => bytes
  }
  if data.length() == 0 {
    return { lines, dropped_bytes: dropped, }
  }

  // 落盘副本：先 .tmp 再 rename，避免半截文件被当成完整副本。
  let staged = copy + ".tmp"
  ignore(
    try {
      @fs.write_binary(
        staged,
        data,
        create_mode=@fs.CreateOrTruncate,
        permission=0o600,
        sync=@fs.NoSync,
      )
      @fs.rename(staged, copy, replace=true)
      true
    } catch {
      _ => false
    } noraise {
      _ => true
    },
  )

  // 清空源。清之前核一次大小：比刚读到的多，说明期间又写了，那部分留不住。
  let read_len = data.length().to_int64()
  let after = try @fs.file_size(staging) catch {
    _ => read_len
  } noraise {
    n => n
  }
  if after > read_len {
    dropped = (after - read_len).to_int()
  }
  ignore(
    try
      @fs.write_binary(
        staging,
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

  lines += flush_copy(copy, stream, prefix)
  { lines, dropped_bytes: dropped, }
}

///|
/// 把某个项目所有实例的暂存日志搬进两条主日志。`staging_dir` 是
/// `.tempLogs`，`name` 是项目名，两条流的目录与配置由调用方给。
///
/// 返回 (行数, 丢弃字节)，调用方只在有丢弃时记一条事件。
pub async fn drain_project(
  staging_dir : String,
  name : String,
  normal : LogStream,
  error : LogStream,
) -> DrainResult {
  let names = try @fs.readdir(staging_dir, sort=true) catch {
    _ => return { lines: 0, dropped_bytes: 0, }
  } noraise {
    entries => entries
  }
  let prefix = name + "-"
  let mut lines = 0
  let mut dropped = 0
  for entry in names {
    if !entry.has_prefix(prefix) || !entry.has_suffix(".log") {
      continue
    }
    // `<项目>-<实例>.out.log` / `.err.log`
    let rest = entry[prefix.length():].to_owned()
    let is_error = rest.has_suffix(".err.log")
    let is_normal = rest.has_suffix(".out.log")
    if !is_error && !is_normal {
      continue
    }
    let tail = if is_error { ".err.log" } else { ".out.log" }
    let inst = rest[:rest.length() - tail.length()].to_owned()
    let result = drain_staging(
      @utils.join_path(staging_dir, entry),
      if is_error {
        error
      } else {
        normal
      },
      "[" + inst + "] ",
    )
    lines += result.lines
    dropped += result.dropped_bytes
  }
  { lines, dropped_bytes: dropped, }
}
