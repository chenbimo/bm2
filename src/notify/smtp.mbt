///|
/// SMTP-level failures. Messages never contain credentials: they carry the
/// stage and the server's status line, which is what an operator needs.
suberror SmtpFailed {
  SmtpError(String)
} derive(Debug)

///|
pub extend SmtpFailed with @debug.Debug::{to_repr}

///|
/// One connection to the relay, plaintext until STARTTLS wraps it.
priv enum SmtpWire {
  Plain(@socket.Tcp)
  Secure(@tls.Tls)
}

///|
async fn SmtpWire::line(self : SmtpWire) -> String {
  let text = match self {
    Plain(conn) => conn.read_until("\r\n")
    Secure(conn) => conn.read_until("\r\n")
  }
  match text {
    Some(line) => line
    None => raise SmtpError("connection closed by the server")
  }
}

///|
async fn SmtpWire::send(self : SmtpWire, text : String) -> Unit {
  let data = @utf8.encode(text)
  match self {
    Plain(conn) => conn.write(data)
    Secure(conn) => conn.write(data)
  }
}

///|
/// Read one reply (relays answer multiline as "250-...\r\n250 ...\r\n")
/// and verify its status code. `hint` names the step when the code alone would
/// leave an operator guessing — a refused STARTTLS is not a protocol error, it is
/// a relay that cannot do what we require.
async fn SmtpWire::reply(
  self : SmtpWire,
  code : String,
  hint~ : String = "",
) -> Unit {
  let current = self.read_reply()
  if current.length() < 4 || !current.has_prefix(code) {
    raise SmtpError(
      if hint == "" {
        "expected " + code + ", got: " + trim_reply(current)
      } else {
        hint + ": expected " + code + ", got: " + trim_reply(current)
      },
    )
  }
}

///|
/// Like `reply`, but never repeats the server's own text. Used for the one step
/// whose answer could quote the command: a relay that echoes it would put the
/// base64 credentials into the reason we log. The fact that the step failed is
/// all an operator needs.
async fn SmtpWire::reply_code(
  self : SmtpWire,
  code : String,
  hint : String,
) -> Unit {
  let current = self.read_reply()
  if current.length() < 4 || !current.has_prefix(code) {
    raise SmtpError(hint)
  }
}

///|
/// Read one reply's final line, skipping the continuation lines of a multiline
/// reply ("250-..." continues, "250 ..." ends).
async fn SmtpWire::read_reply(self : SmtpWire) -> String {
  let mut current = self.line()
  while current.length() >= 4 && current[3].to_int() == 0x2D {
    current = self.line()
  }
  current
}

///|
fn trim_reply(line : String) -> String {
  let mut stop = line.length()
  while stop > 0 {
    let ch = line[stop - 1].to_int()
    if ch == 0x0D || ch == 0x0A {
      stop -= 1
    } else {
      break
    }
  }
  line[:stop].to_owned()
}

///|
/// Deliver one RFC5322 message over SMTP with STARTTLS (or implicit TLS for
/// smtps://). None on acceptance; Some carries a credential-free reason.
pub async fn smtp_deliver(
  target : Target,
  delivery : Delivery,
  mail : String,
  ehlo_name : String,
  timeout_ms : Int32,
) -> String? {
  let exchange = async fn() { smtp_session(target, delivery, mail, ehlo_name) }
  let answer = try @async.with_timeout_opt(timeout_ms, exchange) catch {
    e =>
      match e {
        SmtpError(reason) => return Some(reason)
        other => return Some(other.to_string())
      }
  } noraise {
    answer => answer
  }
  match answer {
    None => Some("did not finish within " + timeout_ms.to_string() + "ms")
    Some(failure) => failure
  }
}

