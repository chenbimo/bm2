///|
/// `[notify]` 的校验。每条失败都点名具体字段与目标序号，且错误文本里永不出现
/// url 与凭据——它们是凭据本身的一半。

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
fn check_web_scheme(url : String, ctx : String) -> Unit raise ConfigError {
  if !url.has_prefix("http://") && !url.has_prefix("https://") {
    raise ConfigError::InvalidField(
      "\{ctx}.url must start with http:// or https://",
    )
  }
  // 占位符是整体替换,不是拼接:把一条完整地址填进已经带前缀的 url,展开结果就是
  // 首尾相连的两段地址。它在协议这一关看不出来——这种值照样以 https:// 开头——
  // 所以数一数 `://` 出现了几次。错误里不回显地址,它是凭据的一半。
  if url.split("://").collect().length() > 2 {
    raise ConfigError::InvalidField(
      "\{ctx}.url contains more than one ://, a placeholder was probably expanded into a full url",
    )
  }
}

///|
pub fn validate_notify(config : NotifyConfig) -> Unit raise ConfigError {
  check_int_range(config.timeout_ms, 100, 60000, "notify.timeout_ms")
  check_int_range(config.dedupe_window_s, 0, 604800, "notify.dedupe_window_s")
  check_int_range(config.max_per_minute, 0, 6000, "notify.max_per_minute")
  check_int_range(config.queue_size, 1, 4096, "notify.queue_size")
  check_int_range(config.daily_report_hour, 1, 23, "notify.daily_report_hour")
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
    "notify.threshold_offline_min",
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
  // The mail channel must exist before any email target can use it.
  match config.mail_url {
    Some(url) =>
      if !url.has_prefix("smtp://") && !url.has_prefix("smtps://") {
        raise ConfigError::InvalidField(
          "notify.mail_url must start with smtp:// or smtps://",
        )
      }
    None => ()
  }
  // 开关打开却没有任何目标，等于配了却没处发——这是最常见的"以为配好了"。
  if config.enabled && config.targets.length() == 0 {
    raise ConfigError::InvalidField(
      "notify.enabled is true but there is no [[notify.target]]",
    )
  }
  for index, target in config.targets {
    let ctx = "notify.target[\{index}]"
    match target.platform {
      "email" => validate_email_target(config, target, ctx)
      "feishu" | "dingtalk" | "wecom" | "slack" | "discord" | "webhook" =>
        validate_web_target(target, ctx)
      _ =>
        raise ConfigError::InvalidField(
          "\{ctx}.platform has unknown value \{target.platform}",
        )
    }
  }
}

///|
/// 邮件目标的发送通道在 `[notify]` 上（一份），目标自己只带收件人。
fn validate_email_target(
  config : NotifyConfig,
  target : NotifyTarget,
  ctx : String,
) -> Unit raise ConfigError {
  match target.mail_to {
    Some(recipients) =>
      if recipients.length() == 0 {
        raise ConfigError::InvalidField("\{ctx}.to must not be empty")
      }
    None => raise ConfigError::InvalidField("\{ctx}.to is required for email")
  }
  match config.mail_url {
    Some(_) => ()
    None =>
      raise ConfigError::InvalidField(
        "\{ctx} uses the email platform but notify has no mail_url",
      )
  }
  // An empty From is the first thing a relay refuses, and that is not the kind
  // of failure to discover when an incident needs reporting.
  let has_from = match config.mail_from {
    Some(from) => !from.is_empty()
    None => false
  }
  if !has_from {
    raise ConfigError::InvalidField(
      "\{ctx} uses the email platform but notify.mail_from is missing",
    )
  }
}

///|
fn validate_web_target(
  target : NotifyTarget,
  ctx : String,
) -> Unit raise ConfigError {
  check_web_scheme(target.url, ctx)
  if target.mail_to is Some(_) {
    raise ConfigError::InvalidField("\{ctx}.to is not used by this platform")
  }
}
