///|
/// The rotation task: the only place in the daemon where a log is copied,
/// renamed or truncated. Supervision publishes the list of logs it wants swept
/// (pure string work, the policy already folded into each job) and this task does
/// the expensive part over the async filesystem, so a slow disk delays nothing
/// else in the process.

///|
pub struct RotateRunner {
  /// Sweeps published by the supervision task. Capacity one: a sweep nobody has
  /// picked up yet is superseded by the next one, which re-checks every path
  /// anyway, so a backlog can never build up here.
  inbound : @aqueue.Queue[Array[@log.RotateJob]]
  state_dir : String
}

///|
pub fn RotateRunner::new(
  state_dir : String,
  inbound : @aqueue.Queue[Array[@log.RotateJob]],
) -> RotateRunner {
  { inbound, state_dir, }
}

///|
/// Sweep one published list: rotate every log that is over its limit, and
/// record what happened. Outcomes are events only, never supervision state.
async fn RotateRunner::sweep(
  self : RotateRunner,
  jobs : Array[@log.RotateJob],
) -> Unit {
  for job in jobs {
    match @log.maybe_rotate_async(job) {
      Skipped => ()
      Rotated =>
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "log_rotated",
          detail=job.path,
        )
      Failed(reason) =>
        log_event(
          self.state_dir,
          "bm2d.events.jsonl",
          "log_rotate_failed",
          detail=job.path + ": " + reason,
        )
    }
  }
}

///|
/// Wait for a sweep, run it, repeat. Waiting on the queue rather than polling
/// costs nothing while no log needs rotating, which is the normal state.
pub async fn RotateRunner::run(self : RotateRunner) -> Unit {
  while true {
    let jobs = self.inbound.get()
    self.sweep(jobs)
  }
}
