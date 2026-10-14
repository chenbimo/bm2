///|
/// One bm2.toml configures exactly one project (single app, one or more
/// instances). The project name is also the app name and must be unique
/// among all registered projects.
pub(all) struct Config {
  name : String
  /// How this config was loaded: `serve` (production) or `dev` (development).
  /// It selected which `.env` files were scanned and it is the value NODE_ENV
  /// must equal, so it travels with the config rather than being re-derived
  /// further down.
  mode : Mode
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
  max_restarts : Int32
  restart_delay_ms : Int32
  min_uptime_ms : Int32
  stop_timeout_ms : Int32
  /// Notification policy for this project: which events leave the machine and
  /// where they go. Written as `[notify]` plus `[[notify.target]]` in bm2.toml,
  /// so a project's supervision and its reporting stay in one file.
  notify : NotifyConfig
  /// Log rotation for this project's instance logs, from the `[logs]` table.
  /// Kept per project because the logs are per project: one noisy app must not
  /// decide how long another one's history is.
  logs : LogsConfig
  /// The project environment, scanned from the `.env` files next to bm2.toml:
  /// `.env`, `.env.<mode>`, `.env.local`, `.env.<mode>.local`, later wins.
  ///
  /// Injected into every instance after the whitelist and before the reserved
  /// vars, and it is the same map that `${VAR}` in bm2.toml resolves against,
  /// so the application and the manager can never disagree about a value.
  env : Array[(String, String)]
} derive(Debug)

///|
pub extend Config with Debug::{to_repr}

///|
/// One notification destination. `preset` picks the platform's payload shape
/// and authentication; the remaining fields are the endpoint and its
/// credentials. url/secret/password/username are sensitive: they are never
/// echoed in errors, events or CLI output.

///|
/// A parsed standard five-field cron: minute, hour, day-of-month, month,
/// day-of-week. Every field is the full expanded set of matching values
/// (`*` expands to the whole range). Day-of-month and day-of-week may not
/// both be restricted — that combination is rejected at parse time.
pub(all) struct CronSpec {
  minutes : Array[Int32]
  hours : Array[Int32]
  days_of_month : Array[Int32]
  months : Array[Int32]
  days_of_week : Array[Int32]
} derive(Debug, Eq)

///|
pub extend CronSpec with Debug::{to_repr}

///|
pub extend CronSpec with Eq::{not_equal, equal}

///|
/// One entry of `[[notify.report]]`. Either instant (has `events`, fires on
/// events) or periodic (has `cron`, fires on schedule) — never both.
pub(all) struct NotifyReport {
  name : String
  label : String?
  /// Instant only: which events this report receives (within the gate).
  events : Array[String]?
  min_level : String?
  /// Periodic only: schedule + which preset template to render.
  cron : CronSpec?
  cron_text : String?
  template : String?
  /// Delivery endpoints of this report.
  targets : Array[NotifyEndpoint]
} derive(Debug)

///|
pub extend NotifyReport with Debug::{to_repr}

///|
/// One delivery endpoint inside a report: a platform plus its connection.
pub(all) struct NotifyEndpoint {
  platform : String
  url : String
  secret : String?
  format : String?
  /// email platform only: recipients.
  mail_to : Array[String]?
} derive(Debug)

///|
pub extend NotifyEndpoint with Debug::{to_repr}

///|
/// Which events leave this project, and where they go. Lives inside the project
/// config: a project's supervision and its reporting are one unit.
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
  events : Array[String]
  threshold_rss_percent : Int32
  threshold_offline_min : Int32
  threshold_restarts : Int32
  start_timeout_ms : Int32
  threshold_disk_mb : Int32
  threshold_storm : Int32
  reports : Array[NotifyReport]
} derive(Debug)

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
    events: [],
    threshold_rss_percent: 0,
    threshold_offline_min: 0,
    threshold_restarts: 0,
    start_timeout_ms: 0,
    threshold_disk_mb: 0,
    threshold_storm: 0,
    reports: [],
  }
}

///|
/// Log rotation for one project, from the `[logs]` table.
pub(all) struct LogsConfig {
  /// A log rotates once it exceeds this size, in megabytes.
  max_size_mb : Int32
  /// How many archived generations to keep. Zero keeps every generation, so the
  /// only bound on disk usage is the one the operator sets.
  keep : Int32
} derive(Debug)

///|
pub extend LogsConfig with Debug::{to_repr}

///|
/// The built-in rotation policy, used by a project without a `[logs]` table and
/// by the daemon's own logs (which no single project's config governs).
pub fn LogsConfig::builtin() -> LogsConfig {
  { max_size_mb: DEFAULT_LOG_MAX_SIZE_MB, keep: DEFAULT_LOG_KEEP, }
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
