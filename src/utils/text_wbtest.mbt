///|
test "json_escape/control_and_quotes" {
  assert_eq(json_escape("a\"b\\c\nd\te"), "a\\\"b\\\\c\\nd\\te")
  assert_eq(json_escape("\u{01}"), "\\u0001")
}

///|
test "jstr/wraps_and_escapes" {
  assert_eq(jstr("say \"hi\""), "\"say \\\"hi\\\"\"")
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
