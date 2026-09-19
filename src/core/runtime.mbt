///|
/// Minimum runtime versions bm2 supports; `bm2 start` probes the real
/// binary and rejects older ones. cluster mode additionally needs these
/// floors for SO_REUSEPORT (Bun reusePort / Node listen reusePort).
const MIN_BUN : String = "1.4.0"

///|
const MIN_NODE : String = "24.0.0"

///|
/// How long the runtime version probe may take. The daemon is single
/// threaded, so this probe is the one place where a stuck helper binary
/// could stall supervision; the wait is hard-bounded and the probe killed
/// on expiry rather than trusting the runtime to answer.
const RUNTIME_PROBE_TIMEOUT_MS : Int = 5000

///|
/// Verify the project's runtime meets the minimum version before any
/// spawn: run `<runtime> --version` once, stdout captured through a temp
/// file under the state dir (stderr stays on the daemon's own log).
/// Every failure mode rejects the start with a concrete reason instead
/// of letting an old runtime fail in confusing ways later.
pub fn Supervisor::check_runtime(
  self : Supervisor,
  runtime : String,
) -> Unit raise SupervisorError {
  let min_text = if runtime == "node" { MIN_NODE } else { MIN_BUN }
  let min = parse_version(min_text)
  let out = "\{self.state_dir}/runtime-version.tmp"
  let problem = try
    @process.spawn({
      bun_path: runtime,
      script: "--version",
      cwd: "/",
      out_log: out,
      err_log: "",
      env_blob: @process.base_env_blob(),
    })
  catch {
    e => Some(e.to_string())
  } noraise {
    pid => {
      let reaped = @process.wait_child_timeout(pid, RUNTIME_PROBE_TIMEOUT_MS)
      match reaped {
        Some((_, @process.ChildExit::Exited(0))) => {
          let text = try @process.read_small(out, cap=256) catch {
            _ => ""
          } noraise {
            data => @utf8.decode_lossy(data)
          }
          let version = parse_version(text)
          if version == (0, 0, 0) {
            Some("cannot parse \{runtime} --version output")
          } else if version_at_least(version, min) {
            None
          } else {
            Some(
              "\{runtime} \{text.trim()} is too old, bm2 requires \{runtime} >= \{min_text}",
            )
          }
        }
        Some((_, @process.ChildExit::Exited(127))) =>
          Some("\{runtime} not found on PATH (or failed to execute)")
        Some((_, @process.ChildExit::Exited(code))) =>
          Some("\{runtime} --version exited with code \{code}")
        Some((_, @process.ChildExit::Signaled(sig))) =>
          Some(
            "\{runtime} --version was killed by signal \{sig} after \{RUNTIME_PROBE_TIMEOUT_MS}ms",
          )
        None =>
          Some(
            "\{runtime} --version did not answer within \{RUNTIME_PROBE_TIMEOUT_MS}ms and was killed",
          )
      }
    }
  }
  @process.discard(() => @process.unlink(out))
  match problem {
    Some(msg) => raise RuntimeRejected(msg)
    None => ()
  }
}

///|
/// First `major.minor.patch` triple in text: skips any prefix ("v",
/// product names) and stops at the first non-version character, so
/// pre-release suffixes ("1.4.0-beta") compare as their release triple.
fn parse_version(text : String) -> (Int, Int, Int) {
  let buf = StringBuilder()
  let mut started = false
  for c in text {
    if !started {
      if c is ('0'..='9') {
        started = true
        buf.write_char(c)
      }
    } else if c is ('0'..='9') || c == '.' {
      buf.write_char(c)
    } else {
      break
    }
  }
  let parts = buf.to_string().split(".").to_array()
  (segment(parts, 0), segment(parts, 1), segment(parts, 2))
}

///|
fn segment(parts : Array[StringView], i : Int) -> Int {
  if i < parts.length() {
    parse_num(parts[i].to_owned())
  } else {
    0
  }
}

///|
/// Numeric prefix of one version segment; non-digits stop the scan.
fn parse_num(s : String) -> Int {
  let mut n = 0
  for c in s {
    if !(c is ('0'..='9')) {
      break
    }
    n = n * 10 + c.to_int() - 48
  }
  n
}

///|
/// Compare two version strings: -1, 0, 1. Both sides go through the same
/// parser as the minimum-version check, so a "v" prefix or a pre-release
/// suffix ("0.3.0-beta") compares as its release triple instead of
/// corrupting the result with garbage arithmetic.
pub fn version_compare(a : String, b : String) -> Int {
  compare_version_triple(parse_version(a), parse_version(b))
}

///|
fn version_at_least(actual : (Int, Int, Int), min : (Int, Int, Int)) -> Bool {
  compare_version_triple(actual, min) >= 0
}

///|
/// Segment-by-segment ordering of two parsed versions; the single place
/// that knows how a version triple is ordered.
fn compare_version_triple(a : (Int, Int, Int), b : (Int, Int, Int)) -> Int {
  if a.0 != b.0 {
    return if a.0 < b.0 { -1 } else { 1 }
  }
  if a.1 != b.1 {
    return if a.1 < b.1 { -1 } else { 1 }
  }
  if a.2 != b.2 {
    return if a.2 < b.2 { -1 } else { 1 }
  }
  0
}
