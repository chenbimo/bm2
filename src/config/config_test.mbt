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
test "rejects zero instances" {
  let message = parse_error(
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
  assert_true(message.contains("instances must be at least 1"))
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
