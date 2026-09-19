///|
/// Run a side effect whose failure must not abort the caller. Supervision
/// and lifecycle progress are defined to survive a broken disk, a dead
/// peer or a vanished process, so every best-effort step routes through
/// here instead of hand-rolling another try/catch pair.
pub fn discard(f : () -> Unit raise) -> Unit {
  try f() catch {
    _ => ()
  } noraise {
    _ => ()
  }
}
