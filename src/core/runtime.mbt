///|
/// Minimum runtime versions bm2 supports; a start is refused when the real binary
/// is older. cluster mode additionally needs these floors for SO_REUSEPORT (Bun
/// reusePort / Node listen reusePort).
const MIN_BUN : String = "1.4.0"

///|
const MIN_NODE : String = "24.0.0"

///|
/// How long a `<runtime> --version` probe may take. The wait itself belongs to the
/// control task (see `RuntimeProbe` in the daemon): a stuck helper binary must not
/// stall any task, and this bound is what turns "stuck" into a reported verdict.
pub const RUNTIME_PROBE_TIMEOUT_MS : Int32 = 5000

///|
/// The runtime version bm2 requires for this name.
pub fn runtime_min(runtime : String) -> String {
  if runtime == "node" {
    MIN_NODE
  } else {
    MIN_BUN
  }
}

///|
/// Judge one `<runtime> --version` run: `None` when the runtime is acceptable,
/// `Some(reason)` when it is not. Pure, so the daemon can run the probe wherever
/// the wait is cheapest and still report exactly these words.
pub fn runtime_verdict(
  runtime : String,
  exit_code : Int32,
  output : String,
) -> String? {
  let min_text = runtime_min(runtime)
  let min = @utils.parse(min_text)
  if exit_code == 127 {
    return Some("\{runtime} not found on PATH (or failed to execute)")
  }
  if exit_code != 0 {
    return Some("\{runtime} --version exited with code \{exit_code}")
  }
  let version = @utils.parse(output)
  if version == { major: 0, minor: 0, patch: 0, } {
    Some("cannot parse \{runtime} --version output")
  } else if @utils.compare(version, min) >= 0 {
    None
  } else {
    Some(
      "\{runtime} \{output.trim()} is too old, bm2 requires \{runtime} >= \{min_text}",
    )
  }
}

///|
/// What to report when the probe never answered within its budget.
pub fn runtime_timeout(runtime : String) -> String {
  "\{runtime} --version did not answer within \{RUNTIME_PROBE_TIMEOUT_MS}ms and was killed"
}

///|
/// What to report when the runtime could not be run at all.
pub fn runtime_unrunnable(runtime : String) -> String {
  "\{runtime} not found on PATH (or failed to execute)"
}
