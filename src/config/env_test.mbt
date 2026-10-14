///|
/// 占位符标记是 `__NAME__`，只写在引号里，展开发生在已解析出的字符串值上。
fn expand_ok(value : String, vars : Map[String, String]) -> String raise {
  @config.expand_with(value, "t", fn(name) { vars.get(name) })
}

///|
fn expand_error(value : String, vars : Map[String, String]) -> String {
  try @config.expand_with(value, "t", fn(name) { vars.get(name) }) catch {
    e => e.to_string()
  } noraise {
    _ => "no-error"
  }
}

///|
/// 整个值、或者值里的一段，都能替换。
test "markers resolve whole values and fragments" {
  let vars : Map[String, String] = Map([("APP_PORT", "4391"), ("HOST", "db")])
  assert_eq(expand_ok("__APP_PORT__", vars), "4391")
  assert_eq(expand_ok("smtp://__HOST__:25", vars), "smtp://db:25")
  assert_eq(expand_ok("no markers here", vars), "no markers here")
}

///|
/// 没有成对的下划线就是普通文本。`a__b` 不该因为「像标记」就报错。
test "text with an unpaired __ is left alone" {
  let vars : Map[String, String] = Map([("HOST", "db")])
  assert_eq(expand_ok("a__b", vars), "a__b")
  assert_eq(expand_ok("__HOST_", vars), "__HOST_")
  assert_eq(expand_ok("_", vars), "_")
}

///|
/// 名字里允许单个下划线，标记在最近的一对下划线处闭合。
test "names may contain single underscores" {
  let vars : Map[String, String] = Map([("BM2_TEST_HOOK", "x")])
  assert_eq(expand_ok("__BM2_TEST_HOOK__", vars), "x")
}

///|
/// 闭合了但名字不合法、或者变量没设，都报错并点名。
test "closed markers are validated" {
  let none : Map[String, String] = Map([])
  assert_true(expand_error("__9BAD__", none).contains("invalid"))
  let missing = expand_error("__BM2_MISSING_URL__", none)
  assert_true(missing.contains("BM2_MISSING_URL"))
  assert_true(missing.contains("which is not set"))
}
