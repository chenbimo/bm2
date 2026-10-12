///|
/// Tests for rendering, signing, the engine and the credential-free failure
/// contract. Delivery against a live endpoint is exercised by bm2's e2e suite.

///|
fn n_target(
  preset : String,
  url : String,
  secret? : String,
  format? : String,
  from? : String,
  to? : Array[String],
  username? : String,
  password? : String,
) -> Target {
  { name: "t", preset, url, secret, format, from, to, username, password, }
}

///|
fn n_message(level : String, ts_ms : UInt64) -> Message {
  Message::new(
    "crash",
    level,
    "api · 实例异常退出",
    "退出码 1",
    "crash|api|0|exit_code",
    ts_ms,
    fields=[("应用", "api"), ("端口", "3000")],
  )
}

///|
fn n_ctx() -> Context {
  { host: "host1", product: "bm2", }
}

///|
test "request signing matches the platforms' published vectors" {
  // DingTalk: base64(HMAC-SHA256(key = secret, msg = "timestamp\n" + secret)),
  // percent-encoded, timestamp in milliseconds.
  assert_eq(
    dingtalk_signature("SECtest", 1700000000000UL),
    "aZLLrriXgn05YbwaGR7knYsLeJADjr9NwLaNNKpxh4g%3D",
  )
  // Feishu: base64(HMAC-SHA256(key = "timestamp\n" + secret, msg = "")),
  // timestamp in seconds — the inverse key/message arrangement.
  assert_eq(
    feishu_signature("SECtest", 1700000000UL),
    "G7XpBpG8NgG02fJOAhX6FRAObIljmFoxVReo8I62pEk=",
  )
}

///|
test "escaping survives the json layer" {
  assert_eq(@fndash.json_escape("a\"b\\c\nd"), "a\\\"b\\\\c\\nd")
  assert_eq(@fndash.json_escape("\u{1}"), "\\u0001")
  assert_eq(@fndash.jstr("x"), "\"x\"")
  assert_eq(@fndash.url_encode("a b/c?d=e&f"), "a%20b%2Fc%3Fd%3De%26f")
  assert_eq(@fndash.url_encode("中文"), "%E4%B8%AD%E6%96%87")
  assert_eq(@fndash.url_encode("AZaz09-_.~"), "AZaz09-_.~")
}

///|
test "the chinese chat presets carry their signature and shape" {
  let msg = n_message("warn", 1700000000000UL)
  let feishu = render_delivery(
    n_target(
      "feishu",
      "https://open.feishu.cn/open-apis/bot/v2/hook/x",
      secret="SECtest",
    ),
    msg,
    n_ctx(),
  )
  assert_true(feishu.body.contains("\"msg_type\":\"interactive\""))
  assert_true(feishu.body.contains("\"timestamp\":\"1700000000\""))
  assert_true(
    feishu.body.contains("G7XpBpG8NgG02fJOAhX6FRAObIljmFoxVReo8I62pEk="),
  )
  assert_true(feishu.body.contains("lark_md"))

  let dingtalk = render_delivery(
    n_target(
      "dingtalk",
      "https://oapi.dingtalk.com/robot/send?access_token=t",
      secret="SECtest",
    ),
    msg,
    n_ctx(),
  )
  assert_true(dingtalk.url.contains("timestamp=1700000000000"))
  assert_true(
    dingtalk.url.contains("sign=aZLLrriXgn05YbwaGR7knYsLeJADjr9NwLaNNKpxh4g%3D"),
  )
  assert_true(dingtalk.body.contains("\"msgtype\":\"markdown\""))
  // A token already in the query string must be joined with &, not ?.
  assert_true(dingtalk.url.contains("?access_token=t&timestamp="))

  let wecom = render_delivery(
    n_target("wecom", "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k"),
    msg,
    n_ctx(),
  )
  assert_true(wecom.body.contains("\"msgtype\":\"markdown\""))
}

///|
test "the western chat presets use their own payload shape" {
  let msg = n_message("error", 1700000000000UL)
  let slack = render_delivery(
    n_target("slack", "https://hooks.slack.com/x"),
    msg,
    n_ctx(),
  )
  assert_true(slack.body.contains("\"blocks\""))
  assert_true(slack.body.contains("\"mrkdwn\""))

  let discord = render_delivery(
    n_target("discord", "https://discord.com/api/webhooks/x"),
    msg,
    n_ctx(),
  )
  assert_true(discord.body.contains("\"embeds\""))
  assert_true(discord.body.contains("\"description\""))
}

///|
test "the generic preset and email carry a stable documented shape" {
  let msg = n_message("warn", 1700000000000UL)
  let generic = render_delivery(
    n_target("webhook", "https://gateway.example/hook", secret="tk"),
    msg,
    n_ctx(),
  )
  assert_true(generic.body.contains("\"event\":\"crash\""))
  assert_true(generic.body.contains("\"level\":\"warn\""))
  assert_true(generic.body.contains("\"host\":\"host1\""))
  assert_true(
    generic.body.contains("\"fields\":{\"应用\":\"api\",\"端口\":\"3000\"}"),
  )
  assert_true(generic.headers.contains(("Authorization", "Bearer tk")))

  let email = render_delivery(
    n_target(
      "email",
      "smtps://smtp.example:465",
      from="bm2@example.com",
      to=["ops@example.com", "oncall@example.com"],
      username="bm2@example.com",
      password="pw",
    ),
    msg,
    n_ctx(),
  )
  let mail = email.mail.unwrap()
  assert_true(mail.contains("From: bm2@example.com"))
  assert_true(mail.contains("To: ops@example.com, oncall@example.com"))
  // The subject is RFC2047 encoded so non-ASCII titles survive SMTP.
  assert_true(mail.contains("Subject: =?UTF-8?B?"))
  assert_true(mail.contains("Date: Tue, 14 Nov 2023 22:13:20 +0000"))
  assert_true(mail.contains("\n\n**api · 实例异常退出**"))
}

