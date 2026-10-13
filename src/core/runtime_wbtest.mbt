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
  let old = runtime_verdict("bun", 0, "1.0.0")
  assert_true(old is Some(_))
  match old {
    Some(reason) => {
      assert_true(reason.contains("1.0.0"))
      assert_true(reason.contains("1.4.0"))
    }
    None => ()
  }
  // At the floor and above it: accepted.
  assert_eq(runtime_verdict("bun", 0, "1.4.0"), None)
  assert_eq(runtime_verdict("bun", 0, "1.9.3"), None)
  // node has its own floor.
  assert_true(runtime_verdict("node", 0, "24.0.0") is None)
  assert_true(runtime_verdict("node", 0, "22.0.0") is Some(_))
}

///|
/// The two verdict messages that depend on the probe itself, not on its output.
test "runtime probe messages name the runtime and the deadline" {
  assert_true(runtime_timeout("bun").contains("bun"))
  assert_true(runtime_timeout("bun").contains("5000ms"))
  assert_true(runtime_unrunnable("node").contains("node"))
  assert_true(runtime_unrunnable("node").contains("not found on PATH"))
}
