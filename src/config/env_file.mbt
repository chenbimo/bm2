///|
/// `.env` 文件的解析器。语义跟随 motdotla/dotenv——Node 生态里 dotenv 的事实标准,
/// 这样我们的边界和生态一致,而不是自己发明一套方言。
///
/// 支持:
/// - `KEY=VALUE`,值两侧的空白会被去掉
/// - `export KEY=VALUE`(标准允许这个前缀)
/// - 单引号与双引号包裹的值;引号内的换行算值的一部分,可以跨行
/// - 双引号内 `\n` `\t` `\r` `\\` `\"` 转义;单引号内一律字面
/// - `#` 注释:整行,或未加引号的值后面以空白开头的行尾注释(`a#b` 里的 `#` 是值)
/// - 空值 `KEY=`
/// - 重复键后者覆盖前者(标准行为)
///
/// 明确不做 `${VAR}` 展开:标准里那是独立的一层(dotenv-expand),不在 parse 的职责
/// 内,而且 bm2 不该替应用做展开——应用自己会展开。
///
/// 出错即拒绝,并点明文件与行号。静默吃掉一行非法内容,比启动失败难查得多。
pub fn parse_env_file(
  text : String,
  path : String,
) -> Map[String, String] raise ConfigError {
  let out : Map[String, String] = Map([])
  let n = text.length()
  let mut i = 0
  let mut line = 1
  while i < n {
    i = skip_spaces(text, i)
    if i >= n {
      break
    }
    if text[i] == '\n' {
      i += 1
      line += 1
      continue
    }
    if text[i] == '\r' {
      i += 1
      continue
    }
    if text[i] == '#' {
      let (next, next_line) = skip_line(text, i, line)
      i = next
      line = next_line
      continue
    }
    if has_export_prefix(text, i) {
      i = skip_spaces(text, i + 6)
    }
    let key_start = i
    while i < n && is_key_char(text[i]) {
      i += 1
    }
    let key = text[key_start:i].to_owned()
    if key.is_empty() {
      raise ConfigError::InvalidDocument(
        at_line(path, line) + "expected a variable name",
      )
    }
    if !valid_env_name(key) {
      raise ConfigError::InvalidDocument(
        at_line(path, line) + "invalid variable name: " + key,
      )
    }
    i = skip_spaces(text, i)
    if i >= n || text[i] != '=' {
      raise ConfigError::InvalidDocument(
        at_line(path, line) + "expected '=' after " + key,
      )
    }
    i = skip_spaces(text, i + 1)
    let value = if i < n && (text[i] == '"' || text[i] == '\'') {
      let (parsed, next, next_line) = read_quoted(text, i, line, path)
      i = skip_spaces(text, next)
      let (after, after_line) = if i < n && text[i] == '#' {
        skip_line(text, i, next_line)
      } else {
        (i, next_line)
      }
      if after < n && text[after] != '\n' && text[after] != '\r' {
        raise ConfigError::InvalidDocument(
          at_line(path, after_line) + "unexpected text after a quoted value",
        )
      }
      i = after
      line = after_line
      parsed
    } else {
      let value_start = i
      while i < n && text[i] != '\n' && text[i] != '\r' {
        i += 1
      }
      let raw = strip_inline_comment(text[value_start:i].to_owned())
      let (next, next_line) = skip_line(text, i, line)
      i = next
      line = next_line
      raw.trim().to_owned()
    }
    out[key] = value
  }
  out
}

///|
/// `路径 line N: ` 前缀。错误信息里必须带得动这两样:哪个文件、哪一行。
fn at_line(path : String, line : Int32) -> String {
  path + " line " + line.to_string() + ": "
}

///|
/// 键名允许的字符。与 `valid_env_name` 的分工:这里负责"到哪结束",它负责"整体合不合法"。
/// 下标取出的是 UInt16,ASCII 判断用不着转 Char。
fn is_key_char(c : UInt16) -> Bool {
  let v = c.to_int()
  (v >= 65 && v <= 90) ||
  (v >= 97 && v <= 122) ||
  (v >= 48 && v <= 57) ||
  v == 95
}

///|
/// 只跳空格与制表符,不跳换行——换行是行的边界,由主循环处理。
fn skip_spaces(text : String, from : Int32) -> Int32 {
  let n = text.length()
  let mut i = from
  while i < n && (text[i] == ' ' || text[i] == '\t') {
    i += 1
  }
  i
}

