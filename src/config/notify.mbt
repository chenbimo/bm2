///|
/// `[notify]` 段的解析：谁收、收哪些事件、告警阈值。
///
/// 只有两层结构：`[notify]` 全局参数 + `[[notify.target]]` 目标列表。每个目标
/// 自带事件过滤，所以没有继承、没有报告、没有 cron——这些概念曾经存在，代价是
/// 用户要先想清楚「哪一层覆盖哪一层」才能写对一个地址。

///|
fn opt_bool(
  table : Map[String, @toml.TomlValue],
  key : String,
  ctx : String,
  default : Bool,
) -> Bool raise ConfigError {
  match opt_bool_opt(table, key, ctx) {
    Some(value) => value
    None => default
  }
}

///|
/// An optional boolean. A quoted string is accepted when it spells one, for the
/// same reason integers take one: `${VAR}` expands inside strings, so a flag
/// driven by a `.env` file arrives quoted.
fn opt_bool_opt(
  table : Map[String, @toml.TomlValue],
  key : String,
  ctx : String,
) -> Bool? raise ConfigError {
  match table.get(key) {
    None => None
    Some(@toml.TomlBoolean(value)) => Some(value)
    Some(@toml.TomlString(text)) =>
      match text {
        "true" => Some(true)
        "false" => Some(false)
        _ =>
          raise ConfigError::InvalidField(
            "\{ctx}.\{key} must be a boolean, but is \"\{text}\"",
          )
      }
    Some(_) =>
      raise ConfigError::InvalidField("\{ctx}.\{key} must be a boolean")
  }
}

///|
fn opt_string_opt(
  table : Map[String, @toml.TomlValue],
  key : String,
  ctx : String,
) -> String? raise ConfigError {
  match table.get(key) {
    None => None
    Some(@toml.TomlString(value)) => Some(value)
    Some(_) => raise ConfigError::InvalidField("\{ctx}.\{key} must be a string")
  }
}

///|
fn opt_string_array_opt(
  table : Map[String, @toml.TomlValue],
  key : String,
  ctx : String,
) -> Array[String]? raise ConfigError {
  match table.get(key) {
    None => None
    Some(@toml.TomlArray(items)) => {
      let out = []
      for index, item in items {
        guard item is @toml.TomlString(value) else {
          raise ConfigError::InvalidField(
            "\{ctx}.\{key}[\{index}] must be a string",
          )
        }
        out.push(value)
      }
      Some(out)
    }
    Some(_) =>
      raise ConfigError::InvalidField(
        "\{ctx}.\{key} must be an array of strings",
      )
  }
}

///|
let notifyKeys : Array[String] = [
  "enabled", "lang", "timeout_ms", "dedupe_window_s", "max_per_minute", "queue_size",
  "daily_report_hour", "threshold_rss_percent", "threshold_offline_min", "threshold_restarts",
  "start_timeout_ms", "threshold_disk_mb", "threshold_storm", "mail_url", "mail_from",
  "mail_username", "mail_password", "target",
]

///|
/// One entry of `[[notify.target]]`.
let targetKeys : Array[String] = [
  "platform", "url", "events", "secret", "format", "to",
]

///|
/// Every platform bm2 can render. Keeping this a closed set is what makes
/// the platform field safe to trust: no user-supplied shape reaches the
/// payload.
let platforms : Array[String] = [
  "feishu", "dingtalk", "wecom", "slack", "discord", "webhook", "email",
]

///|
/// 十类"发生了某事"的事件，加上到点触发的 `daily_stats`。
let notifyEvents : Array[String] = [
  "crash", "errored", "memory_limit", "reuseport_missing", "lifecycle", "daemon",
  "threshold", "oom_kill", "disk_pressure", "start_timeout", "daily_stats",
]

///|
let notifyFormats : Array[String] = ["text", "markdown", "card"]

///|
/// 告警阈值的推荐值：不写就是这些，写 0 才表示关闭该项。
const DEFAULT_THRESHOLD_RSS_PERCENT : Int32 = 80

