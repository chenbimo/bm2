///|
/// `jstr` is the defence between a log line and the JSON document it travels in:
/// a quote or a control character in a body must not be able to break out of the
/// literal. The escaping itself is the standard library's, so what this pins is
/// the wire contract.
test "jstr/wraps_and_escapes" {
  assert_eq(jstr("say \"hi\""), "\"say \\\"hi\\\"\"")
  assert_eq(jstr("a\"b\\c\nd\te"), "\"a\\\"b\\\\c\\nd\\te\"")
  assert_eq(jstr("\u{01}"), "\"\\u0001\"")
}

///|
test "jobj/optional_keys_vanish" {
  // Absent optional fields simply are not in the input array, so they never
  // become nulls on the wire.
  assert_eq(jobj([]), "{}")
  assert_eq(jobj([("a", jstr("1")), ("n", "42")]), "{\"a\":\"1\",\"n\":42}")
}

///|
test "jarr/fragments" {
  assert_eq(jarr([]), "[]")
  assert_eq(jarr([jstr("x"), "1"]), "[\"x\",1]")
}

///|
test "url_encode/unreserved_pass_through" {
  assert_eq(url_encode("aB9-._~"), "aB9-._~")
}

///|
test "url_encode/specials_and_multibyte" {
  assert_eq(url_encode("a b&c=1"), "a%20b%26c%3D1")
  assert_eq(url_encode("中"), "%E4%B8%AD")
}

///|
test "split_basic" {
  assert_eq(split("a,b,,c", ","), ["a", "b", "", "c"])
  assert_eq(split("no-sep", ","), ["no-sep"])
  assert_eq(split("", ","), [""])
  assert_eq(split("a::b", "::"), ["a", "b"])
}

///|
test "chunk_arrays" {
  assert_eq(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])
  assert_eq(chunk([1, 2], 5), [[1, 2]])
  assert_eq(chunk([1, 2], 0), [])
}

///|
test "uniq_keeps_first" {
  assert_eq(uniq(["a", "b", "a", "c", "b"]), ["a", "b", "c"])
  assert_eq(uniq([3, 3, 3]), [3])
}

///|
/// Display width is terminal columns, not code units: that difference is the whole
/// reason this helper exists.
test "display width counts terminal columns" {
  assert_eq(display_width(""), 0)
  assert_eq(display_width("abc"), 3)
  assert_eq(display_width("名称"), 4)
  assert_eq(display_width("运行时长"), 8)
  assert_eq(display_width("api 实例 0"), 10)
  assert_eq(display_width("端口 3020"), 9)
  // Fullwidth forms live outside the CJK blocks.
  assert_eq(display_width("）"), 2)
}

///|
test "padding pads to the display width and never truncates" {
  assert_eq(pad_to("名称", 6), "名称  ")
  assert_eq(pad_to("abc", 8), "abc     ")
  assert_eq(pad_to("名称", 4), "名称")
  assert_eq(pad_to("aaaa", 2), "aaaa")
}
