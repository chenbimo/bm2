///|
/// Append one management event. Logging failures never interrupt process
/// supervision, and event data deliberately excludes environment values and
/// protocol payloads.
///
/// The parameter types differ on purpose: `app` is declared as `String?`
/// because callers forward an already-optional value into it, while
/// `instance`, `pid` and `detail` are declared as plain optionals so
/// callers pass the bare value. Both are omitted the same way.
pub fn log_event(
  state_dir : String,
  file : String,
  event : String,
  app~ : String? = None,
  instance? : Int32,
  pid? : Int32,
  detail? : String,
) -> Unit {
  let fields : Array[(String, String)] = []
  match app {
    Some(name) => fields.push(("app", @fndash.jstr(name)))
    None => ()
  }
  match instance {
    Some(id) => fields.push(("instance", id.to_string()))
    None => ()
  }
  match pid {
    Some(pid) => fields.push(("pid", pid.to_string()))
    None => ()
  }
  match detail {
    Some(text) => fields.push(("detail", @fndash.jstr(text)))
    None => ()
  }
  @fndash.discard(() => @logfly.event(state_dir + "/" + file, event, fields))
}

///|
/// Machine-generated per-instance state. Never edited by users, so the
/// keys keep the struct's snake_case field names. times is optional
/// so state files written by older versions still load.
pub(all) struct InstanceState {
  app_name : String
  instance_id : Int32
  pid : Int32
  pgid : Int32
  port : Int32
  status : String
  started_at : String
  times : Int32?
  restart_count : Int32
  last_exit_code : Int32?
  last_signal : Int32?
  last_reason : String?
} derive(ToJson, FromJson, Debug, Eq)

///|
pub extend InstanceState with ToJson::{to_json}

///|
pub extend InstanceState with FromJson::{from_json}

///|
pub extend InstanceState with Debug::{to_repr}

///|
pub extend InstanceState with Eq::{not_equal, equal}

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
    started_at: @dateku.iso8601(inst.started_at_ms),
    times: Some(inst.times),
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
  instance_id : Int32,
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
pub extend ProjectInfo with ToJson::{to_json}

///|
pub extend ProjectInfo with FromJson::{from_json}

///|
pub extend ProjectInfo with Debug::{to_repr}

///|
pub extend ProjectInfo with Eq::{not_equal, equal}

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
  @fsx.write_atomic(project_path(state_dir, name), @utf8.encode(json))
}

///|
pub fn load_project(path : String) -> ProjectInfo raise {
  @json.from_json(@json.parse(@fs.read_file_to_string(path)))
}

///|
pub fn remove_project(state_dir : String, name : String) -> Unit raise {
  @fsx.unlink(project_path(state_dir, name))
}

///|
/// Atomic write: "<path>.tmp" + fsync + rename, done in bm2_write_atomic.
pub fn save_state(state_dir : String, inst : Instance) -> Unit raise {
  let json = ToJson::to_json(InstanceState::of(inst)).stringify()
  let path = state_path(state_dir, inst.app_name, inst.instance_id)
  @fsx.write_atomic(path, @utf8.encode(json))
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
    _ => "/tmp/bm2-" + @subproc.get_uid().to_string()
  }
}