///|
const DEFAULT_THRESHOLD_OFFLINE_MIN : Int32 = 5

///|
const DEFAULT_THRESHOLD_RESTARTS : Int32 = 5

///|
const DEFAULT_START_TIMEOUT_MS : Int32 = 30000

///|
const DEFAULT_THRESHOLD_DISK_MB : Int32 = 1024

///|
const DEFAULT_THRESHOLD_STORM : Int32 = 20

///|
/// 每日统计的默认整点。只表达"什么时候发"；"发不发"由有没有目标订阅
/// `daily_stats` 决定。
const DEFAULT_DAILY_REPORT_HOUR : Int32 = 8

///|
/// The default is the project's own language rather than a constant: notification
/// copy is part of the project, so a project that says `lang = "zh"` gets Chinese
/// notices without a second knob. `[notify] lang` still overrides it, because a
/// chat group and a terminal can want different languages.
fn opt_lang(
  table : Map[String, @toml.TomlValue],
  default~ : String,
) -> String raise ConfigError {
  match opt_string_opt(table, "lang", "notify") {
    Some(value) =>
      match @i18n.Lang::from_name(value) {
        Some(_) => value
        None =>
          raise ConfigError::InvalidField(
            "notify.lang is not supported: \{value}",
          )
      }
    None => default
  }
}

///|
/// Parse the `[notify]` table of a project config.
pub fn parse_notify_section(
  table : Map[String, @toml.TomlValue],
  default_lang~ : String,
) -> NotifyConfig raise ConfigError {
  reject_unknown_keys(table, notifyKeys, "notify")
  let daily_hour = opt_int(
    table,
    "daily_report_hour",
    "notify",
    DEFAULT_DAILY_REPORT_HOUR,
  )
  if daily_hour < 1 || daily_hour > 23 {
    raise ConfigError::InvalidField(
      "notify.daily_report_hour must be between 1 and 23",
    )
  }
  let config : NotifyConfig = {
    enabled: opt_bool(table, "enabled", "notify", false),
    lang: opt_lang(table, default=default_lang),
    timeout_ms: opt_int(table, "timeout_ms", "notify", 5000),
    dedupe_window_s: opt_int(table, "dedupe_window_s", "notify", 3600),
    max_per_minute: opt_int(table, "max_per_minute", "notify", 30),
    queue_size: opt_int(table, "queue_size", "notify", 128),
    daily_report_hour: daily_hour,
    threshold_rss_percent: opt_int(
      table,
      "threshold_rss_percent",
      "notify",
      DEFAULT_THRESHOLD_RSS_PERCENT,
    ),
    threshold_offline_min: opt_int(
      table,
      "threshold_offline_min",
      "notify",
      DEFAULT_THRESHOLD_OFFLINE_MIN,
    ),
    threshold_restarts: opt_int(
      table,
      "threshold_restarts",
      "notify",
      DEFAULT_THRESHOLD_RESTARTS,
    ),
    start_timeout_ms: opt_int(
      table,
      "start_timeout_ms",
      "notify",
      DEFAULT_START_TIMEOUT_MS,
    ),
    threshold_disk_mb: opt_int(
      table,
      "threshold_disk_mb",
      "notify",
      DEFAULT_THRESHOLD_DISK_MB,
    ),
    threshold_storm: opt_int(
      table,
      "threshold_storm",
      "notify",
      DEFAULT_THRESHOLD_STORM,
    ),
    mail_url: opt_string_opt(table, "mail_url", "notify"),
    mail_from: opt_string_opt(table, "mail_from", "notify"),
    mail_username: opt_string_opt(table, "mail_username", "notify"),
    mail_password: opt_string_opt(table, "mail_password", "notify"),
    targets: parse_targets(table),
  }
  validate_notify(config)
  config
}

