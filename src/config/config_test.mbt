///|
const VALID_DOC : String =
  #|[[apps]]
  #|name = "api"
  #|cwd = "/srv/yicode/api"
  #|script = "index.ts"
  #|instances = 4
  #|base_port = 3000
  #|
  #|[apps.env]
  #|NODE_ENV = "production"
  #|FEATURE_CACHE = "true"
  #|
  #|[[apps]]
  #|name = "upload"
  #|cwd = "/srv/yicode/upload"
  #|script = "src/main.ts"
  #|instances = 2
  #|base_port = 3100
  #|

///|
fn with_app(app_toml : String) -> String {
  VALID_DOC + "\n[[apps]]\n" + app_toml
}

///|
fn parse_error(doc : String) -> String raise {
  try @config.parse(doc) catch {
    e => e.to_string()
  } noraise {
    _ => fail("expected parse to fail")
  }
}

///|
test "parses valid bm2.toml" {
  let config = @config.parse(VALID_DOC)
  assert_eq(config.apps.length(), 2)
  assert_eq(config.apps[0].name, "api")
  assert_eq(config.apps[0].instances, 4)
  assert_eq(config.apps[0].base_port, 3000)
  assert_eq(config.apps[1].script, "src/main.ts")
  assert_eq(config.apps[0].max_memory_mb, 512)
  assert_eq(config.apps[0].max_restarts, 10)
  assert_eq(config.apps[0].restart_delay_ms, 1000)
  assert_eq(config.apps[0].min_uptime_ms, 10000)
  assert_eq(config.apps[0].env["NODE_ENV"], "production")
  assert_eq(config.apps[0].env["FEATURE_CACHE"], "true")
  assert_true(config.apps[1].env.is_empty())
}

///|
test "rejects state_dir field" {
  let message = parse_error("state_dir = \"/tmp/bm2\"\napps = []\n")
  assert_true(message.contains("unknown field state_dir"))
}

///|
test "rejects invalid toml document" {
  assert_true(parse_error("apps = [").contains("InvalidDocument"))
}

///|
test "rejects missing apps" {
  assert_true(parse_error("").contains("apps is required"))
}

///|
test "rejects empty apps" {
  assert_true(parse_error("apps = []\n").contains("at least one app"))
}

///|
test "rejects missing script" {
  let doc =
    #|[[apps]]
    #|name = "api"
    #|cwd = "/srv/api"
    #|instances = 1
    #|base_port = 3000
    #|
  assert_true(parse_error(doc).contains("apps[0].script is required"))
}

///|
test "rejects invalid app name" {
  let message = parse_error(
    with_app(
      (
        #|name = "Api"
        #|cwd = "/srv/api2"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 4000
        #|max_memory_mb = 128
        #|max_restarts = 3
        #|restart_delay_ms = 500
        #|min_uptime_ms = 1000
        #|stop_timeout_ms = 1000
        #|
      ),
    ),
  )
  assert_true(message.contains("invalid name"))
}

///|
test "rejects duplicate app names" {
  let message = parse_error(
    with_app(
      (
        #|name = "api"
        #|cwd = "/srv/api2"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 4000
        #|max_memory_mb = 128
        #|max_restarts = 3
        #|restart_delay_ms = 500
        #|min_uptime_ms = 1000
        #|stop_timeout_ms = 1000
        #|
      ),
    ),
  )
  assert_true(message.contains("duplicate app name api"))
}

///|
test "rejects overlapping port ranges" {
  let message = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = 2
        #|base_port = 3003
        #|max_memory_mb = 128
        #|max_restarts = 3
        #|restart_delay_ms = 500
        #|min_uptime_ms = 1000
        #|stop_timeout_ms = 1000
        #|
      ),
    ),
  )
  assert_true(message.contains("overlapping port ranges"))
}

///|
test "rejects adjacent-but-not-overlapping ranges as valid" {
  let config = @config.parse(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 3004
        #|max_memory_mb = 128
        #|max_restarts = 3
        #|restart_delay_ms = 500
        #|min_uptime_ms = 1000
        #|stop_timeout_ms = 1000
        #|
      ),
    ),
  )
  assert_eq(config.apps.length(), 3)
}

///|
test "rejects port range overflow" {
  let message = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = 2
        #|base_port = 65535
        #|max_memory_mb = 128
        #|max_restarts = 3
        #|restart_delay_ms = 500
        #|min_uptime_ms = 1000
        #|stop_timeout_ms = 1000
        #|
      ),
    ),
  )
  assert_true(message.contains("out of 1 ~ 65535"))
}

///|
test "rejects zero or excessive instances" {
  let zero = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = 0
        #|base_port = 4000
        #|max_memory_mb = 128
        #|max_restarts = 3
        #|restart_delay_ms = 500
        #|min_uptime_ms = 1000
        #|stop_timeout_ms = 1000
        #|
      ),
    ),
  )
  assert_true(zero.contains("instances must be between 1 and 1024"))
  let huge = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = 2000
        #|base_port = 4000
        #|max_memory_mb = 128
        #|max_restarts = 3
        #|restart_delay_ms = 500
        #|min_uptime_ms = 1000
        #|stop_timeout_ms = 1000
        #|
      ),
    ),
  )
  assert_true(huge.contains("instances must be between 1 and 1024"))
}

