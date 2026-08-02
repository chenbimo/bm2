///|
pub(all) struct Event {
  timestamp : String
  event : String
  app : String?
  instance : Int?
  pid : Int?
  detail : String?
} derive(ToJson)

///|
/// Run a side effect whose failure must not abort the caller.
pub fn discard(f : () -> Unit raise) -> Unit {
  try f() catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Append one management event. Logging failures never interrupt process
/// supervision, and event data deliberately excludes environment values and
/// protocol payloads.
pub fn log_event(
  state_dir : String,
  file : String,
  event : String,
  app? : String? = None,
  instance? : Int,
  pid? : Int,
  detail? : String,
) -> Unit {
  let record : Event = {
    timestamp: iso8601(now_ms()),
    event,
    app,
    instance,
    pid,
    detail,
  }
  discard(() => {
    @process.append_file(
      state_dir + "/" + file,
      @utf8.encode(ToJson::to_json(record).stringify() + "\n"),
    )
  })
}

///|
/// Machine-generated per-instance state. Never edited by users, so the
/// keys keep the struct's snake_case field names.
pub(all) struct InstanceState {
  app_name : String
  instance_id : Int
  pid : Int
  pgid : Int
  port : Int
  status : String
  started_at : String
  restart_count : Int
  last_exit_code : Int?
  last_signal : Int?
  last_reason : String?
} derive(ToJson, FromJson, Debug, Eq)

///|
fn InstanceState::of(inst : Instance) -> InstanceState {
  {
    app_name: inst.app_name,
    instance_id: inst.instance_id,
    pid: inst.pid,
    // bm2_spawn puts each child into its own session, so pgid == pid.
    pgid: inst.pid,
    port: inst.port,
    status: inst.status.as_string(),
    started_at: iso8601(inst.started_at_ms),
    restart_count: inst.restart_count,
    last_exit_code: inst.last_exit_code,
    last_signal: inst.last_signal,
    last_reason: inst.last_reason,
  }
}

///|
pub fn state_path(
  state_dir : String,
  app_name : String,
  instance_id : Int,
) -> String {
  "\{state_dir}/\{app_name}/\{app_name}-\{instance_id}.json"
}

///|
/// Registered project: the config path is all a daemon needs to reload
/// the project's config on startup. Written on `bm2 start`, removed once
/// the project is killed and fully stopped.
pub(all) struct ProjectInfo {
  config_path : String
} derive(ToJson, FromJson, Debug, Eq)

///|
pub fn project_path(state_dir : String, name : String) -> String {
  "\{state_dir}/\{name}/project.json"
}

///|
pub fn save_project(
  state_dir : String,
  name : String,
  info : ProjectInfo,
) -> Unit raise {
  let json = ToJson::to_json(info).stringify()
  @process.write_atomic(project_path(state_dir, name), @utf8.encode(json))
}

///|
pub fn load_project(path : String) -> ProjectInfo raise {
  @json.from_json(@json.parse(@fs.read_file_to_string(path)))
}

///|
pub fn remove_project(state_dir : String, name : String) -> Unit raise {
  @process.unlink(project_path(state_dir, name))
}

///|
/// Atomic write: "<path>.tmp" + fsync + rename, done in bm2_write_atomic.
pub fn save_state(state_dir : String, inst : Instance) -> Unit raise {
  let json = ToJson::to_json(InstanceState::of(inst)).stringify()
  let path = state_path(state_dir, inst.app_name, inst.instance_id)
  @process.write_atomic(path, @utf8.encode(json))
}

///|
pub fn load_state(path : String) -> InstanceState raise {
  @json.from_json(@json.parse(@fs.read_file_to_string(path)))
}

///|
/// Fixed per-user state directory. bm2 deliberately manages one app set
/// per Linux user, so configuration cannot override this path. Without a
/// HOME the directory falls back to /tmp so daemons never split across
/// different working directories.
pub fn resolve_state_dir() -> String {
  match @env.get_env_var("HOME") {
    Some(home) if !home.is_empty() => home + "/.bm2"
    _ => "/tmp/bm2-" + @process.get_uid().to_string()
  }
}
