///|
pub(all) enum Status {
  Stopped
  Starting
  Online
  Restarting
  Errored
  Stopping
} derive(Debug, Eq)

///|
pub fn Status::as_string(self : Status) -> String {
  match self {
    Stopped => "stopped"
    Starting => "starting"
    Online => "online"
    Restarting => "restarting"
    Errored => "errored"
    Stopping => "stopping"
  }
}

///|
/// What bm2 wants to happen after the current process exits.
pub(all) enum ExitIntent {
  Idle
  Stop
  RestartFresh
  RestartCounted
} derive(Debug, Eq)

///|
pub(all) struct Instance {
  app_name : String
  cwd : String
  instance_id : Int
  port : Int
  mut pid : Int
  /// pidfd pinned to `pid` (0 when not running); never pid-reused.
  mut pidfd : Int
  mut status : Status
  mut started_at_ms : UInt64
  mut restart_count : Int
  mut uptime_reset_done : Bool
  mut exit_intent : ExitIntent
  mut kill_deadline_ms : UInt64
  mut restart_at_ms : UInt64
  mut last_exit_code : Int?
  mut last_signal : Int?
  mut last_reason : String?
  mut last_rss_kb : Int
} derive(Debug)

///|
pub fn Instance::new(config : @config.Config, instance_id : Int) -> Instance {
  {
    app_name: config.name,
    cwd: config.cwd,
    instance_id,
    port: config.base_port + instance_id,
    pid: 0,
    pidfd: 0,
    status: Stopped,
    started_at_ms: 0UL,
    restart_count: 0,
    uptime_reset_done: false,
    exit_intent: Idle,
    kill_deadline_ms: 0UL,
    restart_at_ms: 0UL,
    last_exit_code: None,
    last_signal: None,
    last_reason: None,
    last_rss_kb: 0,
  }
}

///|
/// True while the OS process exists. The pidfd is authoritative (it is
/// pinned to the original process, so a reused pid cannot be mistaken for
/// a live instance); pid_alive is only a fallback when no pidfd exists.
pub fn Instance::alive(self : Instance) -> Bool {
  if self.pid <= 0 {
    return false
  }
  if self.pidfd > 0 {
    @process.pidfd_alive(self.pidfd)
  } else {
    @process.pid_alive(self.pid)
  }
}
