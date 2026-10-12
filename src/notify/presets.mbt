///|
/// Platform presets: every difference between the supported notification
/// platforms lives in the `match` below, and each arm describes only the
/// payload shape, where the credential goes and how the request is signed.
/// Adding a platform means adding one arm plus one row in the README table —
/// nothing else in the library knows that platforms exist.

///|
fn default_format(preset : String) -> String {
  match preset {
    "slack" | "discord" | "feishu" | "dingtalk" | "wecom" => "markdown"
    _ => "text"
  }
}

///|
/// Render one message for one target: endpoint (any signature already folded
/// in), headers, body, and — for email — the whole RFC5322 message the
/// transport uploads.
fn render_delivery(
  target : Target,
  msg : Message,
  ctx : Context,
) -> Delivery raise NotifyError {
  let format = target.format.unwrap_or(default_format(target.preset))
  match target.preset {
    "feishu" => render_feishu(target, msg, ctx, format)
    "dingtalk" => render_dingtalk(target, msg, ctx, format)
    "wecom" => render_wecom(target, msg, ctx, format)
    "slack" => render_slack(target, msg, ctx, format)
    "discord" => render_discord(target, msg, ctx, format)
    "webhook" => render_generic(target, msg, ctx, format)
    "email" => render_email(target, msg, ctx, format)
    _ => raise NotifyError::InvalidPreset(target.preset)
  }
}

///|
fn json_delivery(
  url : String,
  body : String,
  headers : Array[(String, String)],
) -> Delivery {
  {
    url,
    http_method: "POST",
    content_type: Some("application/json; charset=utf-8"),
    headers,
    body,
    mail: None,
  }
}

///|
fn render_feishu(
  target : Target,
  msg : Message,
  ctx : Context,
  format : String,
) -> Delivery {
  let fields : Array[(String, String)] = []
  if format == "markdown" || format == "card" {
    fields.push(("msg_type", @fndash.jstr("interactive")))
    fields.push(
      (
        "card",
        @fndash.jobj([
          (
            "elements",
            @fndash.jarr([
              @fndash.jobj([
                ("tag", @fndash.jstr("div")),
                (
                  "text",
                  @fndash.jobj([
                    ("tag", @fndash.jstr("lark_md")),
                    ("content", @fndash.jstr(markdown_body(msg, ctx))),
                  ]),
                ),
              ]),
            ]),
          ),
        ]),
      ),
    )
  } else {
    fields.push(("msg_type", @fndash.jstr("text")))
    fields.push(
      ("content", @fndash.jobj([("text", @fndash.jstr(plain_body(msg, ctx)))])),
    )
  }
  match target.secret {
    Some(secret) =>
      if !secret.is_empty() {
        let seconds = msg.ts_ms / 1000UL
        fields.push(("timestamp", @fndash.jstr(seconds.to_string())))
        fields.push(("sign", @fndash.jstr(feishu_signature(secret, seconds))))
      }
    None => ()
  }
  json_delivery(target.url, @fndash.jobj(fields), [])
}

///|
fn render_dingtalk(
  target : Target,
  msg : Message,
  ctx : Context,
  format : String,
) -> Delivery {
  let body = if format == "markdown" || format == "card" {
    @fndash.jobj([
      ("msgtype", @fndash.jstr("markdown")),
      (
        "markdown",
        @fndash.jobj([
          ("title", @fndash.jstr(msg.title)),
          ("text", @fndash.jstr(markdown_body(msg, ctx))),
        ]),
      ),
    ])
  } else {
    @fndash.jobj([
      ("msgtype", @fndash.jstr("text")),
      ("text", @fndash.jobj([("content", @fndash.jstr(plain_body(msg, ctx)))])),
    ])
  }
  let mut url = target.url
  match target.secret {
    Some(secret) =>
      if !secret.is_empty() {
        url = url +
          (if url.contains("?") { "&" } else { "?" }) +
          "timestamp=" +
          msg.ts_ms.to_string() +
          "&sign=" +
          dingtalk_signature(secret, msg.ts_ms)
      }
    None => ()
  }
  json_delivery(url, body, [])
}

