///|
/// Append one plain text line, prefixed with the current ISO timestamp:
/// `2026-10-03T08:15:30.123Z <text>`. Failures raise so the caller stays
/// in charge of best-effort handling.
pub fn plain(path : String, text : String) -> Unit raise FileError {
  append_file(path, @utf8.encode(iso8601(now_ms()) + " " + text + "\n"))
}

///|
/// Append one JSONL management event:
/// `{"ts":"...","event":"...","<key>":<value>...}`. Keys are quoted by the
/// library; values must arrive as already-encoded JSON fragments — pass
/// `jstr(text)` for strings and raw digits for numbers, so a field
/// the caller omits simply does not appear on the wire.
pub fn event(
  path : String,
  event : String,
  fields : Array[(String, String)],
) -> Unit raise FileError {
  let all : Array[(String, String)] = [
    ("ts", jstr(iso8601(now_ms()))),
    ("event", jstr(event)),
  ]
  for pair in fields {
    let (key, value) = pair
    all.push((key, value))
  }
  append_file(path, @utf8.encode(jobj(all) + "\n"))
}

///|
/// Rotate `path` once it exceeds `max_bytes`: copytruncate for logs held
/// open by app processes (they keep writing to the old inode), rename for
/// logs written by the caller itself. Returns true when a rotation ran.
/// Raises FileError when a needed rotation failed; a missing file is not
/// an error (nothing to rotate).
pub fn maybe_rotate(
  path : String,
  max_bytes : Int64,
  copytruncate~ : Bool = false,
) -> Bool raise FileError {
  match file_size(path) {
    Some(size) if size > max_bytes => {
      if copytruncate {
        truncate_in_place(path)
      } else {
        rotate(path)
      }
      true
    }
    _ => false
  }
}
