///|
/// One bm2.toml configures exactly one project (single app, one or more
/// instances). The project name is also the app name and must be unique
/// among all registered projects.
#derive(Debug)
pub(all) struct Config {
  name : String
  /// The language this project's own copy is written in, when it states one.
  ///
  /// None means "follow whoever is looking": the operator's environment for what
  /// is printed to a terminal, this daemon's environment for lines it writes on
  /// its own (its log). It is per project because a project is what a message is
  /// about — and because a server in one country and an operator in another is a
  /// normal arrangement.
  lang : @i18n.Lang?
  cwd : String
  script : String
  runtime : String
  exec_mode : String
  instances : Int32
  port : Int32
  max_memory_mb : Int32
  /// How many processes one instance's tree may contain before the memory
  /// walk stops. Bounds the cost of summing RSS over children the app forked
  /// itself, so a fork bomb cannot stall a supervision tick.
  max_tree_processes : Int32
  max_restarts : Int32
  restart_delay_ms : Int32
  min_uptime_ms : Int32
  stop_timeout_ms : Int32
  /// Notification policy for this project: which events leave the machine and
  /// where they go. Written as `[notify]` plus `[[notify.target]]` in bm2.toml,
  /// so a project's supervision and its reporting stay in one file.
  notify : NotifyConfig
  /// Log rotation for this project's instance logs, from the `log_*` keys.
  /// Kept per project because the logs are per project: one noisy app must not
  /// decide how long another one's history is.
  logs : LogsConfig
}

///|
pub extend Config with Debug::{to_repr}

///|
/// One notification destination. `preset` picks the platform's payload shape
/// and authentication; the remaining fields are the endpoint and its
/// credentials. url/secret/password/username are sensitive: they are never
/// echoed in errors, events or CLI output.

///|
/// 一个目标收哪些事件。
///
/// 不写 `events` 是 `All`；写普通项是白名单 `Only`；写 `!` 前缀是排除式
/// `Except`。白名单与排除式不能混写——两者语义相反，混在一起就得解释
/// 「谁先谁后」，而那种规则没人记得住。
#derive(Debug, Eq)
pub(all) enum EventFilter {
  All
  Only(Array[String])
  Except(Array[String])
}

///|
pub extend EventFilter with Debug::{to_repr}

///|
pub extend EventFilter with Eq::{not_equal, equal}

///|
/// One delivery target: a platform, its connection, and which events it takes.
#derive(Debug)
pub(all) struct NotifyTarget {
  platform : String
  url : String
  secret : String?
  format : String?
  /// email platform only: recipients. The send capability itself lives on
  /// `NotifyConfig` so it is configured once for the whole project.
  mail_to : Array[String]?
  filter : EventFilter
}

///|
pub extend NotifyTarget with Debug::{to_repr}

///|
/// 谁收通知、收到哪些事件，以及告警的判定阈值。
///
/// 只有两个概念：**事件**（11 类，含每日统计 `daily_stats`）与 **目标**
/// （`NotifyTarget`）。目标自己带过滤，所以不需要继承，也不需要报告这一层。
#derive(Debug)
pub(all) struct NotifyConfig {
  enabled : Bool
  /// Mail channel: send capability configured once, used by every email
  /// target. Targets only carry recipients (mail_to).
  mail_url : String?
  mail_from : String?
  mail_username : String?
  mail_password : String?
  /// Notification copy language: "en" (default) or "zh". Only what a human
  /// reads in a chat group is translated; CLI/log/JSON stay language-neutral.
  lang : String
  timeout_ms : Int32
  dedupe_window_s : Int32
  max_per_minute : Int32
  queue_size : Int32
  /// 每日统计的整点（1..23）。它只回答「什么时候发」；「发不发」由有没有
  /// 目标订阅 `daily_stats` 决定——所以没人订阅时这里留着也不报错。
  daily_report_hour : Int32
  threshold_rss_percent : Int32
  threshold_offline_min : Int32
  threshold_restarts : Int32
  start_timeout_ms : Int32
  threshold_disk_mb : Int32
  threshold_storm : Int32
  targets : Array[NotifyTarget]
}

///|
pub extend NotifyConfig with Debug::{to_repr}

///|
/// Notifications are off until a project says otherwise, so a bm2.toml without
/// a notify section is a valid, silent project.
pub fn NotifyConfig::disabled() -> NotifyConfig {
  {
    enabled: false,
    mail_url: None,
    mail_from: None,
    mail_username: None,
    mail_password: None,
    lang: "en",
    timeout_ms: 5000,
    dedupe_window_s: 3600,
    max_per_minute: 30,
    queue_size: 128,
    daily_report_hour: 8,
    threshold_rss_percent: 0,
    threshold_offline_min: 0,
    threshold_restarts: 0,
    start_timeout_ms: 0,
    threshold_disk_mb: 0,
    threshold_storm: 0,
    targets: [],
  }
}

///|
/// Log rotation for one project, from the `log_*` keys.
#derive(Debug)
pub(all) struct LogsConfig {
  /// A log rotates once it exceeds this size, in megabytes.
  max_size_mb : Int32
  /// 保留几代历史（普通日志与错误日志各算各的）。0 表示不留历史，只留当前那一份。
  keep_files : Int32
}

///|
pub extend LogsConfig with Debug::{to_repr}

///|
/// The built-in rotation policy, used by a project without the `log_*` keys and
/// by the daemon's own logs (which no single project's config governs).
pub fn LogsConfig::builtin() -> LogsConfig {
  { max_size_mb: DEFAULT_LOG_MAX_SIZE_MB, keep_files: DEFAULT_LOG_KEEP_FILES, }
}

///|
pub(all) suberror ConfigError {
  InvalidDocument(String)
  InvalidField(String)
}

///|
pub impl Show for ConfigError with fn output(self, logger) {
  match self {
    InvalidDocument(message) => {
      logger.write_string("InvalidDocument: ")
      logger.write_string(message)
    }
    InvalidField(message) => {
      logger.write_string("InvalidField: ")
      logger.write_string(message)
    }
  }
}

///|
pub extend ConfigError with Show::{to_string, output}
