///|
/// Wire protocol revision. Bump it whenever Request or Response changes in
/// a way an older peer cannot read, so version skew between a freshly
/// installed CLI and a still-running daemon is reported as such instead of
/// surfacing as an unexplained decode failure.
pub const PROTOCOL_VERSION : Int = 1

///|
/// One CLI request. The field is optional so a peer predating versioning
/// still decodes, and the mismatch is then reported by name.
pub(all) struct Request {
  protocol : Int?
  command : String
  app : String?
  /// Config path of the caller's project; used by `start` to register it.
  config_path : String?
} derive(ToJson, FromJson, Debug, Eq)

///|
pub(all) struct InstanceInfo {
  app_name : String
  cwd : String
  instance_id : Int
  pid : Int
  port : Int
  exec_mode : String
  status : String
  times : Int
  restart_count : Int
  rss_kb : Int
  uptime_ms : UInt64
  last_reason : String?
} derive(ToJson, FromJson, Debug, Eq)

///|
pub(all) struct Response {
  protocol : Int?
  ok : Bool
  message : String
  instances : Array[InstanceInfo]
} derive(ToJson, FromJson, Debug, Eq)

///|
pub fn Response::ok(
  message : String,
  instances : Array[InstanceInfo],
) -> Response {
  { protocol: Some(PROTOCOL_VERSION), ok: true, message, instances, }
}

///|
pub fn Response::error(message : String) -> Response {
  { protocol: Some(PROTOCOL_VERSION), ok: false, message, instances: [], }
}

///|
/// Human-readable protocol mismatch, or None when both sides agree. Kept
/// here so the CLI and the daemon describe the same condition the same way.
pub fn protocol_problem(peer : Int?) -> String? {
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
