///|
/// The `[notify]` section of a project config: which events leave this
/// project, where they go, and on what schedule. Nothing here executes
/// code — every string is either an endpoint, a credential, or a value from
/// a closed set that validation checks. `${VAR}` expansion already happened
/// at the tree level before any of this runs.

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
fn opt_string_array(
  table : Map[String, @toml.TomlValue],
  key : String,
  ctx : String,
  default : Array[String],
) -> Array[String] raise ConfigError {
  match opt_string_array_opt(table, key, ctx) {
    Some(value) => value
    None => default
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
  "events", "threshold_rss_percent", "threshold_offline_min", "threshold_restarts",
  "start_timeout_ms", "threshold_disk_mb", "threshold_storm", "mail_url", "mail_from",
  "mail_username", "mail_password", "report",
]

///|
/// Report-level keys plus the seven platform objects. Exactly one platform
/// object per endpoint.
let reportKeys : Array[String] = [
  "name", "label", "events", "min_level", "cron", "template", "target",
]

///|
/// Every platform bm2 can render. Keeping this a closed set is what makes
/// the platform field safe to trust: no user-supplied shape reaches the
/// payload.
let platforms : Array[String] = [
  "feishu", "dingtalk", "wecom", "slack", "discord", "webhook", "email",
]

///|
let notifyEvents : Array[String] = [
  "crash", "errored", "memory_limit", "reuseport_missing", "lifecycle", "daemon",
  "threshold", "oom_kill", "disk_pressure", "start_timeout",
]

///|
let notifyLevels : Array[String] = ["info", "warn", "error"]

///|
let notifyFormats : Array[String] = ["text", "markdown", "card"]

///|
/// Preset report templates for periodic reports. The set grows over time;
/// the shape of the table does not.
let notifyTemplates : Array[String] = ["health", "stats"]

///|
/// Parse the `[notify]` table of a project config.
pub fn parse_notify_section(
  table : Map[String, @toml.TomlValue],
) -> NotifyConfig raise ConfigError {
  reject_unknown_keys(table, notifyKeys, "notify")
  let config : NotifyConfig = {
    enabled: opt_bool(table, "enabled", "notify", false),
    lang: opt_lang(table),
    timeout_ms: opt_int(table, "timeout_ms", "notify", 5000),
    dedupe_window_s: opt_int(table, "dedupe_window_s", "notify", 3600),
    max_per_minute: opt_int(table, "max_per_minute", "notify", 30),
    queue_size: opt_int(table, "queue_size", "notify", 128),
    events: opt_string_array(table, "events", "notify", []),
    threshold_rss_percent: opt_int(table, "threshold_rss_percent", "notify", 0),
    threshold_offline_min: opt_int(table, "threshold_offline_min", "notify", 0),
    threshold_restarts: opt_int(table, "threshold_restarts", "notify", 0),
    start_timeout_ms: opt_int(table, "start_timeout_ms", "notify", 0),
    threshold_disk_mb: opt_int(table, "threshold_disk_mb", "notify", 0),
    threshold_storm: opt_int(table, "threshold_storm", "notify", 0),
    mail_url: opt_string_opt(table, "mail_url", "notify"),
    mail_from: opt_string_opt(table, "mail_from", "notify"),
    mail_username: opt_string_opt(table, "mail_username", "notify"),
    mail_password: opt_string_opt(table, "mail_password", "notify"),
    reports: parse_reports(table),
  }
  validate_notify(config)
  config
}

///|
/// Notification copy language, a closed set: "en" (default) or "zh".
fn opt_lang(table : Map[String, @toml.TomlValue]) -> String raise ConfigError {
  match opt_string_opt(table, "lang", "notify") {
    Some(value) =>
      if value == "en" || value == "zh" {
        value
      } else {
        raise ConfigError::InvalidField(
          "notify.lang has unknown value \{value}",
        )
      }
    None => "en"
  }
}

///|
/// Parse the `[[notify.report]]` array: one entry is either instant
/// (events/min_level) or periodic (cron/template), plus its endpoints.
fn parse_reports(
  table : Map[String, @toml.TomlValue],
) -> Array[NotifyReport] raise ConfigError {
  match table.get("report") {
    None => []
    Some(@toml.TomlArray(items)) => {
      let reports = []
      for index, item in items {
        let ctx = "notify.report[\{index}]"
        guard item is @toml.TomlTable(fields) else {
          raise ConfigError::InvalidField("\{ctx} must be a table")
        }
        reject_unknown_keys(fields, reportKeys, ctx)
        let cron = match opt_string_opt(fields, "cron", ctx) {
          Some(text) => Some(parse_cron(text, ctx))
          None => None
        }
        let template = opt_string_opt(fields, "template", ctx)
        // cron and template are a pair; events routing is instant-only.
        if cron is Some(_) && template is None {
          raise ConfigError::InvalidField(
            "\{ctx}.cron requires template (health / stats)",
          )
        }
        if cron is None && template is Some(_) {
          raise ConfigError::InvalidField("\{ctx}.template requires cron")
        }
        match template {
          Some(value) =>
            if !notifyTemplates.contains(value) {
              raise ConfigError::InvalidField(
                "\{ctx}.template has unknown value \{value}",
              )
            }
          None => ()
        }
        if cron is Some(_) {
          if fields.contains("events") {
            raise ConfigError::InvalidField(
              "\{ctx}.events is not used by a periodic report",
            )
          }
          if fields.contains("min_level") {
            raise ConfigError::InvalidField(
              "\{ctx}.min_level is not used by a periodic report",
            )
          }
        }
        reports.push({
          name: req_string(fields, "name", ctx),
          label: opt_string_opt(fields, "label", ctx),
          events: opt_string_array_opt(fields, "events", ctx),
          min_level: opt_string_opt(fields, "min_level", ctx),
          cron,
          cron_text: opt_string_opt(fields, "cron", ctx),
          template,
          targets: parse_endpoints(fields, ctx),
        })
      }
      reports
    }
    Some(_) =>
      raise ConfigError::InvalidField("report must be an array of tables")
  }
}

///|
/// Endpoints of one report: `[[notify.report.target]]` elements.
fn parse_endpoints(
  fields : Map[String, @toml.TomlValue],
  ctx : String,
) -> Array[NotifyEndpoint] raise ConfigError {
  match fields.get("target") {
    None => []
    Some(@toml.TomlArray(items)) => {
      let endpoints = []
      for index, item in items {
        let endpoint_ctx = "\{ctx}.target[\{index}]"
        guard item is @toml.TomlTable(endpoint) else {
          raise ConfigError::InvalidField("\{endpoint_ctx} must be a table")
        }
        let endpoint_keys = ["platform", "url", "secret", "format", "to"]
        reject_unknown_keys(endpoint, endpoint_keys, endpoint_ctx)
        let platform = req_string(endpoint, "platform", endpoint_ctx)
        if !platforms.contains(platform) {
          raise ConfigError::InvalidField(
            "\{endpoint_ctx}.platform has unknown value \{platform}",
          )
        }
        let is_email = platform == "email"
        let url = if is_email {
          "" // the mail channel owns the SMTP endpoint
        } else {
          req_string(endpoint, "url", endpoint_ctx)
        }
        let secret = opt_string_opt(endpoint, "secret", endpoint_ctx)
        match opt_string_opt(endpoint, "format", endpoint_ctx) {
          Some(format) =>
            if !notifyFormats.contains(format) {
              raise ConfigError::InvalidField(
                "\{endpoint_ctx}.format has unknown value \{format}",
              )
            }
          None => ()
        }
        let mail_to = match endpoint.get("to") {
          None => None
          Some(@toml.TomlArray(items)) => {
            let recipients = []
            for recipient in items {
              guard recipient is @toml.TomlString(text) else {
                raise ConfigError::InvalidField(
                  "\{endpoint_ctx}.to must be strings",
                )
              }
              recipients.push(text)
            }
            Some(recipients)
          }
          Some(_) =>
            raise ConfigError::InvalidField(
              "\{endpoint_ctx}.to must be an array",
            )
        }
        endpoints.push({
          platform,
          url,
          secret,
          format: opt_string_opt(endpoint, "format", endpoint_ctx),
          mail_to,
        })
      }
      endpoints
    }
    Some(_) =>
      raise ConfigError::InvalidField(
        "\{ctx}.target must be an array of tables",
      )
  }
}

///|
/// Digits-only text to a non-negative Int; None on any other character.
fn digits_to_int(text : StringView) -> Int32? {
  let mut value = 0
  for c in text {
    let v = c.to_int()
    if v < 48 || v > 57 {
      return None
    }
    value = value * 10 + (v - 48)
  }
  Some(value)
}

///|
/// Expand one cron field: `*` (whole range), `*/n` (stepped), a number, or
/// a comma list of numbers. `base` and `max` define the field's range.
fn cron_field(
  text : StringView,
  base : Int32,
  max : Int32,
  ctx : String,
  what : String,
) -> Array[Int32] raise ConfigError {
  let values : Array[Int32] = []
  for part in text.split(",") {
    if part == "*" {
      for v in base..<=max {
        values.push(v)
      }
      continue
    }
    if part.has_prefix("*/") {
      let step = match digits_to_int(part[2:]) {
        Some(v) => v
        None =>
          raise ConfigError::InvalidField(
            "\{ctx} cron \{what} has invalid step",
          )
      }
      guard step >= 1 else {
        raise ConfigError::InvalidField(
          "\{ctx} cron \{what} step must be at least 1",
        )
      }
      let mut v = base
      while v <= max {
        values.push(v)
        v += step
      }
      continue
    }
    match digits_to_int(part) {
      Some(v) =>
        if v >= base && v <= max {
          values.push(v)
        } else {
          raise ConfigError::InvalidField(
            "\{ctx} cron \{what} value \{v} must be between \{base} and \{max}",
          )
        }
      None =>
        raise ConfigError::InvalidField("\{ctx} cron \{what} has invalid value")
    }
  }
  values
}

///|
/// Parse a standard five-field cron: minute hour day-of-month month
/// day-of-week. Supports `*`, `*/n`, numbers and comma lists. Day-of-month
/// and day-of-week may not both be restricted.
pub fn parse_cron(text : String, ctx : String) -> CronSpec raise ConfigError {
  let parts = text.split(" ").collect()
  guard parts.length() == 5 else {
    raise ConfigError::InvalidField(
      "\{ctx}.cron must have five fields (minute hour day month weekday)",
    )
  }
  let minutes = cron_field(parts[0], 0, 59, ctx, "minute")
  let hours = cron_field(parts[1], 0, 23, ctx, "hour")
  // Both restricted (neither is `*`) is the classic confusing cron case.
  let dom_limited = !(parts[2] == "*")
  let dow_limited = !(parts[4] == "*")
  if dom_limited && dow_limited {
    raise ConfigError::InvalidField(
      "\{ctx}.cron restricts both day-of-month and day-of-week; leave one of them as *",
    )
  }
  let days = cron_field(parts[2], 1, 31, ctx, "day-of-month")
  let months = cron_field(parts[3], 1, 12, ctx, "month")
  // Weekday: cfg 0 and 7 both mean Sunday, 1~6 = Monday..Saturday; stored
  // in tm_wday convention (0=Sunday..6=Saturday).
  let weekdays_raw = cron_field(parts[4], 0, 7, ctx, "day-of-week")
  let weekdays = weekdays_raw.map(fn(w) { w % 7 })
  { minutes, hours, days_of_month: days, months, days_of_week: weekdays, }
}
