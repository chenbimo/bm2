///|
/// The control plane's only channel into supervision. Every request that reads
/// or writes supervised state travels through this queue and is applied inside
/// `Supervisor::tick`, on the supervision task — so there is exactly one writer
/// of apps, instances and restart budgets, and the control plane can never
/// observe a half-applied request.

///|
/// How the daemon should end after serving one control request.
pub(all) enum ExitMode {
  Stay
  /// Bare `kill`: stop every app, then exit. SIGTERM lands on the same path.
  Shutdown
  /// `reload`: detach without stopping apps; the CLI starts a fresh bm2d which
  /// adopts the surviving instances.
  Detach
}

///|
/// One control request waiting for the supervision task. The control task builds
/// the command, puts it on the queue and waits for `reply`; it never touches an
/// app, an instance or the notifier itself.
pub(all) struct Command {
  request : @protocol.Request
  /// Where the answer goes: capacity 1, exactly one reply per command.
  reply : @aqueue.Queue[Reply]
}

///|
pub(all) struct Reply {
  response : @protocol.Response
  /// Non-`Stay` only for the requests that end the daemon; the control side
  /// hands it to the task group body, which then unwinds the daemon.
  exit : ExitMode
}

///|
/// Capacity of the command queue. A command costs one tick (50 ms), and each
/// caller only ever has one in flight, so this absorbs a burst of simultaneous
/// CLIs without ever being the limit anyone notices.
pub const COMMAND_QUEUE_CAPACITY : Int32 = 64

///|
/// Tail of the reply queue's lifetime: a caller that gave up waiting loses the
/// answer, never the daemon.
pub fn Command::new(request : @protocol.Request) -> Command {
  { request, reply: @aqueue.Queue::Queue(kind=Blocking(1)), }
}

///|
/// The queue control requests arrive on. `tick` drains it, so a command is
/// applied within one tick of arriving.
pub fn Supervisor::commands(self : Supervisor) -> @aqueue.Queue[Command] {
  self.commands
}

///|
/// Apply every control request that arrived since the last tick. Runs on the
/// supervision task, which owns every field these touch: no lock, and a reader
/// can never see a half-applied request.
fn Supervisor::drain_commands(self : Supervisor) -> Unit {
  while true {
    let next = try self.commands.try_get() catch {
      _ => None
    } noraise {
      item => item
    }
    match next {
      Some(command) => self.handle_command(command)
      None => return
    }
  }
}

///|
/// Answer one control request in the same tick that picked it up.
pub fn Supervisor::handle_command(self : Supervisor, command : Command) -> Unit {
  let req = command.request
  let (response, exit) = match req.command {
    "list" => (self.cmd_list(req.app), ExitMode::Stay)
    "start" => (self.cmd_start(req), ExitMode::Stay)
    "kill" => self.cmd_kill(req.app)
    "reload" => (@protocol.Response::ok("reloading", []), ExitMode::Detach)
    _ =>
      (
        @protocol.Response::error("unknown command: " + req.command),
        ExitMode::Stay,
      )
  }
  let answered = try command.reply.try_put({ response, exit, }) catch {
    _ => false
  } noraise {
    ok => ok
  }
  if !answered {
    // The caller stopped waiting (its own request timeout expired) or simply
    // disconnected. The answer is dropped, and the drop is worth a line: it is
    // the only trace of a control request that went nowhere.
    log_event(
      self.state_dir,
      "bm2d.events.jsonl",
      "command_reply_dropped",
      app=req.app,
      detail=req.command,
    )
  }
}

///|
/// `bm2 list`: instances of one app, or of every app.
fn Supervisor::cmd_list(self : Supervisor, app : String?) -> @protocol.Response {
  let names = try self.targets(app) catch {
    e => return @protocol.Response::error(e.to_string())
  } noraise {
    found => found
  }
  @protocol.Response::ok("ok", self.infos_of(names))
}

///|
/// Every start re-reads the config from the request's config path, so
/// `bm2 start` always reflects the current bm2.toml, verifies the runtime meets
/// the minimum version, then registers the project (updating it when it already
/// runs) and starts it.
///
/// The request answers immediately with the in-flight state: the CLI polls
/// `list` for the terminal state, so a stop timeout never delays an answer.
fn Supervisor::cmd_start(
  self : Supervisor,
  req : @protocol.Request,
) -> @protocol.Response {
  let config_path = match req.config_path {
    Some(path) => path
    None => return @protocol.Response::error("start requires a config path")
  }
  let config = try @config.load(config_path) catch {
    e => return @protocol.Response::error(e.to_string())
  } noraise {
    loaded => loaded
  }
  try self.check_runtime(config.runtime) catch {
    e => return @protocol.Response::error(e.to_string())
  } noraise {
    _ => ()
  }
  try self.register(config, config_path) catch {
    e => return @protocol.Response::error(e.to_string())
  } noraise {
    _ => ()
  }
  let name = config.name
  try self.start_app(name) catch {
    e => return @protocol.Response::error(e.to_string())
  } noraise {
    _ => ()
  }
  @protocol.Response::ok("started", self.infos_of([name]))
}

///|
/// Kill an app immediately, or end the daemon when no app was named. The
/// all-app kill itself happens in the shutdown path, after the reply has
/// reached the caller.
fn Supervisor::cmd_kill(
  self : Supervisor,
  app : String?,
) -> (@protocol.Response, ExitMode) {
  match app {
    None => (@protocol.Response::ok("bm2d stopping", []), ExitMode::Shutdown)
    Some(name) => {
      try self.kill_app(name) catch {
        e => return (@protocol.Response::error(e.to_string()), ExitMode::Stay)
      } noraise {
        _ => ()
      }
      (@protocol.Response::ok("killed", self.infos_of([name])), ExitMode::Stay)
    }
  }
}

///|
/// Resolve the optional app filter to concrete app names, verifying that a named
/// app exists.
fn Supervisor::targets(self : Supervisor, app : String?) -> Array[String] raise {
  match app {
    Some(name) => {
      ignore(self.app_instances(name))
      [name]
    }
    None => self.app_names()
  }
}

///|
/// List output excludes intentionally stopped instances. Other statuses,
/// especially restarting and errored, remain visible for operational diagnosis.
fn Supervisor::infos_of(
  self : Supervisor,
  names : Array[String],
) -> Array[@protocol.InstanceInfo] {
  let now_mono = @proc.monotonic_ms()
  let infos = []
  for name in names {
    try {
      for inst in self.app_instances(name) {
        if !(inst.status is Status::Stopped) {
          infos.push(instance_info_of(inst, now_mono))
        }
      }
    } catch {
      _ => ()
    } noraise {
      _ => ()
    }
  }
  infos
}
