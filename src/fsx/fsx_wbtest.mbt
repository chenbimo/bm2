///|
/// Existence probe built on fsx itself, so the tests need no fs dependency.
fn exists(path : String) -> Bool {
  file_size(path) is Some(_)
}

///|
/// append 到不存在的文件要能创建出来（原 C 用 O_CREAT），并且读到的一直是
/// 追加后的完整内容。
test "append_file creates a missing file" {
  let dir = "/tmp/fsx-test-append-new"
  mkdir_p(dir)
  let path = dir + "/fresh.log"
  unlink_quiet(path)
  append_file(path, @utf8.encode("a\n"))
  append_file(path, @utf8.encode("b\n"))
  assert_eq(@utf8.decode_lossy(read_small(path)), "a\nb\n")
}

///|
fn unlink_quiet(path : String) -> Unit {
  let _ = try unlink(path) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// cap 小于文件大小时只读回前 cap 字节：read_small 的"有界"是调用方的
/// 安全边界，超大文件不能整个读进内存。
test "read_small honours the cap" {
  let dir = "/tmp/fsx-test-cap"
  mkdir_p(dir)
  let path = dir + "/big.txt"
  write_atomic(path, @utf8.encode("0123456789"))
  assert_eq(@utf8.decode_lossy(read_small(path, cap=4)), "0123")
  // 文件小于 cap 时读全部
  assert_eq(@utf8.decode_lossy(read_small(path, cap=64)), "0123456789")
}

///|
/// /proc 里的文件 size 恒为 0，走 read_all 分支：这条路径保证读进程信息
/// （内存、负载、进程树）不会因为 size 为 0 而读到空内容。
test "read_small reads /proc virtual files" {
  let text = @utf8.decode_lossy(read_small("/proc/self/stat", cap=4096))
  assert_true(text.length() > 0)
  assert_true(text.contains("("))
}

///|
test "write_atomic and append_file round-trip" {
  let dir = "/tmp/fsx-test-file"
  mkdir_p(dir + "/a/b")
  let path = dir + "/a/b/state.json"
  write_atomic(path, @utf8.encode("{\"v\":1}"))
  assert_eq(@utf8.decode_lossy(read_small(path)), "{\"v\":1}")
  assert_false(exists(path + ".tmp"))
  write_atomic(path, @utf8.encode("{\"v\":2}"))
  append_file(path, @utf8.encode("\nline2\n"))
  append_file(path, @utf8.encode("line3\n"))
  assert_eq(@utf8.decode_lossy(read_small(path)), "{\"v\":2}\nline2\nline3\n")
  unlink(path)
}

///|
test "mkdir_p is idempotent" {
  mkdir_p("/tmp/fsx-test-dirs/x/y")
  mkdir_p("/tmp/fsx-test-dirs/x/y")
  assert_true(exists("/tmp/fsx-test-dirs/x/y"))
}

///|
test "chmod reports a missing path" {
  let failed = try {
    chmod("/tmp/fsx-no-such-file", 0o600)
    false
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(failed)
}

///|
/// read_small backs the /proc reads (environ, status, cmdline), which is why it
/// stops at the cap instead of growing a buffer to fit whatever it reads.
test "read_small stops at the cap" {
  let path = "/tmp/fsx-test-cap/big.txt"
  mkdir_p("/tmp/fsx-test-cap")
  write_atomic(path, @utf8.encode("x".repeat(100)))
  assert_eq(read_small(path, cap=10).length(), 10)
  assert_eq(read_small(path, cap=1000).length(), 100)
  unlink(path)
}

///|
test "file_size reports bytes and missing files" {
  let path = "/tmp/fsx-test-size/app.log"
  mkdir_p("/tmp/fsx-test-size")
  write_atomic(path, @utf8.encode("12345"))
  assert_eq(file_size(path), Some(5L))
  assert_eq(file_size(path + "/none"), None)
}

///|
/// The daemon compares config paths to decide whether two registrations name the
/// same project, so the comparison has to survive spelling differences.
test "realpath canonicalizes, and reports what it cannot resolve" {
  let dir = "/tmp/fsx-test-realpath"
  mkdir_p(dir + "/sub")
  write_atomic(dir + "/bm2.toml", @utf8.encode("name = \"app\"\n"))
  let canonical = realpath(dir + "/bm2.toml")
  assert_true(canonical is Some(_))
  // The same file spelled with a redundant `.`, and through `..`: one answer.
  assert_eq(realpath(dir + "/./bm2.toml"), canonical)
  assert_eq(realpath(dir + "/sub/../bm2.toml"), canonical)
  // A path that does not exist has no canonical form.
  assert_eq(realpath(dir + "/nope.toml"), None)
}

///|
/// 读目录会失败（EISDIR），但每个失败句柄都必须关掉：守护进程长期运行，
/// 一次泄漏几个 fd，几天就耗尽。这条测试把失败路径跑 20 次再数 fd。
test "read_small closes the handle when reading fails" {
  let dir = "/tmp/fsx-test-fd"
  mkdir_p(dir)
  let before = @fs.read_dir("/proc/self/fd").length()
  for _ in 0..<20 {
    let _ = try read_small(dir) catch {
      _ => b""
    } noraise {
      b => b
    }
  }
  let after = @fs.read_dir("/proc/self/fd").length()
  // read_dir 自身占一个 fd，允许 2 的波动；泄漏 20 个则远远超出。
  assert_true(after <= before + 2)
}
