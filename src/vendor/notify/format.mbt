///|
/// Request signing and the two body layouts every message is rendered from.
/// String/JSON/encoding helpers live in chensuiyi/fndash, time formatting
/// in chensuiyi/dateku.

///|
/// HMAC-SHA256, base64-encoded: the shared half of the two Chinese chat
/// platforms' request signing.
fn hmac_sha256_base64(key : String, message : String) -> String {
  let mac = @crypto.hmac(
    @crypto.SHA256::new(),
    @utf8.encode(key)[:],
    @utf8.encode(message)[:],
  )
  @base64.encode(mac.unsafe_reinterpret_as_bytes())
}

///|
/// DingTalk signs `timestamp + "\n" + secret` with the secret as the key, and
/// carries the timestamp in milliseconds.
fn dingtalk_signature(secret : String, timestamp_ms : UInt64) -> String {
  @fndash.url_encode(
    hmac_sha256_base64(secret, timestamp_ms.to_string() + "\n" + secret),
  )
}

///|
/// Feishu signs the *empty* message with `timestamp + "\n" + secret` as the key
/// (the inverse of DingTalk) and carries the timestamp in seconds.
fn feishu_signature(secret : String, timestamp_s : UInt64) -> String {
  hmac_sha256_base64(timestamp_s.to_string() + "\n" + secret, "")
}

///|
fn field_lines(msg : Message, bullet : String) -> String {
  let buf = StringBuilder()
  for pair in msg.fields {
    let (key, value) = pair
    buf.write_string("\n" + bullet + key + ": " + value)
  }
  buf.to_string()
}

///|
fn plain_body(msg : Message, ctx : Context) -> String {
  msg.title +
  "\n" +
  msg.body +
  field_lines(msg, "") +
  "\n\n--\n" +
  ctx.product +
  " @ " +
  ctx.host
}

///|
fn markdown_body(msg : Message, ctx : Context) -> String {
  "**" +
  msg.title +
  "**\n\n" +
  msg.body +
  field_lines(msg, "- ") +
  "\n\n> " +
  ctx.product +
  " @ " +
  ctx.host
}
