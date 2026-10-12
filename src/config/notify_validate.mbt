///|
/// Validation for the `[notify]` section. Every failure names the field and
/// the report/endpoint index; no error ever echoes a URL or a credential.

///|
fn check_int_range(
  value : Int32,
  low : Int32,
  high : Int32,
  ctx : String,
) -> Unit raise ConfigError {
  if value < low || value > high {
    raise ConfigError::InvalidField("\{ctx} must be between \{low} and \{high}")
  }
}

///|
fn check_members(
  values : Array[String],
  allowed : Array[String],
  ctx : String,
) -> Unit raise ConfigError {
  for value in values {
    if !allowed.contains(value) {
      raise ConfigError::InvalidField("\{ctx} has unknown value \{value}")
    }
  }
}

///|
fn check_web_scheme(url : String, ctx : String) -> Unit raise ConfigError {
  if url.has_prefix("http://") || url.has_prefix("https://") {
    return
  }
  raise ConfigError::InvalidField(
    "\{ctx}.url must start with http:// or https://",
  )
}

///|
pub fn validate_notify(config : NotifyConfig) -> Unit raise ConfigError {
  check_int_range(config.timeout_ms, 100, 60000, "notify.timeout_ms")
  check_int_range(config.dedupe_window_s, 0, 604800, "notify.dedupe_window_s")
  check_int_range(config.max_per_minute, 0, 6000, "notify.max_per_minute")
  check_int_range(config.queue_size, 1, 4096, "notify.queue_size")
  check_int_range(
    config.threshold_rss_percent,
    0,
    100,
    "notify.threshold_rss_percent",
  )
  check_int_range(
    config.threshold_offline_min,
    0,
    1440,
    "threshold_offline_min",
  )
  check_int_range(
    config.threshold_restarts,
    0,
    1000,
    "notify.threshold_restarts",
  )
  check_int_range(config.start_timeout_ms, 0, 600000, "notify.start_timeout_ms")
  check_int_range(
    config.threshold_disk_mb,
    0,
    1048576,
    "notify.threshold_disk_mb",
  )
  check_int_range(config.threshold_storm, 0, 1000, "notify.threshold_storm")
  check_members(config.events, notifyEvents, "notify.events")
  // The mail channel must exist before any email endpoint can use it.
  match config.mail_url {
    Some(url) =>
      if !url.has_prefix("smtp://") && !url.has_prefix("smtps://") {
        raise ConfigError::InvalidField(
          "notify.mail_url must start with smtp:// or smtps://",
        )
      }
    None => ()
  }
  let seen : Map[String, Unit] = Map([])
  for index, report in config.reports {
    // The index and the report name are what a message may mention.
    let ctx = "notify.report[\{index}]"
    if report.name.is_empty() {
      raise ConfigError::InvalidField("\{ctx}.name must not be empty")
    }
    if seen.contains(report.name) {
      raise ConfigError::InvalidField("duplicate report name: \{report.name}")
    }
    seen[report.name] = ()
    match report.min_level {
      Some(level) => check_members([level], notifyLevels, "\{ctx}.min_level")
      None => ()
    }
    // Instant reports route events; periodic reports need endpoints too.
    if report.cron is None {
      match report.events {
        Some(events) => check_members(events, notifyEvents, "\{ctx}.events")
        None => ()
      }
    }
    if report.targets.is_empty() {
      raise ConfigError::InvalidField(
        "\{ctx} must configure at least one [[notify.report.target]]",
      )
    }
    for endpoint_index, endpoint in report.targets {
      let endpoint_ctx = "\{ctx}.target[\{endpoint_index}]"
      match endpoint.platform {
        "email" => {
          match endpoint.mail_to {
            Some(recipients) =>
              if recipients.is_empty() {
                raise ConfigError::InvalidField(
                  "\{endpoint_ctx}.email.to must not be empty",
                )
              }
            None =>
              raise ConfigError::InvalidField(
                "\{endpoint_ctx}.email.to is required",
              )
          }
          match config.mail_url {
            Some(_) => ()
            None =>
              raise ConfigError::InvalidField(
                "\{endpoint_ctx} uses the email platform but notify has no mail_url",
              )
          }
        }
        "feishu" | "dingtalk" | "wecom" | "slack" | "discord" | "webhook" => {
          check_web_scheme(endpoint.url, endpoint_ctx)
          if endpoint.mail_to is Some(_) {
            raise ConfigError::InvalidField(
              "\{endpoint_ctx}.to is not used by this platform",
            )
          }
        }
        _ =>
          raise ConfigError::InvalidField(
            "\{endpoint_ctx}.platform has unknown value \{endpoint.platform}",
          )
      }
    }
  }
}
