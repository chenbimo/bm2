///|
const VALID_DOC : String =
  #|name = "blog"
  #|cwd = "/srv/yicode/blog"
  #|script = "index.ts"
  #|instances = 4
  #|port = 3000
  #|

///|
const BASE_DIR : String = "/srv/yicode"

///|
fn parse_error(doc : String) -> String raise {
  try @config.parse(doc, BASE_DIR) catch {
    e => e.to_string()
  } noraise {
    _ => fail("expected parse to fail")
  }
}

///|
test "parses valid bm2.toml" {
  let config = @config.parse(VALID_DOC, BASE_DIR)
  assert_eq(config.name, "blog")
  assert_eq(config.cwd, "/srv/yicode/blog")
  assert_eq(config.script, "index.ts")
  assert_eq(config.instances, 4)
  assert_eq(config.port, 3000)
  assert_eq(config.max_memory_mb, 512)
  assert_eq(config.max_restarts, 10)
  assert_eq(config.restart_delay_ms, 1000)
  assert_eq(config.min_uptime_ms, 10000)
  assert_eq(config.stop_timeout_ms, 10000)
}

///|
test "cwd defaults to the config directory" {
  let config = @config.parse(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|instances = 2
      #|port = 3000
      #|
    ),
    "/srv/yicode/blog",
  )
  assert_eq(config.cwd, "/srv/yicode/blog")
}

///|
test "rejects unknown top-level field" {
  let message = parse_error(
    (
      #|name = "blog"
      #|state_dir = "/tmp/bm2"
      #|script = "index.ts"
      #|instances = 1
      #|port = 3000
      #|
    ),
  )
  assert_true(message.contains("unknown field state_dir"))
}

///|
test "rejects the removed env table" {
  let message = parse_error(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|instances = 1
      #|port = 3000
      #|
      #|[env]
      #|APP_ENV = "production"
      #|
    ),
  )
  assert_true(message.contains("unknown field env"))
}

///|
test "rejects invalid toml document" {
  let message = parse_error("name = [unclosed")
  assert_true(message.contains("InvalidDocument"))
}

///|
test "rejects missing required fields" {
  assert_true(
    parse_error("script = \"x\"\ninstances = 1\nport = 1\n").contains(
      "name is required",
    ),
  )
  assert_true(
    parse_error("name = \"x\"\ninstances = 1\nport = 1\n").contains(
      "script is required",
    ),
  )
  assert_true(
    parse_error("name = \"x\"\nscript = \"s\"\nport = 1\n").contains(
      "instances is required",
    ),
  )
  assert_true(
    parse_error("name = \"x\"\nscript = \"s\"\ninstances = 1\n").contains(
      "port is required",
    ),
  )
}

///|
test "rejects invalid project name" {
  let cases = [
    ("1abc", "invalid name"),
    ("a-b", "invalid name"),
    ("a.b", "invalid name"),
    ("a b", "invalid name"),
    ("a@b", "invalid name"),
    ("", "must not be empty"),
  ]
  for pair in cases {
    let (name, expect) = pair
    let message = parse_error(
      "name = \"\{name}\"\nscript = \"s\"\ninstances = 1\nport = 3000\n",
    )
    assert_true(message.contains(expect))
  }
}

///|
test "allows uppercase letters and underscores in project name" {
  let config = @config.parse(
    (
      #|name = "Blog_API_2"
      #|script = "index.ts"
      #|instances = 1
      #|port = 3000
      #|
    ),
    BASE_DIR,
  )
  assert_eq(config.name, "Blog_API_2")
}

///|
test "rejects non-absolute cwd" {
  let message = parse_error(
    (
      #|name = "blog"
      #|cwd = "srv/blog"
      #|script = "index.ts"
      #|instances = 1
      #|port = 3000
      #|
    ),
  )
  assert_true(message.contains("cwd must be an absolute path"))
}

///|
test "rejects script escaping cwd" {
  let escape = parse_error(
    (
      #|name = "blog"
      #|script = "../evil.ts"
      #|instances = 1
      #|port = 3000
      #|
    ),
  )
  assert_true(escape.contains("must not contain '..' segments"))
  let absolute = parse_error(
    (
      #|name = "blog"
      #|script = "/etc/evil.ts"
      #|instances = 1
      #|port = 3000
      #|
    ),
  )
  assert_true(absolute.contains("must be a relative path"))
}

///|
test "rejects invalid runtime" {
  let message = parse_error(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|runtime = "python"
      #|instances = 1
      #|port = 3000
      #|
    ),
  )
  assert_true(message.contains("runtime must be \"bun\" or \"node\""))
  let ok = @config.parse(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|runtime = "node"
      #|instances = 1
      #|port = 3000
      #|
    ),
    BASE_DIR,
  )
  assert_eq(ok.runtime, "node")
}

///|
test "exec_mode defaults to cluster and accepts only fork or cluster" {
  let config = @config.parse(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|instances = 2
      #|port = 3000
      #|
    ),
    BASE_DIR,
  )
  assert_eq(config.exec_mode, "cluster")
  let fork = @config.parse(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|exec_mode = "fork"
      #|instances = 4
      #|port = 3000
      #|
    ),
    BASE_DIR,
  )
  assert_eq(fork.exec_mode, "fork")
  let message = parse_error(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|exec_mode = "sticky"
      #|instances = 1
      #|port = 3000
      #|
    ),
  )
  assert_true(message.contains("exec_mode must be \"fork\" or \"cluster\""))
}

///|
test "rejects zero or excessive instances" {
  let zero = parse_error(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|instances = 0
      #|port = 3000
      #|
    ),
  )
  assert_true(zero.contains("instances must be between 1 and 1024"))
  let many = parse_error(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|instances = 2000
      #|port = 3000
      #|
    ),
  )
  assert_true(many.contains("instances must be between 1 and 1024"))
}

///|
test "rejects port range overflow" {
  let message = parse_error(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|instances = 2
      #|port = 65535
      #|
    ),
  )
  assert_true(message.contains("is out of 1 ~ 65535"))
}

///|
test "rejects port near int max before the range sum wraps" {
  let message = parse_error(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|instances = 5
      #|port = 2147483647
      #|
    ),
  )
  assert_true(message.contains("port must be within 1 ~ 65535"))
}

///|
test "rejects invalid numeric limits" {
  let cases = [
    ("max_memory_mb = 0", "max_memory_mb must be at least 1"),
    ("max_restarts = -1", "out of range"),
    ("restart_delay_ms = -1", "out of range"),
    ("min_uptime_ms = -1", "out of range"),
    ("stop_timeout_ms = 0", "stop_timeout_ms must be between 1 and 60000"),
    ("stop_timeout_ms = 60001", "stop_timeout_ms must be between 1 and 60000"),
  ]
  for pair in cases {
    let (line, expect) = pair
    let doc = "name = \"blog\"\nscript = \"index.ts\"\ninstances = 1\nport = 3000\n" +
      line +
      "\n"
    assert_true(parse_error(doc).contains(expect))
  }
}

///|
test "load reads and validates a file with cwd default" {
  let dir = "/tmp/bm2-config-test-" + @env.now().to_string()
  @fs.create_dir(dir)
  @fs.write_string_to_file(
    dir + "/bm2.toml",
    "name = \"blog\"\nscript = \"index.ts\"\ninstances = 1\nport = 3000\n",
  )
  let config = @config.load(dir + "/bm2.toml")
  assert_eq(config.name, "blog")
  assert_eq(config.cwd, dir)
  let missing = try @config.load(dir + "/nope.toml") catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(missing)
}