///|
test "rejects script escaping cwd" {
  let message = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "../escape.ts"
        #|instances = 1
        #|base_port = 4000
        #|max_memory_mb = 128
        #|max_restarts = 3
        #|restart_delay_ms = 500
        #|min_uptime_ms = 1000
        #|stop_timeout_ms = 1000
        #|
      ),
    ),
  )
  assert_true(message.contains("must not contain '..'"))
}

///|
test "parses app env" {
  let config = @config.parse(
    (
      #|[[apps]]
      #|name = "api"
      #|cwd = "/srv/api"
      #|script = "index.ts"
      #|instances = 1
      #|base_port = 3000
      #|
      #|[apps.env]
      #|NODE_ENV = "production"
      #|FEATURE_CACHE = "true"
      #|
    ),
  )
  assert_eq(config.apps[0].env["NODE_ENV"], "production")
  assert_eq(config.apps[0].env["FEATURE_CACHE"], "true")
}

///|
test "rejects non-string app env value" {
  assert_true(
    parse_error(
      (
        #|[[apps]]
        #|name = "api"
        #|cwd = "/srv/api"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 3000
        #|
        #|[apps.env]
        #|NODE_ENV = 1
        #|
      ),
    ).contains("apps[0].env.NODE_ENV must be a string"),
  )
}

///|
test "rejects reserved app env variable" {
  assert_true(
    parse_error(
      (
        #|[[apps]]
        #|name = "api"
        #|cwd = "/srv/api"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 3000
        #|
        #|[apps.env]
        #|PORT = "4000"
        #|
      ),
    ).contains("apps[0].env.PORT is reserved"),
  )
}

///|
test "rejects invalid app env variable name" {
  assert_true(
    parse_error(
      (
        #|[[apps]]
        #|name = "api"
        #|cwd = "/srv/api"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 3000
        #|
        #|[apps.env]
        #|"BAD-NAME" = "value"
        #|
      ),
    ).contains("apps[0].env has invalid variable name BAD-NAME"),
  )
}

///|
test "allows empty app env" {
  let config = @config.parse(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 4000
        #|env = {}
        #|
      ),
    ),
  )
  assert_true(config.apps[2].env.is_empty())
}

///|
test "rejects invalid runtime" {
  let message = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|runtime = "python"
        #|instances = 1
        #|base_port = 4000
        #|
      ),
    ),
  )
  assert_true(message.contains("runtime must be \"bun\" or \"node\""))
  let ok = @config.parse(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|runtime = "node"
        #|instances = 1
        #|base_port = 4000
        #|
      ),
    ),
  )
  assert_eq(ok.apps[2].runtime, "node")
  assert_eq(ok.apps[0].runtime, "bun")
}

///|
test "rejects invalid numeric limits" {
  let cases = [
    ("max_memory_mb = 0", "max_memory_mb must be at least 1"),
    ("max_restarts = -1", "out of range"),
    ("restart_delay_ms = -1", "out of range"),
    ("min_uptime_ms = -1", "out of range"),
    ("stop_timeout_ms = 0", "stop_timeout_ms must be at least 1"),
  ]
  for pair in cases {
    let (line, expect) = pair
    let app_toml = "name = \"extra\"\ncwd = \"/srv/extra\"\nscript = \"index.ts\"\ninstances = 1\nbase_port = 4000\n" +
      line +
      "\n"
    let message = parse_error(with_app(app_toml))
    assert_true(message.contains(expect))
  }
}

///|
test "rejects non-absolute cwd" {
  let message = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "srv/extra"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 4000
        #|
      ),
    ),
  )
  assert_true(message.contains("cwd must be an absolute path"))
}

///|
test "rejects absolute or empty script" {
  let abs = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "/abs.ts"
        #|instances = 1
        #|base_port = 4000
        #|
      ),
    ),
  )
  assert_true(abs.contains("script must be a relative path inside cwd"))
  let empty = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = ""
        #|instances = 1
        #|base_port = 4000
        #|
      ),
    ),
  )
  assert_true(empty.contains("script must be a relative path"))
}

///|
test "rejects empty app name" {
  let message = parse_error(
    with_app(
      (
        #|name = ""
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 4000
        #|
      ),
    ),
  )
  assert_true(message.contains("app name must not be empty"))
}

///|
test "rejects unknown app field" {
  let message = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 4000
        #|bogus = 1
        #|
      ),
    ),
  )
  assert_true(message.contains("unknown field bogus"))
}

///|
test "rejects app field type errors" {
  let inst = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = "x"
        #|base_port = 4000
        #|
      ),
    ),
  )
  assert_true(inst.contains("instances must be an integer"))
  let name = parse_error(
    with_app(
      (
        #|name = 1
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 4000
        #|
      ),
    ),
  )
  assert_true(name.contains("name must be a string"))
}

///|
test "rejects huge instances count" {
  let message = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = 3000000000
        #|base_port = 4000
        #|
      ),
    ),
  )
  assert_true(message.contains("out of range"))
}

///|
test "rejects non-table env" {
  let message = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 4000
        #|env = "x"
        #|
      ),
    ),
  )
  assert_true(message.contains("env must be a table"))
}

///|
test "load reports missing file" {
  let e = try @config.load("/nonexistent/bm2-no-such.toml") catch {
    err => err.to_string()
  } noraise {
    _ => fail("expected load failure")
  }
  assert_true(e.contains("cannot read config file"))
}
