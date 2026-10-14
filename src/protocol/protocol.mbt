///|
/// Wire protocol revision. Bump it whenever Request or Response changes in
/// a way an older peer cannot read, so version skew between a freshly
/// installed CLI and a still-running daemon is reported as such instead of
/// surfacing as an unexplained decode failure.
///
/// A change the old peer *can* parse still needs a bump when its meaning
/// moved: `force` was added this way, and a daemon that predates it would
/// ignore the field, answer a forced retire with a graceful stop, and let the
/// caller believe it succeeded. That silent case is the dangerous one — a
/// decode failure at least announces itself.
///
/// Version 5 is the environment rework. `serve`/`dev` replaced `start`, and an
/// instance row now carries the mode it runs in. An older daemon answers
/// `unknown command` for both verbs, which is loud and would be survivable on
/// its own, but its listing also decodes as a row with no mode — so the two
/// sides are made to agree about the whole protocol instead.
///
/// Version 6 added `lang`. A daemon that predates it would ignore the field and
/// answer in English while the CLI printed Chinese: one screen, two languages,
/// and nothing to announce it. That is the silent case again.
pub const PROTOCOL_VERSION : Int32 = 6

///|
/// One CLI request. The field is optional so a peer predating versioning
/// still decodes, and the mismatch is then reported by name.
pub(all) struct Request {
  protocol : Int32?
  command : String
  app : String?
  /// Config path of the caller's project; used by `start` to register it.
  config_path : String?
  /// Notification target name; used by `notify` to test one destination
  /// instead of all of them.
  notify_target : String?
  /// `remove`: retire the project without waiting for a graceful stop, and let
  /// the caller purge its state directory afterwards.
  force : Bool?
  /// The language the CLI resolved for this request, so the daemon answers in the
  /// language the answer will be read in. Optional, and absent means English —
  /// which is what an unset locale means too, and what every test asserts.
  lang : String?
} derive(ToJson, FromJson, Debug, Eq)

///|
pub extend Request with ToJson::{to_json}

///|
pub extend Request with FromJson::{from_json}

///|
pub extend Request with Debug::{to_repr}

///|
pub extend Request with Eq::{not_equal, equal}

///|
pub(all) struct InstanceInfo {
  app_name : String
  /// The mode this instance's project was started in. It decided which `.env`
  /// files were read and it is the instance's NODE_ENV. A project-level fact
  /// repeated on every row, because the listing is what an operator reads.
  mode : String
  cwd : String
  instance_id : Int32
  pid : Int32
  port : Int32
  exec_mode : String
  status : String
  times : Int32
  restart_count : Int32
  rss_kb : Int32
  uptime_ms : UInt64
  last_reason : String?
} derive(ToJson, FromJson, Debug, Eq)

///|
pub extend InstanceInfo with ToJson::{to_json}

///|
pub extend InstanceInfo with FromJson::{from_json}

///|
pub extend InstanceInfo with Debug::{to_repr}

///|
pub extend InstanceInfo with Eq::{not_equal, equal}

///|
pub(all) struct Response {
  protocol : Int32?
  ok : Bool
  message : String
  instances : Array[InstanceInfo]
  /// Present on `list` answers from a daemon that reports about itself. Optional
  /// on the wire: an older CLI ignores it and a newer CLI accepts a daemon that
  /// does not send it yet, so neither side needs a protocol bump.
  daemon : DaemonInfo?
} derive(ToJson, FromJson, Debug, Eq)

///|
pub extend Response with ToJson::{to_json}

///|
pub extend Response with FromJson::{from_json}

///|
pub extend Response with Debug::{to_repr}

///|
pub extend Response with Eq::{not_equal, equal}

///|
pub fn Response::ok(
  message : String,
  instances : Array[InstanceInfo],
) -> Response {
  {
    protocol: Some(PROTOCOL_VERSION),
    ok: true,
    message,
    instances,
    daemon: None,
  }
}

///|
pub fn Response::error(message : String) -> Response {
  {
    protocol: Some(PROTOCOL_VERSION),
    ok: false,
    message,
    instances: [],
    daemon: None,
  }
}

///|
/// What a `list` answer can carry about the daemon itself: the numbers an
/// operator cannot read off the instance table.
pub(all) struct DaemonInfo {
  pid : Int32
  /// Milliseconds since this daemon started (monotonic, so it is a duration).
  uptime_ms : UInt64
  /// Instances under management, across every project.
  instances : Int32
  /// Commands applied since start: monotonic, so two samples show whether the
  /// control plane is moving.
  commands_applied : UInt64
  /// Projects waiting for a restart, and projects waiting to be unregistered.
  pending_restarts : Int32
  pending_removals : Int32
} derive(ToJson, FromJson, Debug, Eq)

///|
pub extend DaemonInfo with ToJson::{to_json}

///|
pub extend DaemonInfo with FromJson::{from_json}

///|
pub extend DaemonInfo with Debug::{to_repr}

///|
pub extend DaemonInfo with Eq::{not_equal, equal}

///|
/// Human-readable protocol mismatch, or None when both sides agree. Kept
/// here so the CLI and the daemon describe the same condition the same way.
pub fn protocol_problem(peer : Int32?) -> String? {
  match peer {
    Some(version) =>
      if version == PROTOCOL_VERSION {
        None
      } else {
        Some(
          "protocol mismatch: the other side speaks \{version}, this binary speaks \{PROTOCOL_VERSION}; run 'bm2 reload'",
        )
      }
    None =>
      Some(
        "protocol mismatch: the other side predates protocol versioning; run 'bm2 reload'",
      )
  }
}

///|
pub fn encode_request(req : Request) -> Bytes {
  @utf8.encode(ToJson::to_json(req).stringify())
}

///|
pub fn decode_request(data : Bytes) -> Request raise {
  @json.from_json(@json.parse(@utf8.decode(data)))
}

///|
pub fn encode_response(resp : Response) -> Bytes {
  @utf8.encode(ToJson::to_json(resp).stringify())
}

///|
pub fn decode_response(data : Bytes) -> Response raise {
  @json.from_json(@json.parse(@utf8.decode(data)))
}
