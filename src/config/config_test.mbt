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
/// 开发模式永远单实例:配置里的实例数只在 serve 下生效。
test "development mode runs a single instance" {
  let development = @config.parse(
    VALID_DOC,
    BASE_DIR,
    mode=@config.Mode::Development,
  )
  assert_eq(development.mode, @config.Mode::Development)
  assert_eq(development.instances, 1)
  // 同一份文档在生产模式下仍是 4 个:实例数没有被改写,只是开发模式不采用它。
  assert_eq(@config.parse(VALID_DOC, BASE_DIR).instances, 4)
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
/// 造一份临时项目目录并写入给定的 .env 文件。(先清一次,重复跑不会撞 already exists。)
fn env_dir(name : String, files : Array[(String, String)]) -> String raise {
  let dir = "/tmp/bm2-env-" + name
  cleanup_env_dir(dir, files)
  @fs.create_dir(dir)
  for pair in files {
    @fs.write_string_to_file(dir + "/" + pair.0, pair.1)
  }
  dir
}

///|
fn cleanup_env_dir(dir : String, files : Array[(String, String)]) -> Unit {
  for pair in files {
    try @fs.remove_file(dir + "/" + pair.0) catch {
      _ => ()
    } noraise {
      _ => ()
    }
  }
  try @fs.remove_dir(dir) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// 从注入数组里取一个键。顺序不保证,所以不能按下标读。
fn injected(entries : Array[(String, String)], key : String) -> String {
  let mut found = ""
  for pair in entries {
    if pair.0 == key {
      found = pair.1
    }
  }
  found
}

///|
/// 扫描结果既是注入给实例的环境,也是 ${VAR} 的解析源——同一份 map,所以应用和
/// 管理者不可能对同一个名字读出不同的值。
test ".env files feed both the injected environment and placeholders" {
  let files : Array[(String, String)] = [
    (".env", "SHARED=base\n"),
    (".env.production", "MYSQL_HOST=db.internal\n"),
    (".env.local", "SHARED=local\n"),
  ]
  let dir = env_dir("scan", files)
  let config = @config.parse(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|instances = 1
      #|port = 3000
      #|cwd = "/srv/${MYSQL_HOST}"
      #|
    ),
    dir,
  )
  // 三个文件合并:同名键后加载的覆盖先加载的。
  assert_eq(config.env.length(), 2)
  assert_eq(injected(config.env, "SHARED"), "local")
  assert_eq(injected(config.env, "MYSQL_HOST"), "db.internal")
  // 同一个值也解析进了配置里的占位符。
  assert_eq(config.cwd, "/srv/db.internal")
  cleanup_env_dir(dir, files)
}

///|
/// 模式决定带模式名的那两份文件。
test ".env files: mode selects the mode-specific file" {
  let files : Array[(String, String)] = [
    (".env", "SHARED=base\n"),
    (".env.production", "TARGET=prod\n"),
    (".env.development", "TARGET=dev\n"),
  ]
  let dir = env_dir("mode", files)
  let production = @config.parse(VALID_DOC, dir, mode=@config.Mode::Production)
  let development = @config.parse(
    VALID_DOC,
    dir,
    mode=@config.Mode::Development,
  )
  assert_eq(injected(production.env, "TARGET"), "prod")
  assert_eq(injected(development.env, "TARGET"), "dev")
  cleanup_env_dir(dir, files)
}

///|
/// 坏文件是硬错误,而且要说出是哪个文件、哪一行——静默少一个变量最难查。
test ".env files: a malformed file names the file and the line" {
  let files : Array[(String, String)] = [(".env", "A=1\nB 2\n")]
  let dir = env_dir("bad", files)
  let message = try {
    ignore(@config.parse(VALID_DOC, dir))
    "no error"
  } catch {
    e => e.to_string()
  } noraise {
    _ => "no error"
  }
  assert_true(message.contains(dir + "/.env line 2"))
  cleanup_env_dir(dir, files)
}

///|
/// 一个 .env 文件都没有也是正常的:项目环境就是空的。
test ".env files: absent files are not an error" {
  let plain = @config.parse(VALID_DOC, "/tmp/bm2-env-absent")
  assert_eq(plain.env.length(), 0)
}

///|
/// 数字字段也吃占位符:展开发生在字段解析之前,而 TOML 没有不带引号的占位符写法,
/// 所以从环境来的数字必然是带引号的字符串。
test "numeric fields take a quoted placeholder" {
  let files : Array[(String, String)] = [
    (".env.production", "APP_PORT=4391\nAPP_MEM=1024\n"),
  ]
  let dir = env_dir("num", files)
  let config = @config.parse(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|instances = "1"
      #|port = "${APP_PORT}"
      #|max_memory_mb = "${APP_MEM}"
      #|
    ),
    dir,
  )
  assert_eq(config.port, 4391)
  assert_eq(config.max_memory_mb, 1024)
  assert_eq(config.instances, 1)
  cleanup_env_dir(dir, files)
}

