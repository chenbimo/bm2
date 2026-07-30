///|
const VALID_DOC : String =
  #|state_dir = "~/.local/state/bm2"
  #|
  #|[[apps]]
  #|name = "api"
  #|cwd = "/srv/yicode/api"
  #|script = "index.ts"
  #|instances = 4
  #|base_port = 3000
  #|max_memory_mb = 512
  #|max_restarts = 10
  #|restart_delay_ms = 1000
  #|min_uptime_ms = 10000
  #|stop_timeout_ms = 10000
  #|
  #|[[apps]]
  #|name = "upload"
  #|cwd = "/srv/yicode/upload"
  #|script = "src/main.ts"
  #|instances = 2
  #|base_port = 3100
  #|max_memory_mb = 256
  #|max_restarts = 5
  #|restart_delay_ms = 1000
  #|min_uptime_ms = 10000
  #|stop_timeout_ms = 10000
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
  assert_eq(config.state_dir, Some("~/.local/state/bm2"))
  assert_eq(config.apps.length(), 2)
  assert_eq(config.apps[0].name, "api")
  assert_eq(config.apps[0].instances, 4)
  assert_eq(config.apps[0].base_port, 3000)
  assert_eq(config.apps[1].script, "src/main.ts")
}

///|
test "state_dir is optional" {
  let doc =
    #|[[apps]]
    #|name = "api"
    #|cwd = "/srv/api"
    #|script = "index.ts"
    #|instances = 1
    #|base_port = 3000
    #|max_memory_mb = 128
    #|max_restarts = 3
    #|restart_delay_ms = 500
    #|min_uptime_ms = 1000
    #|stop_timeout_ms = 1000
    #|
  let config = @config.parse(doc)
  assert_eq(config.state_dir, None)
}

///|
test "rejects invalid toml document" {
  assert_true(parse_error("apps = [").contains("InvalidDocument"))
}

///|
test "rejects missing apps" {
  assert_true(
    parse_error("state_dir = \"/tmp/bm2\"\n").contains("apps is required"),
  )
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
test "rejects unknown field" {
  let message = parse_error(
    with_app(
      (
        #|name = "extra"
        #|cwd = "/srv/extra"
        #|script = "index.ts"
        #|instances = 1
        #|base_port = 4000
        #|max_memory_mb = 128
        #|max_restarts = 3
        #|restart_delay_ms = 500
        #|min_uptime_ms = 1000
        #|stop_timeout_ms = 1000
        #|env = {}
        #|
      ),
    ),
  )
  assert_true(message.contains("unknown field env"))
}