///|
async fn smtp_session(
  target : Target,
  delivery : Delivery,
  mail : String,
  ehlo_name : String,
) -> String? {
  // smtp://host:port forces STARTTLS before credentials; smtps:// is TLS
  // from the first byte — the same contract curl had.
  let url = delivery.url
  let secure = url.has_prefix("smtps://")
  let prefix_len = if secure { 8 } else { 7 }
  let rest = url[prefix_len:url.length()].to_owned()
  let mut host = rest
  let mut port = if secure { 465 } else { 25 }
  for i, ch in rest {
    if ch == ':' {
      host = rest[:i].to_owned()
      port = match parse_smtp_port(rest[i + 1:].to_owned()) {
        Some(parsed) => parsed
        None => port
      }
      break
    }
    if ch == '/' {
      break
    }
  }
  let conn = @socket.Tcp::connect_to_host(host, port~)
  let mut wire : SmtpWire = if secure {
    Secure(@tls.Tls::client(conn, host~))
  } else {
    Plain(conn)
  }
  wire.reply("220")
  wire.send("EHLO " + ehlo_name + "\r\n")
  wire.reply("250")
  if !secure {
    wire.send("STARTTLS\r\n")
    wire.reply("220", hint="the relay refused STARTTLS")
    wire = Secure(@tls.Tls::client(conn, host~))
    wire.send("EHLO " + ehlo_name + "\r\n")
    wire.reply("250")
  }
  match target.username {
    Some(username) if username != "" => {
      let blob = "\u{0}" + username + "\u{0}" + target.password.unwrap_or("")
      wire.send("AUTH PLAIN " + @base64.encode(@utf8.encode(blob)) + "\r\n")
      wire.reply_code("235", "the relay rejected the AUTH PLAIN credentials")
    }
    _ => ()
  }
  wire.send("MAIL FROM:<" + target.from.unwrap_or("") + ">\r\n")
  wire.reply("250")
  for recipient in target.to.unwrap_or([]) {
    wire.send("RCPT TO:<" + recipient + ">\r\n")
    wire.reply("250")
  }
  wire.send("DATA\r\n")
  wire.reply("354")
  wire.send(dot_stuff(mail) + "\r\n.\r\n")
  wire.reply("250")
  wire.send("QUIT\r\n")
  None
}

///|
fn parse_smtp_port(text : String) -> Int32? {
  if text.is_empty() {
    return None
  }
  let mut value = 0
  for i in 0..<text.length() {
    let ch = text[i].to_int()
    if ch < 0x30 || ch > 0x39 {
      return None
    }
    value = value * 10 + (ch - 0x30)
  }
  if value <= 0 || value > 65535 {
    None
  } else {
    Some(value)
  }
}

///|
/// SMTP transparency: a line starting with a dot gets another dot, lines travel
/// with CRLF endings, and anything past `SMTP_LINE_LIMIT` octets is split —
/// RFC 5321 caps a line at 998 octets and some relays reject the whole message
/// otherwise. Splitting adds a line break and changes no other byte; it counts
/// UTF-8 width rather than characters, so a multi-byte character is never cut in
/// half.
fn dot_stuff(mail : String) -> String {
  let lines = mail.split("\n")
  let out = []
  for line in lines {
    for chunk in fold_line(trim_reply(line.to_owned())) {
      let stuffed = if chunk.has_prefix(".") { "." + chunk } else { chunk }
      out.push(stuffed)
    }
  }
  out.join("\r\n")
}

///|
/// How many octets one transmitted line may hold: the RFC 5321 ceiling.
const SMTP_LINE_LIMIT : Int32 = 998

///|
/// Split one logical line into transmitted lines of at most `SMTP_LINE_LIMIT`
/// octets. Segmentation is by character index, so the cut always lands on a
/// character boundary.
fn fold_line(line : String) -> Array[String] {
  let out = []
  let mut start = 0
  let mut width = 0
  let mut index = 0
  for ch in line {
    let ch_width = utf8_char_width(ch)
    if width + ch_width > SMTP_LINE_LIMIT {
      out.push(line[start:index].to_owned())
      start = index
      width = 0
    }
    width += ch_width
    index += 1
  }
  out.push(line[start:].to_owned())
  out
}

///|
/// UTF-8 width of one character, in octets.
fn utf8_char_width(ch : Char) -> Int32 {
  let code = ch.to_int()
  if code < 0x80 {
    1
  } else if code < 0x800 {
    2
  } else if code < 0x10000 {
    3
  } else {
    4
  }
}
