///|
/// Strip spaces and tabs from both ends (plus a trailing CR, so Windows
/// line endings survive a `split("\n")`).
pub fn trim_spaces(text : StringView) -> String {
  let mut start = 0
  let end = text.length()
  while start < end {
    let ch = text[start].to_int()
    if ch == 0x20 || ch == 0x09 {
      start += 1
    } else {
      break
    }
  }
  let mut stop = end
  while stop > start {
    let ch = text[stop - 1].to_int()
    if ch == 0x20 || ch == 0x09 || ch == 0x0D {
      stop -= 1
    } else {
      break
    }
  }
  if start == 0 && stop == end {
    text.to_owned()
  } else if start >= stop {
    ""
  } else {
    text[start:stop].to_owned()
  }
}

///|
/// Strict non-negative integer: every character must be an ASCII digit,
/// empty input rejected. Returns `None` instead of a partial number.
pub fn parse_int(text : String) -> Int32? {
  if text.is_empty() {
    return None
  }
  let mut value = 0
  for i in 0..<text.length() {
    let ch = text[i].to_int()
    if ch < 0x30 || ch > 0x39 {
      return None
    }
    value = value * 10 + (ch - 0x30)
  }
  Some(value)
}

///|
/// Text of the first double-quoted segment in a line, or `""` when the
/// line quotes nothing. Built for `key = "value"` manifest lines.
pub fn quoted_value(line : String) -> String {
  let mut start = -1
  let mut stop = line.length()
  for i, ch in line {
    if ch == '"' {
      if start < 0 {
        start = i
      } else {
        stop = i
        break
      }
    }
  }
  if start >= 0 && stop > start {
    line[start + 1:stop].to_owned()
  } else {
    ""
  }
}

///|
const HEX_DIGITS : String = "0123456789ABCDEF"

///|
fn hex_pair(value : Int32) -> String {
  let high = value >> 4
  let low = value & 15
  HEX_DIGITS[high:high + 1].to_owned() + HEX_DIGITS[low:low + 1].to_owned()
}

///|
/// Escape a string for embedding inside a JSON double-quoted literal:
/// quotes, backslashes and the C/JSON control escapes; other control
/// characters become `\u00XX`.
pub fn json_escape(text : String) -> String {
  let buf = StringBuilder()
  for c in text {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ =>
        if c.to_int() < 0x20 {
          buf.write_string("\\u00" + hex_pair(c.to_int()))
        } else {
          buf.write_char(c)
        }
    }
  }
  buf.to_string()
}

///|
/// A JSON string literal: the text, escaped and wrapped in quotes.
pub fn jstr(text : String) -> String {
  "\"" + json_escape(text) + "\""
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
/// True when the text is empty or made only of spaces/tabs.
pub fn is_blank(text : String) -> Bool {
  for c in text {
    let value = c.to_int()
    if value != 0x20 && value != 0x09 {
      return false
    }
  }
  true
}

///|
/// Drop `prefix` from the start of `text`; `None` when it is not there.
pub fn remove_prefix(text : String, prefix : String) -> String? {
  if prefix.is_empty() || !text.has_prefix(prefix) {
    None
  } else {
    Some(text[prefix.length():].to_owned())
  }
}

///|
/// Drop `suffix` from the end of `text`; `None` when it is not there.
pub fn remove_suffix(text : String, suffix : String) -> String? {
  if suffix.is_empty() || !text.has_suffix(suffix) {
    None
  } else {
    Some(text[:text.length() - suffix.length()].to_owned())
  }
}

///|
/// Pad `text` with `pad` (default `"0"`) on the left up to `target_len`.
/// Longer text is returned unchanged; an empty `pad` returns `text`.
pub fn pad_start(
  text : String,
  target_len : Int32,
  pad~ : String = "0",
) -> String {
  if text.length() >= target_len || pad.is_empty() {
    return text
  }
  let fill = pad.repeat(
    (target_len - text.length() + pad.length() - 1) / pad.length(),
  )
  fill[:target_len - text.length()].to_owned() + text
}

///|
/// Pad `text` with `pad` (default `" "`) on the right up to `target_len`.
pub fn pad_end(
  text : String,
  target_len : Int32,
  pad~ : String = " ",
) -> String {
  if text.length() >= target_len || pad.is_empty() {
    return text
  }
  let fill = pad.repeat(
    (target_len - text.length() + pad.length() - 1) / pad.length(),
  )
  text + fill[:target_len - text.length()].to_owned()
}

///|
/// Lowercase a Latin string (A-Z only; other chars unchanged).
pub fn to_lower(text : String) -> String {
  let buf = StringBuilder()
  for c in text {
    let value = c.to_int()
    if value >= 65 && value <= 90 {
      buf.write_char((value + 32).unsafe_to_char())
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
/// Uppercase a Latin string (a-z only; other chars unchanged).
pub fn to_upper(text : String) -> String {
  let buf = StringBuilder()
  for c in text {
    let value = c.to_int()
    if value >= 97 && value <= 122 {
      buf.write_char((value - 32).unsafe_to_char())
    } else {
      buf.write_char(c)
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
/// Integers from `start` up to (excluding) `end` by `step` (default 1).
/// A non-positive `step` yields an empty array.
pub fn range(start : Int32, end : Int32, step~ : Int32 = 1) -> Array[Int32] {
  let values : Array[Int32] = []
  if step <= 0 {
    return values
  }
  let mut current = start
  while current < end {
    values.push(current)
    current += step
  }
  values
}

///|
/// Clamp `n` into `[lo, hi]`.
pub fn clamp_int(n : Int32, lo : Int32, hi : Int32) -> Int32 {
  if n < lo {
    lo
  } else if n > hi {
    hi
  } else {
    n
  }
}

///|
/// Bytes as uppercase hex (`"4142"`).
pub fn hex_encode(bytes : Bytes) -> String {
  let buf = StringBuilder()
  for byte in bytes {
    buf.write_string(hex_pair(byte.to_int()))
  }
  buf.to_string()
}

///|
/// Decode an even-length uppercase/lowercase hex string into bytes;
/// `None` on odd length or any non-hex character.
pub fn hex_decode(text : String) -> Bytes? {
  if text.length() % 2 != 0 {
    return None
  }
  let nibbles : Array[Int32] = []
  for c in text {
    let value = c.to_int()
    let digit = if value >= 48 && value <= 57 {
      value - 48
    } else if value >= 65 && value <= 70 {
      value - 55
    } else if value >= 97 && value <= 102 {
      value - 87
    } else {
      return None
    }
    nibbles.push(digit)
  }
  let bytes : Array[Byte] = []
  let mut index = 0
  while index < nibbles.length() {
    bytes.push((nibbles[index] * 16 + nibbles[index + 1]).to_byte())
    index += 2
  }
  Some(Bytes::from_array(bytes))
}
