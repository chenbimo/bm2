///|
/// bm2 的控制通道协议适配层:传输(帧协议/令牌/认证/拨号)在
/// chensuiyi/dcipc,这里只做 Request/Response 与字节帧的编解码衔接。

///|
/// Write one framed response to an authenticated connection.
pub async fn write_response(conn : @socket.Tcp, resp : @core.Response) -> Unit {
  write_frame(conn, @core.encode_response(resp))
}

///|
/// One authenticated request/response round trip on a fresh connection.
/// The server answers the token frame with a single byte before accepting
/// the request frame, so a rejected token surfaces as EOF (AuthFailed)
/// rather than a confusing protocol error.
pub async fn round_trip(
  conn : @socket.Tcp,
  token : String,
  req : @core.Request,
  timeout_ms : Int32,
) -> @core.Response {
  @core.decode_response(
    round_trip_bytes(conn, token, @core.encode_request(req), timeout_ms),
  )
}

///|
/// Read one request frame from an authenticated connection, tolerating a
/// client that connects and goes silent. None means the connection yielded
/// nothing usable and has been closed.
pub async fn read_request(conn : @socket.Tcp) -> @core.Request? {
  match read_frame_timeout(conn, AUTH_TIMEOUT_MS) {
    Some(payload) => Some(@core.decode_request(payload))
    None => None
  }
}