///|
test "chinese chat platforms are judged by their body code, not just http" {
  // 成功应答:错误码为 0。
  assert_true(
    body_failure("feishu", "{\"code\":0,\"msg\":\"success\"}") is None,
  )
  assert_true(
    body_failure("dingtalk", "{\"errcode\":0,\"errmsg\":\"ok\"}") is None,
  )
  // 凭据错误:HTTP 200 + 非零错误码,必须判为失败并携带平台信息。
  let bad = body_failure("feishu", "{\"code\":19021,\"msg\":\"sign error\"}")
  assert_true(bad is Some(_))
  let reason = bad.unwrap()
  assert_true(reason.contains("feishu"))
  assert_true(reason.contains("19021"))
  // 不认识的应答形状:宁可放行,不误报。
  assert_true(body_failure("webhook", "plain text body") is None)
}

///|
async test "a failed delivery reports a reason without the credential" {
  let target = n_target(
    "webhook",
    "http://127.0.0.1:9/hook?token=SECRET",
    secret="TOPSECRET",
  )
  let reason = match deliver(target, n_message("warn", 1000UL), 300, n_ctx()) {
    Some(reason) => reason
    None => fail("expected the unreachable target to fail")
  }
  assert_false(reason.is_empty())
  // Neither the URL, its token, nor the header credential may leak into a
  // reason that the host application prints.
  assert_false(reason.contains("SECRET"))
  assert_false(reason.contains("127.0.0.1"))
  assert_false(reason.contains("TOPSECRET"))
}

///|
async test "the engine dedupes, rate limits and enforces the queue limit" {
  let dead = [n_target("webhook", "http://127.0.0.1:9/hook")]
  let engine = Engine::new(n_ctx())
  // Same key inside the dedupe window: first emit queues, the rest counted.
  assert_eq(
    engine.emit(
      1000UL,
      "k1",
      "app",
      n_message("warn", 1000UL),
      dead,
      300,
      dedupe_window_s=3600,
    ),
    Queued,
  )
  assert_eq(
    engine.emit(
      2000UL,
      "k1",
      "app",
      n_message("warn", 2000UL),
      dead,
      300,
      dedupe_window_s=3600,
    ),
    Deduped(count=2),
  )
  // A different key is a different event.
  assert_eq(
    engine.emit(
      3000UL,
      "k2",
      "app",
      n_message("warn", 3000UL),
      dead,
      300,
      dedupe_window_s=3600,
    ),
    Queued,
  )
  assert_eq(engine.queued(), 2)
  assert_eq(engine.dropped(), 0)
  // Rate limit: a fresh window with a 1/minute cap drops the second emit.
  let throttled = Engine::new(n_ctx())
  assert_eq(
    throttled.emit(
      1000UL,
      "a",
      "app",
      n_message("warn", 1000UL),
      dead,
      300,
      rate_per_minute=1,
    ),
    Queued,
  )
  assert_eq(
    throttled.emit(
      2000UL,
      "b",
      "app",
      n_message("warn", 2000UL),
      dead,
      300,
      rate_per_minute=1,
    ),
    RateLimited,
  )
  assert_eq(throttled.dropped(), 1)
  // Queue limit: a third message for the same owner has no room.
  let capped = Engine::new(n_ctx())
  assert_eq(
    capped.emit(
      1000UL,
      "a",
      "app",
      n_message("warn", 1000UL),
      dead,
      300,
      queue_limit=2,
    ),
    Queued,
  )
  assert_eq(
    capped.emit(
      1000UL,
      "b",
      "app",
      n_message("warn", 1000UL),
      dead,
      300,
      queue_limit=2,
    ),
    Queued,
  )
  assert_eq(
    capped.emit(
      1000UL,
      "c",
      "app",
      n_message("warn", 1000UL),
      dead,
      300,
      queue_limit=2,
    ),
    QueueFull,
  )
}

///|
async test "pump retries with backoff, then exhausts" {
  let dead = [n_target("webhook", "http://127.0.0.1:9/hook?token=SECRET")]
  let engine = Engine::new(n_ctx())
  assert_eq(
    engine.emit(1000UL, "k", "app", n_message("warn", 1000UL), dead, 300),
    Queued,
  )
  // First pass fails: attempt 1, next try after 5s.
  let first = engine.pump(1000UL)
  assert_eq(first.remaining, 1)
  assert_eq(first.outcome, Failed(attempt=1))
  // Pumping before the backoff expires stays idle.
  assert_eq(engine.pump(2000UL).outcome, Idle)
  // Second pass fails: attempt 2, next try after 15s.
  assert_eq(engine.pump(6000UL).outcome, Failed(attempt=2))
  // Third pass exhausts the budget and drops the head.
  assert_eq(engine.pump(21000UL).outcome, Exhausted)
  assert_eq(engine.queued(), 0)
  assert_eq(engine.pump(22000UL).outcome, Idle)
}
