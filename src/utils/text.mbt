///|
const HEX_DIGITS : String = "0123456789ABCDEF"

///|
fn hex_pair(value : Int32) -> String {
  let high = value >> 4
  let low = value & 15
  HEX_DIGITS[high:high + 1].to_owned() + HEX_DIGITS[low:low + 1].to_owned()
}

///|
/// A JSON string literal: the text, escaped and wrapped in quotes. The escaping
/// comes from the standard library, which is the part worth not hand-writing: a
/// body carrying a quote or a control character must not be able to break out of
/// the literal, and an escaped alert body reaches a third-party platform
/// verbatim.
pub fn jstr(text : String) -> String {
  @json.to_json(text).stringify()
}

///|
/// Build a JSON object from already-encoded value fragments, so an optional
/// key simply does not appear instead of turning into a null the platform
/// may reject. Keys are quoted by `jstr`; values must arrive pre-encoded
/// (e.g. `jstr(...)` for strings, raw digits for numbers).
pub fn jobj(fields : Array[(String, String)]) -> String {
  let buf = StringBuilder()
  buf.write_char('{')
  let mut first = true
  for pair in fields {
    let (key, value) = pair
    if !first {
      buf.write_char(',')
    }
    first = false
    buf.write_string(jstr(key))
    buf.write_char(':')
    buf.write_string(value)
  }
  buf.write_char('}')
  buf.to_string()
}

///|
/// Build a JSON array from already-encoded item fragments.
pub fn jarr(items : Array[String]) -> String {
  let buf = StringBuilder()
  buf.write_char('[')
  let mut first = true
  for item in items {
    if !first {
      buf.write_char(',')
    }
    first = false
    buf.write_string(item)
  }
  buf.write_char(']')
  buf.to_string()
}

///|
fn is_unreserved(value : Int32) -> Bool {
  (value >= 48 && value <= 57) ||
  (value >= 65 && value <= 90) ||
  (value >= 97 && value <= 122) ||
  value == 45 ||
  value == 46 ||
  value == 95 ||
  value == 126
}

///|
/// Percent-encode a value for a URL query string or a form body: everything
/// outside the RFC 3986 unreserved set becomes `%XX` over UTF-8 bytes.
pub fn url_encode(text : String) -> String {
  let buf = StringBuilder()
  for byte in @utf8.encode(text) {
    let value = byte.to_int()
    if is_unreserved(value) {
      // Unreserved bytes are ASCII, so decoding one byte back gives the char.
      buf.write_string(@utf8.decode_lossy(Bytes::from_array([byte])))
    } else {
      buf.write_char('%')
      buf.write_string(hex_pair(value))
    }
  }
  buf.to_string()
}

///|
/// Split `text` on `sep` into owned strings. `sep` must be non-empty.
pub fn split(text : String, sep : String) -> Array[String] {
  let parts : Array[String] = []
  if sep.is_empty() {
    return parts
  }
  let mut start = 0
  let mut index = 0
  let limit = text.length() - sep.length()
  while index <= limit {
    if text[index:index + sep.length()].to_owned() == sep {
      parts.push(text[start:index].to_owned())
      index += sep.length()
      start = index
    } else {
      index += 1
    }
  }
  parts.push(text[start:].to_owned())
  parts
}

///|
/// Split into consecutive chunks of at most `size` items. A non-positive
/// `size` yields an empty array.
pub fn[T] chunk(items : Array[T], size : Int32) -> Array[Array[T]] {
  let chunks : Array[Array[T]] = []
  if size <= 0 {
    return chunks
  }
  let mut current : Array[T] = []
  for item in items {
    current.push(item)
    if current.length() == size {
      chunks.push(current)
      current = []
    }
  }
  if !current.is_empty() {
    chunks.push(current)
  }
  chunks
}

///|
/// First occurrence of each value, order preserved.
pub fn[T : Eq] uniq(items : Array[T]) -> Array[T] {
  let seen : Array[T] = []
  let result : Array[T] = []
  for item in items {
    let mut found = false
    for s in seen {
      if s == item {
        found = true
        break
      }
    }
    if !found {
      seen.push(item)
      result.push(item)
    }
  }
  result
}

///|
/// How many terminal columns a string occupies.
///
/// Not `String::length`, which counts UTF-16 code units: a Chinese character
/// measures 1 there and takes 2 columns, so a header like `运行时长` measured 4
/// while occupying 8, and every table with translated headers came out ragged and
/// pulled the following columns left.
///
/// The ranges below are the common East Asian and emoji blocks — an approximation
/// of the Unicode East Asian Width property, not a copy of it.
/// `moonbitlang/x/unicode` carries no width table, and importing one to pad a table
/// cell would cost more than it is worth here. A character outside these ranges
/// counts as one column, and combining marks as none.
pub fn display_width(text : String) -> Int32 {
  let mut width = 0
  for ch in text {
    width += char_width(ch.to_int())
  }
  width
}

///|
fn char_width(code : Int32) -> Int32 {
  // Combining marks and zero-width formatting: no column of their own.
  if (code >= 0x0300 && code <= 0x036f) ||
    code == 0x200b ||
    (code >= 0xfe00 && code <= 0xfe0f) {
    return 0
  }
  // East Asian wide and fullwidth, plus emoji.
  if (code >= 0x1100 && code <= 0x115f) ||
    (code >= 0x2e80 && code <= 0xa4cf) ||
    (code >= 0xac00 && code <= 0xd7a3) ||
    (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0xfe30 && code <= 0xfe6f) ||
    (code >= 0xff00 && code <= 0xff60) ||
    (code >= 0xffe0 && code <= 0xffe6) ||
    (code >= 0x1f300 && code <= 0x1faff) ||
    (code >= 0x20000 && code <= 0x3fffd) {
    return 2
  }
  1
}

///|
/// Pad with spaces on the right to a display width. Text already at or past the
/// width is returned untouched: a table that truncates a path is worse than one
/// whose columns are uneven.
pub fn pad_to(text : String, width : Int32) -> String {
  let pad = width - display_width(text)
  if pad <= 0 {
    return text
  }
  let buf = StringBuilder()
  buf.write_string(text)
  for _ in 0..<pad {
    buf.write_string(" ")
  }
  buf.to_string()
}