///|
fn render_wecom(
  target : Target,
  msg : Message,
  ctx : Context,
  format : String,
) -> Delivery {
  let body = if format == "markdown" || format == "card" {
    @fndash.jobj([
      ("msgtype", @fndash.jstr("markdown")),
      (
        "markdown",
        @fndash.jobj([("content", @fndash.jstr(markdown_body(msg, ctx)))]),
      ),
    ])
  } else {
    @fndash.jobj([
      ("msgtype", @fndash.jstr("text")),
      ("text", @fndash.jobj([("content", @fndash.jstr(plain_body(msg, ctx)))])),
    ])
  }
  json_delivery(target.url, body, [])
}

///|
fn render_slack(
  target : Target,
  msg : Message,
  ctx : Context,
  format : String,
) -> Delivery {
  let body = if format == "card" || format == "markdown" {
    @fndash.jobj([
      ("text", @fndash.jstr(msg.title)),
      (
        "blocks",
        @fndash.jarr([
          @fndash.jobj([
            ("type", @fndash.jstr("section")),
            (
              "text",
              @fndash.jobj([
                ("type", @fndash.jstr("mrkdwn")),
                ("text", @fndash.jstr(markdown_body(msg, ctx))),
              ]),
            ),
          ]),
        ]),
      ),
    ])
  } else {
    @fndash.jobj([("text", @fndash.jstr(markdown_body(msg, ctx)))])
  }
  json_delivery(target.url, body, [])
}

///|
fn render_discord(
  target : Target,
  msg : Message,
  ctx : Context,
  format : String,
) -> Delivery {
  let body = if format == "card" || format == "markdown" {
    @fndash.jobj([
      ("content", @fndash.jstr(msg.title)),
      (
        "embeds",
        @fndash.jarr([
          @fndash.jobj([
            ("title", @fndash.jstr(msg.title)),
            ("description", @fndash.jstr(markdown_body(msg, ctx))),
          ]),
        ]),
      ),
    ])
  } else {
    @fndash.jobj([("content", @fndash.jstr(markdown_body(msg, ctx)))])
  }
  json_delivery(target.url, body, [])
}

///|
/// The generic preset: one stable, documented JSON shape for everything the host application
/// does not ship a preset for (self-hosted gateways, other webhook platforms).
fn render_generic(
  target : Target,
  msg : Message,
  ctx : Context,
  format : String,
) -> Delivery {
  ignore(format)
  let body = @fndash.jobj([
    ("event", @fndash.jstr(msg.event)),
    ("level", @fndash.jstr(msg.level)),
    ("title", @fndash.jstr(msg.title)),
    ("body", @fndash.jstr(msg.body)),
    ("host", @fndash.jstr(ctx.host)),
    ("timestamp", @fndash.jstr(msg.ts_ms.to_string())),
    ("fields", @fndash.jobj(json_pairs(msg.fields))),
  ])
  let headers = []
  match target.secret {
    Some(secret) =>
      if !secret.is_empty() {
        headers.push(("Authorization", "Bearer " + secret))
      }
    None => ()
  }
  json_delivery(target.url, body, headers)
}

///|
fn json_pairs(fields : Array[(String, String)]) -> Array[(String, String)] {
  fields.map(fn(pair) {
    let (key, value) = pair
    (key, @fndash.jstr(value))
  })
}

///|
/// Email is the one preset whose transport is SMTP, so it renders a whole
/// message (headers plus UTF-8 body) for the transport to send.
fn render_email(
  target : Target,
  msg : Message,
  ctx : Context,
  format : String,
) -> Delivery {
  ignore(format)
  let buf = StringBuilder()
  buf.write_string("From: " + target.from.unwrap_or("") + "\n")
  buf.write_string("To: " + target.to.unwrap_or([]).join(", ") + "\n")
  buf.write_string(
    "Subject: =?UTF-8?B?" + @base64.encode(@utf8.encode(msg.title)[:]) + "?=\n",
  )
  buf.write_string("Date: " + @dateku.rfc5322(msg.ts_ms) + "\n")
  buf.write_string("MIME-Version: 1.0\n")
  buf.write_string("Content-Type: text/plain; charset=UTF-8\n")
  buf.write_string("Content-Transfer-Encoding: 8bit\n")
  buf.write_string("X-Host: " + ctx.host + "\n")
  buf.write_string("\n")
  buf.write_string(markdown_body(msg, ctx))
  buf.write_string("\n")
  {
    url: target.url,
    http_method: "POST",
    content_type: None,
    headers: [],
    body: "",
    mail: Some(buf.to_string()),
  }
}
