///|
/// Control-channel failures. `AuthFailed` closes the connection without a
/// response, so a wrong token looks to its presenter like a closed port.
pub suberror IpcError {
  Timeout
  AuthFailed
  Closed(String)
  TooLarge(size~ : Int32, limit~ : Int32)
} derive(Debug)

///|
pub extend IpcError with @debug.Debug::{to_repr}

///|
/// Hard ceiling for one control message. The receiver allocates exactly the
/// announced length, so this is not a limit on how many instances may be
/// listed — it only stops a hostile peer from forcing an absurd allocation.
pub const MAX_MSG_BYTES : Int32 = 4 * 1024 * 1024

///|
/// How long either side waits for the auth handshake (and the daemon for a
/// silent client) before dropping the connection.
pub const AUTH_TIMEOUT_MS : Int32 = 5000

///|
/// Files under the state dir that publish the daemon's contact point.
pub const PORT_FILE : String = "daemon.port"

///|
pub const TOKEN_FILE : String = "daemon.token"

///|
/// 4-byte big-endian length header + payload, over the connection.
pub async fn write_frame(conn : @socket.Tcp, payload : Bytes) -> Unit {
  let len = payload.length()
  if len > MAX_MSG_BYTES {
    raise TooLarge(size=len, limit=MAX_MSG_BYTES)
  }
  let head = Bytes::makei(4, fn(i) { ((len >> ((3 - i) * 8)) & 0xFF).to_byte() })
  conn.write(head)
  conn.write(payload)
}

///|
/// Read one framed message: size the buffer to the announced length, then
/// read the body. Sizing to the payload keeps the accept side free of an
/// arbitrary message-size ceiling.
async fn read_frame(conn : @socket.Tcp) -> Bytes {
  let head = conn.read_exactly(4)
  let len = (head[0].to_int() << 24) |
    (head[1].to_int() << 16) |
    (head[2].to_int() << 8) |
    head[3].to_int()
  if len > MAX_MSG_BYTES {
    raise TooLarge(size=len, limit=MAX_MSG_BYTES)
  }
  conn.read_exactly(len)
}

///|
/// Length-safe equality for token comparison: the loop always consumes the
/// full input, so timing does not reveal a matching prefix.
fn constant_time_eq(a : String, b : String) -> Bool {
  let ab = @utf8.encode(a)
  let bb = @utf8.encode(b)
  let mut diff = ab.length() ^ bb.length()
  let n = if ab.length() < bb.length() { ab.length() } else { bb.length() }
  for i in 0..<n {
    diff = diff ^ (ab[i].to_int() ^ bb[i].to_int())
  }
  diff == 0
}

///|
/// 256 bits from the kernel RNG, hex-encoded: 64 characters, no ambiguity
/// on the wire or in a file.
pub fn generate_token() -> String raise {
  hex_encode(@fsx.read_small("/dev/urandom", cap=32))
}

///|
pub fn hex_encode(bytes : Bytes) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for i in 0..<bytes.length() {
    let b = bytes[i].to_int()
    out.write_string(digits[b >> 4:(b >> 4) + 1].to_owned())
    out.write_string(digits[b & 15:(b & 15) + 1].to_owned())
  }
  out.to_string()
}

///|
/// Read the port file the daemon wrote after binding. None when there is
/// nothing readable (no daemon, or a stale file from a dead one).
pub fn read_daemon_port(state_dir : String) -> Int32? {
  try {
    let text = @utf8.decode(
      @fsx.read_small(state_dir + "/" + PORT_FILE, cap=32),
    )
    parse_port(text)
  } catch {
    _ => None
  } noraise {
    port => port
  }
}

///|
fn parse_port(text : String) -> Int32? {
  let trimmed = trim_ascii(text)
  if trimmed.is_empty() {
    return None
  }
  let mut value = 0
  for i in 0..<trimmed.length() {
    let ch = trimmed[i].to_int()
    if ch < 0x30 || ch > 0x39 {
      return None
    }
    value = value * 10 + (ch - 0x30)
  }
  if value <= 0 || value > 65535 {
    return None
  }
  Some(value)
}

