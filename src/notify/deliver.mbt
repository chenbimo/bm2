///|
/// Delivery entry points: render one message for one target and push it over
/// the network. None means the endpoint accepted it; Some carries a
/// credential-free reason.

///|
/// Deliver one message to many targets, one request each, sequentially.
/// Returns `(target name, failure)` pairs in input order.
pub async fn deliver_all(
  targets : Array[Target],
  msg : Message,
  timeout_ms : Int32,
  ctx : Context,
) -> Array[(String, String?)] {
  let results = []
  for target in targets {
    results.push((target.name, deliver(target, msg, timeout_ms, ctx)))
  }
  results
}

///|
/// Deliver one message to one target.
pub async fn deliver(
  target : Target,
  msg : Message,
  timeout_ms : Int32,
  ctx : Context,
) -> String? {
  let delivery = try render_delivery(target, msg, ctx) catch {
    e => return Some(e.to_string())
  } noraise {
    rendered => rendered
  }
  transport(target, delivery, timeout_ms, ctx)
}

///|
/// Ceiling on a response body we are willing to parse: 1 MiB. The chat platforms
/// answer with a few hundred bytes, so a body past this is a broken or
/// misconfigured endpoint rather than a delivery result worth interpreting — and
/// parsing it as JSON is the expensive part, which is what this actually stops.
pub const MAX_RESPONSE_BYTES : Int32 = 1048576

///|
/// 飞书、钉钉、企业微信都是"HTTP 200 + 响应体错误码":只看状态码会把 token
/// 错误当成投递成功。应答形状对不上(空 body、纯文本)一律视为成功,避免把
/// 不认识的结构误报为失败。
fn body_failure(preset : String, body : String) -> String? {
  let code_key = match preset {
    "feishu" => "code"
    "dingtalk" | "wecom" => "errcode"
    _ => return None
  }
  let parsed = try @json.parse(body) catch {
    _ => return None
  } noraise {
    value => value
  }
  guard parsed is Object(fields) else { return None }
  let code = match fields.get(code_key) {
    Some(Number(value, ..)) => value.to_int()
    _ => return None
  }
  if code == 0 {
    return None
  }
  let mut reason = preset + " code " + code.to_string()
  match fields.get("msg") {
    Some(String(text)) if text != "" => reason = reason + ": " + text
    _ => ()
  }
  match fields.get("errmsg") {
    Some(String(text)) if text != "" => reason = reason + ": " + text
    _ => ()
  }
  Some(reason)
}

///|
/// Route one rendered request: JSON presets over HTTP, email over SMTP.
async fn transport(
  target : Target,
  delivery : Delivery,
  timeout_ms : Int32,
  ctx : Context,
) -> String? {
  match delivery.mail {
    Some(mail) => smtp_deliver(target, delivery, mail, ctx.host, timeout_ms)
    None => http_deliver(target, delivery, timeout_ms)
  }
}

///|
/// HTTP presets: one request, whole-call timeout. Non-2xx is a failure; for
/// feishu/dingtalk/wecom the response body is inspected too, because they
/// report credential errors as "200 + errcode".
async fn http_deliver(
  target : Target,
  delivery : Delivery,
  timeout_ms : Int32,
) -> String? {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  match delivery.content_type {
    Some(content_type) =>
      headers[@http.CaseInsensitiveString("Content-Type")] = content_type
    None => ()
  }
  for pair in delivery.headers {
    let (key, value) = pair
    headers[@http.CaseInsensitiveString(key)] = value
  }
  let exchange = async fn() {
    match delivery.http_method {
      "GET" => @http.get(delivery.url, headers~)
      "PUT" => @http.put(delivery.url, delivery.body, headers~)
      _ => @http.post(delivery.url, delivery.body, headers~)
    }
  }
  let answer = try @async.with_timeout_opt(timeout_ms, exchange) catch {
    e => return Some(e.to_string())
  } noraise {
    answer => answer
  }
  match answer {
    None => Some("did not finish within " + timeout_ms.to_string() + "ms")
    Some((resp, body)) => {
      if resp.code < 200 || resp.code >= 300 {
        return Some("HTTP " + resp.code.to_string() + " " + resp.reason)
      }
      let raw = body.binary()
      if raw.length() > MAX_RESPONSE_BYTES {
        return Some(
          "response body too large: " + raw.length().to_string() + " bytes",
        )
      }
      body_failure(target.preset, @utf8.decode_lossy(raw))
    }
  }
}