///|
/// `[[notify.target]]` 数组：每个目标的平台、连接与事件过滤。
fn parse_targets(
  table : Map[String, @toml.TomlValue],
) -> Array[NotifyTarget] raise ConfigError {
  match table.get("target") {
    None => []
    Some(@toml.TomlArray(items)) => {
      let targets = []
      for index, item in items {
        let ctx = "notify.target[\{index}]"
        guard item is @toml.TomlTable(fields) else {
          raise ConfigError::InvalidField("\{ctx} must be a table")
        }
        reject_unknown_keys(fields, targetKeys, ctx)
        let platform = req_string(fields, "platform", ctx)
        if !platforms.contains(platform) {
          raise ConfigError::InvalidField(
            "\{ctx}.platform has unknown value \{platform}",
          )
        }
        let is_email = platform == "email"
        // The mail channel owns the SMTP endpoint; an email target only names
        // its recipients, so several targets can share one channel. A url here
        // is a mistake worth naming instead of silently dropping.
        let url = if is_email {
          if fields.contains("url") {
            raise ConfigError::InvalidField("\{ctx}.url is not used by email")
          }
          ""
        } else {
          req_string(fields, "url", ctx)
        }
        match opt_string_opt(fields, "format", ctx) {
          Some(format) =>
            if !notifyFormats.contains(format) {
              raise ConfigError::InvalidField(
                "\{ctx}.format has unknown value \{format}",
              )
            }
          None => ()
        }
        let mail_to = match opt_string_array_opt(fields, "to", ctx) {
          Some(recipients) => {
            if recipients.length() == 0 {
              raise ConfigError::InvalidField(
                "\{ctx}.to must name at least one recipient",
              )
            }
            Some(recipients)
          }
          None => None
        }
        if is_email && mail_to is None {
          raise ConfigError::InvalidField("\{ctx}.to is required for email")
        }
        targets.push({
          platform,
          url,
          secret: opt_string_opt(fields, "secret", ctx),
          format: opt_string_opt(fields, "format", ctx),
          mail_to,
          filter: parse_event_filter(fields, ctx),
        })
      }
      targets
    }
    Some(_) =>
      raise ConfigError::InvalidField(
        "notify.target must be an array of tables",
      )
  }
}

///|
/// `events` 的三种写法：不写 = 全部；普通项 = 白名单；`!` 前缀 = 排除式。
/// 混写直接报错——两种语义相反，混在一起就只能靠"谁先谁后"解释，而那种规则
/// 没人记得住。
fn parse_event_filter(
  fields : Map[String, @toml.TomlValue],
  ctx : String,
) -> EventFilter raise ConfigError {
  let items = match opt_string_array_opt(fields, "events", ctx) {
    None => return EventFilter::All
    Some(items) => items
  }
  if items.length() == 0 {
    raise ConfigError::InvalidField(
      "\{ctx}.events must list at least one event (omit it to take all)",
    )
  }
  let included : Array[String] = []
  let excluded : Array[String] = []
  for item in items {
    if item.has_prefix("!") {
      let name = item[1:].to_owned()
      check_event_name(name, ctx)
      excluded.push(name)
    } else {
      check_event_name(item, ctx)
      included.push(item)
    }
  }
  if included.length() > 0 && excluded.length() > 0 {
    raise ConfigError::InvalidField(
      "\{ctx}.events cannot mix plain names and !exclusions",
    )
  }
  if excluded.length() > 0 {
    EventFilter::Except(excluded)
  } else {
    EventFilter::Only(included)
  }
}

///|
fn check_event_name(name : String, ctx : String) -> Unit raise ConfigError {
  if !notifyEvents.contains(name) {
    raise ConfigError::InvalidField("\{ctx}.events has unknown event \{name}")
  }
}

///|
/// 一个目标是否接收某事件。纯函数，路由与测试共用。
pub fn EventFilter::accepts(self : EventFilter, event : String) -> Bool {
  match self {
    All => true
    Only(names) => names.contains(event)
    Except(names) => !names.contains(event)
  }
}
