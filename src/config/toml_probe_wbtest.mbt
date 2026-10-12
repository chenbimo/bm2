///|
const PROBE_DOC : String =
  #|[[apps]]
  #|name = "api"
  #|cwd = "/srv/yicode/api"
  #|script = "index.ts"
  #|instances = 4
  #|port = 3000
  #|
  #|[[apps]]
  #|name = "upload"
  #|cwd = "/srv/yicode/upload"
  #|script = "index.ts"
  #|instances = 2
  #|port = 3100
  #|

///|
test "bobzhang/toml parses bm2.toml shape on native" {
  let value = @toml.parse(PROBE_DOC)
  guard value is @toml.TomlTable(root) else { fail("root must be a table") }
  guard root.get("apps") is Some(@toml.TomlArray(apps)) else {
    fail("apps must be an array")
  }
  assert_eq(apps.length(), 2)
  guard apps[0] is @toml.TomlTable(first) else { fail("app must be a table") }
  assert_eq(first.get("name"), Some(@toml.TomlString("api")))
  assert_eq(first.get("port"), Some(@toml.TomlInteger(3000)))
}
