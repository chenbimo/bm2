///|
/// Async log rotation. Supervision must never block, and one rotation can move
/// ten megabytes: on a slow disk that is long enough to stall every deadline,
/// every delivery and every accept behind it. So the expensive half lives here,
/// where each filesystem call awaits, and the supervision task only publishes
/// which files it wants swept.
///
/// Failures are values, not aborts: the async filesystem raises `OSError`, so a
/// rotation that cannot finish reports why instead of taking the rotation task
/// down with it.

///|
/// How many archived generations a rotation keeps (`path.1` .. `path.10`).
const ROTATE_GENERATIONS : Int32 = 10

///|
/// What one rotation attempt did, so the caller can log the outcome without
/// knowing how it happened.
pub(all) enum RotateOutcome {
  /// The file is under the limit, or not there at all.
  Skipped
  /// One rotation ran.
  Rotated
  /// The rotation started and failed: the string is the `log_rotate_failed`
  /// detail, so the reason reaches the event log either way.
  Failed(String)
}

///|
/// Size of a file in bytes, None when it is missing or unreadable. Rotation
/// sweeps instances that have never written a line, so "not there" is a normal
/// answer rather than an error worth reporting.
async fn size_of(path : String) -> Int64? {
  try @fs.file_size(path) catch {
    _ => None
  } noraise {
    size => Some(size)
  }
}

///|
/// Drop one generation, ignoring a path that is not there: dropping the oldest
/// is best-effort in the chain, exactly as the C version treated it.
async fn remove_quietly(path : String) -> Unit {
  try @fs.remove(path) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Shift one generation. A missing source is the normal case, and any other
/// failure only leaves a gap in the chain, so neither earns a log line: the
/// final rename or copy is what reports a failure.
async fn rename_generation(src : String, dst : String) -> Unit {
  try @fs.rename(src, dst, replace=true) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Shift the chain (`path.9` -> `path.10`, .., `path.1` -> `path.2`) and drop
/// the oldest, leaving room for a new `path.1`.
async fn shift_chain(path : String) -> Unit {
  remove_quietly(path + "." + ROTATE_GENERATIONS.to_string())
  let mut i = ROTATE_GENERATIONS - 1
  while i >= 1 {
    rename_generation(
      path + "." + i.to_string(),
      path + "." + (i + 1).to_string(),
    )
    i -= 1
  }
}

///|
/// Rename rotation: for logs the daemon itself writes, where no fd survives
/// the rename.
async fn rename_rotate(path : String) -> Unit {
  shift_chain(path)
  @fs.rename(path, path + ".1", replace=true)
}

///|
/// Copy-then-truncate rotation: for logs held open by an app process, which
/// keeps writing to the old inode. The inode survives, so the app's output
/// continues into the now-empty file; the few bytes written during the copy are
/// lost, the accepted trade-off for fd-held logs.
async fn copy_truncate(path : String) -> Unit {
  let content : Bytes = @fs.read_file(path).binary()
  shift_chain(path)
  // The copy lands before the source is emptied, and both sides are synced: a
  // crash in between must not lose the content twice.
  @fs.write_file(path + ".1", content, permission=0o600, sync=Data)
  @fs.write_file(path, b"", create_mode=TruncateExisting, sync=Data)
}

///|
/// Rotate `path` once it exceeds `max_bytes`: copytruncate for logs held open
/// by an app process, rename for logs the daemon writes itself. A missing file
/// is not an error, and a rotation that does fail reports the reason as a value
/// rather than raising it into the task that called.
pub async fn maybe_rotate_async(
  path : String,
  max_bytes : Int64,
  copytruncate~ : Bool = false,
) -> RotateOutcome {
  match size_of(path) {
    None => Skipped
    Some(size) =>
      if size <= max_bytes {
        Skipped
      } else {
        try {
          if copytruncate {
            copy_truncate(path)
          } else {
            rename_rotate(path)
          }
        } catch {
          e => Failed(e.to_string())
        } noraise {
          _ => Rotated
        }
      }
  }
}
