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
/// Stop a project without retiring it: it stays registered and listed, and stays
/// stopped until `bm2 start` puts it back. `kill` unregisters, which is why this
/// is a verb of its own rather than a flag on that one.
fn Supervisor::cmd_stop(self : Supervisor, app : String?) -> @protocol.Response {
  match app {
    None => @protocol.Response::error("stop requires a project name")
    Some(name) => {
      try self.pause_app(name) catch {
        e => return @protocol.Response::error(e.to_string())
      } noraise {
        _ => ()
      }
      @protocol.Response::ok("stopped", self.infos_of([name]))
    }
  }
}

///|
/// Retire a project: stop it, then unregister it, so the name is free again and
/// its supervision state is gone. The logs stay — they are the operator's record
/// of what the project did, and deleting them is a separate, explicit act on the
/// client side (`bm2 remove -f` purges the state directory once the project is
/// gone).
fn Supervisor::cmd_remove(
  self : Supervisor,
  app : String?,
  force : Bool?,
) -> @protocol.Response {
  match app {
    None => @protocol.Response::error("remove requires a project name")
    Some(name) => {
      // An unknown name is an error, not a no-op: silently "removing" something
      // that was never registered would hide a typo.
      try self.app_config(name) catch {
        e => return @protocol.Response::error(e.to_string())
      } noraise {
        _ => ()
      }
      // Hard with `-f`, graceful (SIGTERM, with the usual escalation) without it.
      // `check_removals` finalizes once every instance has stopped.
      try self.remove_app(name, force=force.unwrap_or(false)) catch {
        e => return @protocol.Response::error(e.to_string())
      } noraise {
        _ => ()
      }
      if self.projects.get(name) is Some(project) {
        project.stopped = false
      }
      @protocol.Response::ok("removing", self.infos_of([name]))
    }
  }
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
      Some(command) => {
        self.commands_applied += 1
        self.handle_command(command)
      }
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
    "stop" => (self.cmd_stop(req.app), ExitMode::Stay)
    "remove" => (self.cmd_remove(req.app, req.force), ExitMode::Stay)
    "kill" => cmd_kill(req.app)
    "reload" => (@protocol.Response::ok("reloading", []), ExitMode::Detach)
    other =>
      match @config.Mode::of_command(other) {
        // The two start verbs: one supervision, two environments.
        Some(mode) => (self.cmd_start(req, mode), ExitMode::Stay)
        None =>
          (
            @protocol.Response::error("unknown command: " + other),
            ExitMode::Stay,
          )
      }
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
  // `list` is where an operator looks first, so it also carries the daemon's own
  // numbers; `bm2 list` prints them under the instance table.
  let listed = @protocol.Response::ok("ok", self.infos_of(names))
  { ..listed, daemon: Some(self.daemon_info()), }
}

///|
/// `bm2 serve` and `bm2 dev` re-read the config from the request's config path,
/// so a start always reflects the current bm2.toml and the current `.env` files.
/// The verb's mode decides which of those files load, and it is what the
/// instances get as NODE_ENV. The runtime verdict was already taken on the
/// control side; registration updates a project that already runs, then it is
/// started.
///
/// The request answers immediately with the in-flight state: the CLI polls
/// `list` for the terminal state, so a stop timeout never delays an answer.
fn Supervisor::cmd_start(
  self : Supervisor,
  req : @protocol.Request,
  mode : @config.Mode,
) -> @protocol.Response {
  let config_path = match req.config_path {
    Some(path) => path
    None => return @protocol.Response::error("start requires a config path")
  }
  let config = try @config.load(config_path, mode~) catch {
    e => return @protocol.Response::error(e.to_string())
  } noraise {
    loaded => loaded
  }
  // The runtime verdict was already produced on the control side (RuntimeProbe),
  // where waiting for the helper costs nothing: doing it here would block the
  // supervision tick, which is the one thing the tick must never do.
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
/// Bare `kill` ends the daemon; there is no app form. Retiring an app is `stop`
/// (stop, stay registered) or `remove` (retire, free the name) — `kill` used to be
/// a third, harder version of `remove`, which made one verb mean two things at two
/// layers. The all-app kill itself happens in the shutdown path, after the reply
/// has reached the caller.
fn cmd_kill(app : String?) -> (@protocol.Response, ExitMode) {
  match app {
    None => (@protocol.Response::ok("bm2d stopping", []), ExitMode::Shutdown)
    Some(name) =>
      (
        @protocol.Response::error(
          "kill no longer takes a project: use 'bm2 stop " +
          name +
          "' to stop it, or 'bm2 remove " +
          name +
          "' to retire it",
        ),
        ExitMode::Stay,
      )
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
    // The mode is the project's, so the row asks the project for it. A name
    // with no project behind it cannot be listed at all.
    let mode = match self.config_of(name) {
      Some(config) => config.mode.as_string()
      None => continue
    }
    try {
      for inst in self.app_instances(name) {
        // A stopped instance is normally hidden by the listing: during a restart
        // it is a transient state between two generations. A project stopped on
        // purpose is the opposite — it stays in the registry and has to stay
        // visible, which is the whole point of `bm2 stop`. Only a project being
        // retired (`bm2 remove`) keeps its instances out of the listing.
        if !(inst.status is Status::Stopped) || self.is_stopped(name) {
          infos.push(instance_info_of(inst, now_mono, mode))
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
