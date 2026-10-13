///|
/// Async log rotation. Supervision must never block, and one rotation can move
/// ten megabytes: on a slow disk that is long enough to stall every deadline,
/// every delivery and every accept behind it. So the expensive half lives here,
/// where each filesystem call awaits, and the supervision task only publishes
/// which files it wants swept.

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
/// Size of a file in bytes, None when it is not there. The async filesystem
/// reports errors by aborting rather than raising, so existence is checked
/// instead of caught — the caller's question is only "is there anything to
/// rotate".
async fn size_of(path : String) -> Int64? {
  if @fs.exists(path) {
    Some(@fs.file_size(path))
  } else {
    None
  }
}

///|
/// Drop one generation, ignoring a path that is not there. Log rotation runs
/// over instances that have never written a line, so a missing file must be a
/// no-op and not a failure the operator has to read about.
async fn remove_quietly(path : String) -> Unit {
  if @fs.exists(path) {
    @fs.remove(path)
  }
}

///|
/// Rename one generation, ignoring a source that is not there. `replace` keeps
/// rename(2) semantics: an existing destination is overwritten.
async fn rename_quietly(src : String, dst : String) -> Unit {
  if @fs.exists(src) {
    @fs.rename(src, dst, replace=true)
  }
}

///|
/// Shift the chain (`path.9` -> `path.10`, .., `path.1` -> `path.2`) and drop
/// the oldest, leaving room for a new `path.1`.
async fn shift_chain(path : String) -> Unit {
  remove_quietly(path + "." + ROTATE_GENERATIONS.to_string())
  let mut i = ROTATE_GENERATIONS - 1
  while i >= 1 {
    rename_quietly(path + "." + i.to_string(), path + "." + (i + 1).to_string())
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
/// by an app process, rename for logs the daemon writes itself.
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
        if copytruncate {
          copy_truncate(path)
        } else {
          rename_rotate(path)
        }
        Rotated
      }
  }
}
