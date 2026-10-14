///|
/// 解析成功时的便捷包装。
fn parse_ok(text : String) -> Map[String, String] raise {
  @config.parse_env_file(text, "/srv/app/.env")
}

///|
/// 解析失败时取错误文本。断言"点名了哪个文件与哪一行",必须拿到消息本身。
fn env_error(text : String) -> String raise {
  try ignore(@config.parse_env_file(text, "/srv/app/.env")) catch {
    e => e.to_string()
  } noraise {
    _ => fail("expected parse to fail")
  }
}

///|
test "env file: keys, blank lines and full-line comments" {
  let parsed = parse_ok("# 顶部\n\nA=1\n\n  # 中间的注释\nB=2\n")
  assert_eq(parsed.get("A"), Some("1"))
  assert_eq(parsed.get("B"), Some("2"))
  assert_eq(parsed.get("C"), None)
}

///|
test "env file: export prefix is allowed" {
  let parsed = parse_ok("export A=1\nexport\tB=2\n")
  assert_eq(parsed.get("A"), Some("1"))
  assert_eq(parsed.get("B"), Some("2"))
}

///|
test "env file: exportFOO is a key, not a prefix" {
  let parsed = parse_ok("exportFOO=1\n")
  assert_eq(parsed.get("exportFOO"), Some("1"))
  assert_eq(parsed.get("FOO"), None)
}

///|
test "env file: surrounding whitespace is trimmed" {
  let parsed = parse_ok("  A  =  1  \n")
  assert_eq(parsed.get("A"), Some("1"))
}

///|
test "env file: single quotes are literal" {
  let parsed = parse_ok("A='a\\nb'\n")
  assert_eq(parsed.get("A"), Some("a\\nb"))
}

///|
test "env file: double quotes process escapes" {
  let parsed = parse_ok("A=\"a\\nb\\tc\"\n")
  assert_eq(parsed.get("A"), Some("a\nb\tc"))
}

///|
test "env file: quoted value keeps inline hash" {
  let parsed = parse_ok("A=\"a # b\"\n")
  assert_eq(parsed.get("A"), Some("a # b"))
}

///|
test "env file: inline comment needs a leading space" {
  let parsed = parse_ok("A=1 # 注释\nB=a#b\n")
  assert_eq(parsed.get("A"), Some("1"))
  assert_eq(parsed.get("B"), Some("a#b"))
}

///|
test "env file: empty value" {
  let parsed = parse_ok("A=\nB=\"\"\n")
  assert_eq(parsed.get("A"), Some(""))
  assert_eq(parsed.get("B"), Some(""))
}

///|
test "env file: duplicate key keeps the last value" {
  let parsed = parse_ok("A=1\nA=2\n")
  assert_eq(parsed.get("A"), Some("2"))
}

///|
test "env file: quoted value may span lines" {
  let parsed = parse_ok("A=\"line1\nline2\"\nB=2\n")
  assert_eq(parsed.get("A"), Some("line1\nline2"))
  assert_eq(parsed.get("B"), Some("2"))
}

///|
test "env file: CRLF input" {
  let parsed = parse_ok("A=1\r\nB=2\r\n")
  assert_eq(parsed.get("A"), Some("1"))
  assert_eq(parsed.get("B"), Some("2"))
}

///|
test "env file: missing equals names the line" {
  let message = env_error("A=1\nB 2\n")
  assert_true(message.contains("/srv/app/.env line 2"))
  assert_true(message.contains("expected '='"))
}

///|
test "env file: invalid variable name names the line" {
  let message = env_error("A=1\n2B=2\n")
  assert_true(message.contains("line 2"))
  assert_true(message.contains("invalid variable name"))
}

///|
test "env file: unterminated quote names the opening line" {
  let message = env_error("A=1\nB=\"oops\nC=3\n")
  assert_true(message.contains("line 2"))
  assert_true(message.contains("unterminated quote"))
}

///|
test "env file: text after a quoted value is rejected" {
  let message = env_error("A=\"x\" y\n")
  assert_true(message.contains("line 1"))
  assert_true(message.contains("unexpected text"))
}
