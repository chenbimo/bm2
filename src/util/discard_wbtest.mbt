///|
suberror Boom {
  Bang
}

///|
test "discard swallows failures and runs the success path" {
  let mut ran = 0
  discard(() => ran += 1)
  assert_eq(ran, 1)
  discard(() => raise Bang)
  assert_eq(ran, 1)
}
