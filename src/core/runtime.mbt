///|
/// Minimum runtime versions bm2 supports; `bm2 start` probes the real
/// binary and rejects older ones.
const MIN_BUN : String = "1.4.0"

///|
const MIN_NODE : String = "24.0.0"

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
      let reaped = try @process.wait_child(pid) catch {
        _ => None
      } noraise {
        r => r
      }
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
        _ => Some("\{runtime} --version could not be reaped")
      }
    }
  }
  discard(() => @process.unlink(out))
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
  let buf = StringBuilder::new()
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
fn version_at_least(actual : (Int, Int, Int), min : (Int, Int, Int)) -> Bool {
  actual.0 > min.0 ||
  (
    actual.0 == min.0 &&
    (actual.1 > min.1 || (actual.1 == min.1 && actual.2 >= min.2))
  )
}
