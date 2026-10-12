///|
/// chensuiyi/notify — 多平台通知库:消息模型、平台预设渲染、HTTP/SMTP 投递,
/// 以及一个可选的去重/限流/重试引擎。设计约定:
///
/// - 所有失败原因(返回的 `String?` 中的 `Some`)永不包含凭据——url、secret、
///   password 不出现在任何错误文本里,调用方可以放心把它打进日志。
/// - 所有时间由调用方注入(`now` 参数),库自身不读时钟,保证可测。
/// - 库不写日志、不落盘、不依赖任何业务概念,只投递消息并报告结果。

///|
pub suberror NotifyError {
  InvalidPreset(String)
} derive(Debug)

///|
pub impl Show for NotifyError with fn output(self, logger) {
  match self {
    InvalidPreset(preset) => {
      logger.write_string("unknown preset: ")
      logger.write_string(preset)
    }
  }
}

///|
pub extend NotifyError with Show::{to_string, output}

///|
pub extend NotifyError with @debug.Debug::{to_repr}

///|
/// One notification. `key` is what deduplication keys on; `event` is the
/// logical event name carried through to generic webhook payloads.
pub(all) struct Message {
  event : String
  level : String
  title : String
  body : String
  fields : Array[(String, String)]
  ts_ms : UInt64
  key : String
} derive(Debug)

///|
pub extend Message with Debug::{to_repr}

///|
pub fn Message::new(
  event : String,
  level : String,
  title : String,
  body : String,
  key : String,
  ts_ms : UInt64,
  fields~ : Array[(String, String)] = [],
) -> Message {
  { event, level, title, body, fields, ts_ms, key, }
}

///|
/// One delivery destination. `preset` selects the payload shape (a closed set:
/// feishu / dingtalk / wecom / slack / discord / webhook / email); the rest are
/// endpoint and credential fields.
pub(all) struct Target {
  name : String
  preset : String
  url : String
  secret : String?
  format : String?
  from : String?
  to : Array[String]?
  username : String?
  password : String?
} derive(Debug)

///|
pub extend Target with Debug::{to_repr}

///|
/// A rendered request: what the transport hands to the network. Kept separate
/// from the message so one message can be rendered per target.
pub(all) struct Delivery {
  url : String
  http_method : String
  content_type : String?
  headers : Array[(String, String)]
  body : String
  /// email: the complete RFC5322 message.
  mail : String?
} derive(Debug)

///|
pub extend Delivery with Debug::{to_repr}

///|
/// Who is sending: appears in message footers (`product @ host`) and in the
/// SMTP EHLO greeting. Passed in by the caller so the library stays
/// platform-agnostic.
pub(all) struct Context {
  host : String
  product : String
} derive(Debug)

///|
pub extend Context with Debug::{to_repr}

///|
/// The default context for callers that do not care about branding.
pub fn Context::default() -> Context {
  { host: "localhost", product: "notify", }
}
