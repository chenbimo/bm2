///|
/// 边界钉住 core `Path` 的拼接语义：调用点靠这几条判断能不能直接换。
test "join_path normalizes separators" {
  assert_eq(join_path("/srv/api", "index.js"), "/srv/api/index.js")
  // 末尾多一个斜杠不会拼出双斜杠
  assert_eq(join_path("/srv/api/", "index.js"), "/srv/api/index.js")
  // 空的一段不引入多余斜杠
  assert_eq(join_path("", "index.js"), "index.js")
  assert_eq(join_path("/srv/api", ""), "/srv/api")
  // 第二段总是接在后面（实测：不是 POSIX 的绝对路径覆盖语义）
  assert_eq(join_path("/srv/api", "/etc/x"), "/srv/api/etc/x")
  // 相对路径照常拼接
  assert_eq(join_path("logs", "a.log"), "logs/a.log")
}