///|
/// 跳到行尾之后,并在跨过换行时把行号加一。返回 (新下标, 新行号)。
fn skip_line(text : String, from : Int32, line : Int32) -> (Int32, Int32) {
  let n = text.length()
  let mut i = from
  while i < n && text[i] != '\n' {
    i += 1
  }
  if i < n {
    (i + 1, line + 1)
  } else {
    (i, line)
  }
}

///|
/// `export` 前缀必须正好是一个词:后面跟空白。`exportFOO=1` 的键是 `exportFOO`。
fn has_export_prefix(text : String, at : Int32) -> Bool {
  if at + 6 >= text.length() {
    return false
  }
  if text[at:at + 6].to_owned() != "export" {
    return false
  }
  let after = text[at + 6]
  after == ' ' || after == '\t'
}

///|
/// 读一个引号包裹的值。引号内允许换行,所以返回新的下标与行号。
///
/// 内容用切片拼接而不是逐字符写入:普通字符一直累积到下一个需要处理的位置(闭合
/// 引号或转义符)再一次性追加,省掉每字符一次写入,也避开 UInt16 与 Char 的转换。
fn read_quoted(
  text : String,
  from : Int32,
  line : Int32,
  path : String,
) -> (String, Int32, Int32) raise ConfigError {
  let n = text.length()
  let quote = text[from]
  let double = quote == '"'
  let buf = StringBuilder()
  let mut i = from + 1
  let mut run = i
  let mut current_line = line
  while i < n {
    let c = text[i]
    if c == '\n' {
      current_line += 1
      i += 1
      continue
    }
    if c == quote {
      buf.write_string(text[run:i].to_owned())
      return (buf.to_string(), i + 1, current_line)
    }
    if double && c == '\\' && i + 1 < n {
      let replacement : String? = match text[i + 1] {
        'n' => Some("\n")
        't' => Some("\t")
        'r' => Some("\r")
        '\\' => Some("\\")
        '"' => Some("\"")
        _ => None
      }
      match replacement {
        Some(decoded) => {
          buf.write_string(text[run:i].to_owned())
          buf.write_string(decoded)
          i += 2
          run = i
          continue
        }
        // 不认识的转义原样保留:退回一个字符,让它留在将要追加的片段里。
        None => {
          i += 1
          continue
        }
      }
    }
    i += 1
  }
  raise ConfigError::InvalidDocument(
    at_line(path, line) + "unterminated quote opened here",
  )
}

///|
/// 去掉未加引号值后面的行尾注释。标准要求 `#` 前面有空白才算注释,所以 `a#b` 是值。
fn strip_inline_comment(raw : String) -> String {
  let n = raw.length()
  let mut i = 0
  while i < n {
    if raw[i] == '#' && i > 0 && (raw[i - 1] == ' ' || raw[i - 1] == '\t') {
      return raw[0:i].to_owned()
    }
    i += 1
  }
  raw
}

///|
/// Scan a project directory for its `.env` files and merge them into one map.
///
/// Precedence, lowest to highest — the same order bun documents, and the reason
/// bm2 reads these files itself instead of hoping two runtimes agree:
/// `.env` → `.env.<mode>` → `.env.local` → `.env.<mode>.local`.
///
/// A missing file is normal (most projects have one or two of the four); a file
/// that exists but cannot be read, or parses badly, is a hard error. Swallowing
/// either would turn "this deploy lost its credentials" into a silent afternoon.
pub fn scan_env_files(
  dir : String,
  mode : Mode,
) -> Map[String, String] raise ConfigError {
  let merged : Map[String, String] = Map([])
  let names : Array[String] = [
    ".env",
    ".env." + mode.as_string(),
    ".env.local",
    ".env." + mode.as_string() + ".local",
  ]
  for name in names {
    let path = dir + "/" + name
    if !@fs.path_exists(path) {
      continue
    }
    let text = try @fs.read_file_to_string(path) catch {
      _ => raise ConfigError::InvalidDocument("cannot read env file: " + path)
    } noraise {
      content => content
    }
    for pair in parse_env_file(text, path).iter() {
      let (key, value) = pair
      merged[key] = value
    }
  }
  merged
}
