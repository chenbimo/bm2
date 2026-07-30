///|
pub(all) struct Request {
  command : String
  app : String?
} derive(ToJson, FromJson, Debug, Eq)

///|
pub(all) struct InstanceInfo {
  app_name : String
  instance_id : Int
  pid : Int
  port : Int
  status : String
  restart_count : Int
  rss_kb : Int
  uptime_ms : UInt64
  last_reason : String?
} derive(ToJson, FromJson, Debug, Eq)

///|
pub(all) struct Response {
  ok : Bool
  message : String
  instances : Array[InstanceInfo]
} derive(ToJson, FromJson, Debug, Eq)

///|
/// Live snapshot of one instance. rss_kb is -1 when unavailable,
/// uptime_ms is 0 when the instance is not running.
pub fn InstanceInfo::of(inst : Instance, now : UInt64) -> InstanceInfo {
  let rss_kb = if inst.status is Online {
    match @process.read_rss_kb(inst.pid) {
      Some(kb) => kb
      None => -1
    }
  } else {
    -1
  }
  let uptime_ms = if inst.pid > 0 && inst.started_at_ms > 0UL {
    now - inst.started_at_ms
  } else {
    0UL
  }
  {
    app_name: inst.app_name,
    instance_id: inst.instance_id,
    pid: inst.pid,
    port: inst.port,
    status: inst.status.as_string(),
    restart_count: inst.restart_count,
    rss_kb,
    uptime_ms,
    last_reason: inst.last_reason,
  }
}

///|
pub fn Response::ok(
  message : String,
  instances : Array[InstanceInfo],
) -> Response {
  { ok: true, message, instances }
}

///|
pub fn Response::error(message : String) -> Response {
  { ok: false, message, instances: [] }
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
