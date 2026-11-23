///|
/// The runtime verdict is a pure function so the probe can run wherever its wait
/// is cheapest (the control task) and still report exactly these words. The
/// blocking part — running the helper and waiting for it — is covered end to end
/// by the daemon's probe tests and the e2e suite.
test "runtime_verdict judges a missing runtime, a bad exit and a version" {
  // A missing binary is the exec failure the caller maps here.
  assert_eq(
    runtime_verdict("bun", 127, ""),
    Some("bun not found on PATH (or failed to execute)"),
  )
  assert_eq(
    runtime_verdict("bun", 1, ""),
    Some("bun --version exited with code 1"),
  )
  assert_eq(
    runtime_verdict("bun", 0, "not a version"),
    Some("cannot parse bun --version output"),
  )
  // Below the floor: the reason names both what was found and what is required.
  match runtime_verdict("bun", 0, "1.0.0") {
    Some(reason) => {
      assert_true(reason.contains("1.0.0"))
      assert_true(reason.contains("1.4.0"))
    }
    None => fail("bun 1.0.0 must be below the floor")
  }
  // At the floor and above it: accepted.
  assert_eq(runtime_verdict("bun", 0, "1.4.0"), None)
  assert_eq(runtime_verdict("bun", 0, "1.9.3"), None)
  // node has its own floor: 24.0.0 is the line bm2 ships against, so the whole
  // 22.x and 23.x range must be refused — and the reason has to name both the
  // version found and the floor, or an operator cannot tell why it was refused.
  match runtime_verdict("node", 0, "22.12.0") {
    Some(reason) => {
      assert_true(reason.contains("22.12.0"))
      assert_true(reason.contains("24.0.0"))
    }
    None => fail("node 22.x must be below the floor")
  }
  match runtime_verdict("node", 0, "23.11.1") {
    Some(reason) => assert_true(reason.contains("23.11.1"))
    None => fail("node 23.x must be below the floor")
  }
  assert_eq(runtime_verdict("node", 0, "24.0.0"), None)
  assert_eq(runtime_verdict("node", 0, "26.13.1"), None)
}

///|
/// The two verdict messages that depend on the probe itself, not on its output.
test "runtime probe messages name the runtime and the deadline" {
  assert_true(runtime_timeout("bun").contains("bun"))
  assert_true(runtime_timeout("bun").contains("5000ms"))
  assert_true(runtime_unrunnable("node").contains("node"))
  assert_true(runtime_unrunnable("node").contains("not found on PATH"))
}
