///|
test "trim_spaces/both_ends" {
  assert_eq(trim_spaces("  hello world  "), "hello world")
}

///|
test "trim_spaces/tabs_and_crlf" {
  assert_eq(trim_spaces("\t\tx\r"), "x")
  assert_eq(trim_spaces(" \t "), "")
}

///|
test "trim_spaces/nothing_to_do" {
  assert_eq(trim_spaces("intact"), "intact")
}

///|
test "parse_int/strict_digits" {
  assert_eq(parse_int("42"), Some(42))
  assert_eq(parse_int("0"), Some(0))
  assert_eq(parse_int("007"), Some(7))
}

///|
test "parse_int/rejects_partial" {
  assert_eq(parse_int("4x"), None)
  assert_eq(parse_int("-1"), None)
  assert_eq(parse_int(""), None)
}

///|
test "quoted_value/manifest_line" {
  assert_eq(quoted_value("name = \"chensuiyi/bm2\""), "chensuiyi/bm2")
  assert_eq(quoted_value("version = \"0.5.0\" # comment"), "0.5.0")
}

///|
test "quoted_value/unquoted_is_empty" {
  assert_eq(quoted_value("no quotes here"), "")
}

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
test "is_blank" {
  assert_eq(is_blank(""), true)
  assert_eq(is_blank("  \t "), true)
  assert_eq(is_blank(" a "), false)
}

///|
test "remove_prefix_suffix" {
  assert_eq(remove_prefix("v1.2.3", "v"), Some("1.2.3"))
  assert_eq(remove_prefix("1.2.3", "v"), None)
  assert_eq(remove_suffix("app.log", ".log"), Some("app"))
  assert_eq(remove_suffix("app", ".log"), None)
}

///|
test "pad_start_end" {
  assert_eq(pad_start("42", 5), "00042")
  assert_eq(pad_start("42", 5, pad="-"), "---42")
  assert_eq(pad_start("abcdef", 3), "abcdef")
  assert_eq(pad_end("ab", 4), "ab  ")
  assert_eq(pad_end("ab", 4, pad=".*"), "ab.*")
}

///|
test "to_lower_upper" {
  assert_eq(to_lower("ABC-def"), "abc-def")
  assert_eq(to_upper("abc-DEF"), "ABC-DEF")
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
test "range_basic" {
  assert_eq(range(0, 5), [0, 1, 2, 3, 4])
  assert_eq(range(2, 10, step=3), [2, 5, 8])
  assert_eq(range(5, 5), [])
  assert_eq(range(0, 5, step=0), [])
}

///|
test "clamp_int_bounds" {
  assert_eq(clamp_int(5, 1, 10), 5)
  assert_eq(clamp_int(-3, 1, 10), 1)
  assert_eq(clamp_int(99, 1, 10), 10)
}

///|
test "hex_roundtrip" {
  assert_eq(hex_encode(@utf8.encode("AB")), "4142")
  assert_eq(hex_decode("4142"), Some(@utf8.encode("AB")))
  assert_eq(hex_decode("41g2"), None)
  assert_eq(hex_decode("414"), None)
  assert_eq(hex_decode(""), Some(b""))
}