///|
fn trim_ascii(text : String) -> String {
  let mut start = 0
  let end = text.length()
  while start < end {
    let ch = text[start].to_int()
    if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D {
      start += 1
    } else {
      break
    }
  }
  let mut stop = end
  while stop > start {
    let ch = text[stop - 1].to_int()
    if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D {
      stop -= 1
    } else {
      break
    }
  }
  if start == 0 && stop == end {
    text
  } else if start >= stop {
    ""
  } else {
    text[start:stop].to_owned()
  }
}

///|
/// Read the shared token. None when missing/unreadable — callers report
/// "no daemon" rather than leaking the reason.
pub fn read_token(state_dir : String) -> String? {
  try {
    let text = @utf8.decode(
      @fsx.read_small(state_dir + "/" + TOKEN_FILE, cap=128),
    )
    let trimmed = trim_ascii(text)
    if trimmed.is_empty() {
      None
    } else {
      Some(trimmed)
    }
  } catch {
    _ => None
  } noraise {
    token => token
  }
}

///|
/// Dial the daemon over loopback TCP using the recorded port. Raises
/// Closed when there is no readable port file (no daemon, or a stale one).
pub async fn dial(state_dir : String) -> @socket.Tcp {
  match read_daemon_port(state_dir) {
    Some(port) => @socket.Tcp::connect_to_host("127.0.0.1", port~)
    None => raise Closed("no daemon port file")
  }
}

///|
/// One authenticated round trip on a fresh connection, over raw bytes:
/// the token frame goes first, the server answers with a single ack byte
/// before the payload frame is accepted (a rejected token therefore
/// surfaces as EOF — AuthFailed — rather than a protocol error), then the
/// payload frame is written and the response frame read. The whole
/// exchange is bounded by `timeout_ms`; silence raises Timeout.
pub async fn round_trip_bytes(
  conn : @socket.Tcp,
  token : String,
  payload : Bytes,
  timeout_ms : Int32,
) -> Bytes {
  let exchange = async fn() {
    write_frame(conn, @utf8.encode(token))
    try ignore(conn.read_exactly(1)) catch {
      _ => raise AuthFailed
    } noraise {
      _ => ()
    }
    write_frame(conn, payload)
    read_frame(conn)
  }
  match @async.with_timeout_opt(timeout_ms, exchange) {
    Some(response) => response
    None => raise Timeout
  }
}

///|
/// Accept one connection and authenticate it. Returns the open connection
/// when the peer presented the right token (the ack byte is already sent),
/// None for wrong token / silence / garbage — those connections are closed
/// here without ever reaching the dispatcher. Cancellation propagates so a
/// shutting-down daemon stops accepting.
pub async fn accept_authed(
  server : @socket.TcpServer,
  token : String,
) -> @socket.Tcp? {
  let (conn, _peer) = server.accept()
  let ok = try {
    let exchange = async fn() {
      let presented = @utf8.decode(read_frame(conn))
      write_ack(conn, constant_time_eq(presented, token))
    }
    match @async.with_timeout_opt(AUTH_TIMEOUT_MS, exchange) {
      Some(_) => true
      None => false
    }
  } catch {
    _ => false
  } noraise {
    accepted => accepted
  }
  if !ok {
    conn.close()
    return None
  }
  Some(conn)
}

///|
async fn write_ack(conn : @socket.Tcp, accept : Bool) -> Unit {
  if accept {
    conn.write(b"y")
  } else {
    // Any byte works: the client only needs "the server hung up right
    // after auth" versus "no answer at all" to tell a wrong token from a
    // dead daemon. Closing without the ack is the rejection signal.
    conn.close()
    raise AuthFailed
  }
}

///|
/// Read one framed message from an authenticated connection, tolerating a
/// client that connects and goes silent: None means the connection yielded
/// nothing usable and has been closed.
pub async fn read_frame_timeout(
  conn : @socket.Tcp,
  timeout_ms : Int32,
) -> Bytes? {
  let exchange = async fn() { read_frame(conn) }
  let received = try @async.with_timeout_opt(timeout_ms, exchange) catch {
    _ => None
  } noraise {
    received => received
  }
  match received {
    Some(frame) => Some(frame)
    None => {
      conn.close()
      None
    }
  }
}
