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
const RUNTIME_PROBE_TIMEOUT_MS : Int32 = 5000

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
  let min = @utils.parse(min_text)
  let out = "\{self.state_dir}/runtime-version.tmp"
  let problem = try
    @proc.spawn({
      bun_path: runtime,
      script: "--version",
      cwd: "/",
      out_log: out,
      err_log: "",
      env_blob: @proc.base_env_blob(),
    })
  catch {
    e => Some(e.to_string())
  } noraise {
    pid => {
      let reaped = @proc.wait_child_timeout(pid, RUNTIME_PROBE_TIMEOUT_MS)
      match reaped {
        Some((_, @proc.ChildExit::Exited(0))) => {
          let text = try @fsx.read_small(out, cap=256) catch {
            _ => ""
          } noraise {
            data => @utf8.decode_lossy(data)
          }
          let version = @utils.parse(text)
          if version == { major: 0, minor: 0, patch: 0, } {
            Some("cannot parse \{runtime} --version output")
          } else if @utils.compare(version, min) >= 0 {
            None
          } else {
            Some(
              "\{runtime} \{text.trim()} is too old, bm2 requires \{runtime} >= \{min_text}",
            )
          }
        }
        Some((_, @proc.ChildExit::Exited(127))) =>
          Some("\{runtime} not found on PATH (or failed to execute)")
        Some((_, @proc.ChildExit::Exited(code))) =>
          Some("\{runtime} --version exited with code \{code}")
        Some((_, @proc.ChildExit::Signaled(sig))) =>
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
  @utils.discard(() => @fsx.unlink(out))
  match problem {
    Some(msg) => raise RuntimeRejected(msg)
    None => ()
  }
}
