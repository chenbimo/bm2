///|
/// Async log rotation. Supervision must never block, and one rotation can move
/// ten megabytes: on a slow disk that is long enough to stall every deadline,
/// every delivery and every accept behind it. So the expensive half lives here,
/// where each filesystem call awaits, and the supervision task only publishes
/// which logs it wants swept.
///
/// Failures are values, not aborts: the async filesystem raises `OSError`, so a
/// rotation that cannot finish reports why instead of taking the rotation task
/// down with it.

///|
/// One log to look at: where it is, how it is held open, and how much history the
/// project it belongs to asked for.
pub(all) struct RotateJob {
  path : String
  /// True when an app process holds the file open, so the content is copied out
  /// and the original emptied in place (copytruncate). False when the daemon
  /// writes the log itself, where a rename is enough.
  ///
  /// Copytruncate loses whatever the app writes between the copy and the
  /// truncate. That is the price of rotating a file we hold no descriptor for,
  /// not a defect to fix by renaming: after a rename the app keeps writing to
  /// the old inode and the new file stays empty for good.
  copytruncate : Bool
  /// Rotate once the file is larger than this.
  max_bytes : Int64
  /// Generations to keep. Zero keeps every generation.
  keep : Int32
}

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
/// Split a log path into its directory and its stem, dropping the `.log`.
fn split_log_path(path : String) -> (String, String) {
  let full = @path.Path::Path(path)
  let dir = full.dirname().to_string()
  let base = full.basename().to_owned()
  let stem = if base.has_suffix(".log") {
    base[:base.length() - 4].to_owned()
  } else {
    base
  }
  (dir, stem)
}

///|
/// Path of generation `n`: `.../api.log` → `.../api.1.log`.
///
/// The number goes before the extension, never after it. Every rotated file in
/// bm2 follows this — a project's `api.log` and the daemon's `bm2d.events.log`
/// alike — so the suffix is always `.log` and a directory listing keeps one
/// project's files together.
fn slice_path(path : String, n : Int32) -> String {
  let (dir, stem) = split_log_path(path)
  let name = stem + "." + n.to_string() + ".log"
  if dir == "" {
    name
  } else {
    dir + "/" + name
  }
}

///|
/// Highest archived generation next to `path`, 0 when there is none.
///
/// A bounded chain knows its own length, but an unbounded one does not, so the
/// length is read from the directory: every `<stem>.<digits>.log` entry counts
/// as a generation and the largest number wins. Entries that are not a plain
/// number (a rotated name, a hand-made backup) are ignored rather than guessed
/// at.
async fn highest_generation(path : String) -> Int32 {
  let (dir, stem) = split_log_path(path)
  let prefix = stem + "."
  let names = try @fs.readdir(dir, sort=false) catch {
    _ => []
  } noraise {
    entries => entries
  }
  let mut highest = 0
  for name in names {
    if !name.has_prefix(prefix) || !name.has_suffix(".log") {
      continue
    }
    let tail = name[prefix.length():name.length() - 4].to_owned()
    let mut value = 0
    let mut numeric = tail.length() > 0
    for ch in tail {
      if ch is ('0'..<='9') {
        value = value * 10 + (ch.to_int() - 48)
      } else {
        numeric = false
        break
      }
    }
    if numeric && value > highest {
      highest = value
    }
  }
  highest
}

///|
/// Shift the chain (`stem.N.log` -> `stem.N+1.log`, .., `stem.1.log` ->
/// `stem.2.log`), leaving room for a new `stem.1.log`. With a bound, the oldest
/// generations beyond it are dropped; with `keep = 0` nothing is dropped and the
/// chain is as long as the directory says it is.
async fn shift_chain(path : String, keep : Int32) -> Unit {
  let mut i = keep
  if keep > 0 {
    remove_quietly(slice_path(path, keep))
    i = keep - 1
  } else {
    i = highest_generation(path)
  }
  while i >= 1 {
    rename_generation(slice_path(path, i), slice_path(path, i + 1))
    i -= 1
  }
}

///|
/// Rename rotation: for logs the daemon itself writes, where no fd survives
/// the rename.
async fn rename_rotate(path : String, keep : Int32) -> Unit {
  shift_chain(path, keep)
  @fs.rename(path, slice_path(path, 1), replace=true)
}

///|
/// Copy-then-truncate rotation: for logs held open by an app process, which
/// keeps writing to the old inode. The inode survives, so the app's output
/// continues into the now-empty file; the few bytes written during the copy are
/// lost, the accepted trade-off for fd-held logs.
async fn copy_truncate(path : String, keep : Int32) -> Unit {
  let content : Bytes = @fs.read_binary(path)
  shift_chain(path, keep)
  // The copy lands before the source is emptied, and both sides are synced: a
  // crash in between must not lose the content twice.
  @fs.write_binary(slice_path(path, 1), content, permission=0o600, sync=Data)
  @fs.write_binary(path, b"", create_mode=TruncateExisting, sync=Data)
}

///|
/// Rotate the job's log once it exceeds its size limit: copytruncate for logs
/// held open by an app process, rename for logs the daemon writes itself. A
/// missing file is not an error, and a rotation that does fail reports the reason
/// as a value rather than raising it into the task that called.
pub async fn maybe_rotate_async(job : RotateJob) -> RotateOutcome {
  match size_of(job.path) {
    None => Skipped
    Some(size) =>
      if size <= job.max_bytes {
        Skipped
      } else {
        try {
          if job.copytruncate {
            copy_truncate(job.path, job.keep)
          } else {
            rename_rotate(job.path, job.keep)
          }
        } catch {
          e => Failed(e.to_string())
        } noraise {
          _ => Rotated
        }
      }
  }
}