///|
/// 引号里的东西不是数字时,报错要点名字段和实际拿到的值。
test "a quoted number that is not a number is rejected" {
  let message = parse_error(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|instances = 1
      #|port = "4391x"
      #|
    ),
  )
  assert_true(message.contains("root.port must be an integer"))
  assert_true(message.contains("4391x"))
}

///|
/// 布尔字段同理。
test "boolean fields take a quoted placeholder" {
  let files : Array[(String, String)] = [
    (".env.production", "NOTIFY_ON=true\n"),
  ]
  let dir = env_dir("bool", files)
  let config = @config.parse(
    VALID_DOC + "\n[notify]\nenabled = \"${NOTIFY_ON}\"\n",
    dir,
  )
  assert_true(config.notify.enabled)
  cleanup_env_dir(dir, files)
}

///|
/// 布尔字段写了个不是布尔的字符串也一样点名。
test "a quoted non-boolean is rejected" {
  let message = parse_error(VALID_DOC + "\n[notify]\nenabled = \"maybe\"\n")
  assert_true(message.contains("notify.enabled must be a boolean"))
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
    ("max_memory_mb = 0", "max_memory_mb must be between 1 and 1048576"),
    ("max_memory_mb = 1048577", "max_memory_mb must be between 1 and 1048576"),
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
/// The accepted side of every boundary the validator states: an instance count
/// at the documented maximum, a port at the top of the legal range, and zero
/// for the delays that are documented as "0 means immediately".
test "accepts values exactly at the documented bounds" {
  let config = @config.parse(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|instances = 1024
      #|port = 3000
      #|max_memory_mb = 1
      #|max_restarts = 0
      #|restart_delay_ms = 0
      #|min_uptime_ms = 0
      #|stop_timeout_ms = 60000
      #|
    ),
    BASE_DIR,
  )
  assert_eq(config.instances, 1024)
  assert_eq(config.max_restarts, 0)
  assert_eq(config.restart_delay_ms, 0)
  assert_eq(config.min_uptime_ms, 0)
  assert_eq(config.stop_timeout_ms, 60000)
  // One instance may still sit on the very last port.
  let top = @config.parse(
    (
      #|name = "blog"
      #|script = "index.ts"
      #|instances = 1
      #|port = 65535
      #|
    ),
    BASE_DIR,
  )
  assert_eq(top.port, 65535)
}

///|
test "rejects a name that does not start with a letter" {
  for name in ["_blog", "1blog", "-blog"] {
    let message = parse_error(
      "name = \"" +
      name +
      "\"\nscript = \"index.ts\"\ninstances = 1\nport = 3000\n",
    )
    assert_true(message.contains("invalid name"))
  }
}

///|
test "rejects numeric limits at the documented bounds" {
  // Each case supplies the whole document: doubling up on a key would make the
  // TOML parser reject it before the validator ever sees it.
  let cases = [
    ("instances = 1025\nport = 3000", "instances must be between 1 and 1024"),
    ("instances = 1\nport = 0", "port must be within 1 ~ 65535"),
    ("instances = 1\nport = 65536", "port must be within 1 ~ 65535"),
    (
      "instances = 1\nport = 3000\nmax_memory_mb = 0", "max_memory_mb must be between 1 and 1048576",
    ),
    (
      "instances = 1\nport = 3000\nstop_timeout_ms = 60001", "stop_timeout_ms must be between 1 and 60000",
    ),
  ]
  for pair in cases {
    let (fields, expect) = pair
    let doc = "name = \"blog\"\nscript = \"index.ts\"\n" + fields + "\n"
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

///|
/// `[logs]` is optional: without it a project rotates at the built-in size and
/// keeps every generation. With it, both limits are the project's to choose.
test "logs section: defaults, overrides and bounds" {
  let doc = "name = \"app\"\ncwd = \"/srv/app\"\nscript = \"index.ts\"\ninstances = 1\nport = 3000\n"
  let config = @config.parse(doc, "/srv/app")
  assert_eq(config.logs.max_size_mb, 10)
  assert_eq(config.logs.keep, 0)
  let tuned = @config.parse(
    doc + "[logs]\nmax_size_mb = 50\nkeep = 3\n",
    "/srv/app",
  )
  assert_eq(tuned.logs.max_size_mb, 50)
  assert_eq(tuned.logs.keep, 3)
  // A rotation that silently never happens, and a negative generation count,
  // are both rejected at parse time rather than discovered later on disk.
  for bad in ["[logs]\nmax_size_mb = 0\n", "[logs]\nkeep = -1\n"] {
    let rejected = try {
      ignore(@config.parse(doc + bad, "/srv/app"))
      false
    } catch {
      _ => true
    } noraise {
      _ => false
    }
    assert_true(rejected)
  }
}
