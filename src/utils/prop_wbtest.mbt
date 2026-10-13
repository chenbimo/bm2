///|
/// Property tests: invariants that must hold for *every* input, rather than the
/// examples a hand-written case happens to cover. Everything here is pure, so the
/// properties are fast and never touch the filesystem or the network.

///|
/// `jstr` is what stands between a log line and the JSON document it travels in,
/// and its output goes to a third-party platform verbatim. So the property is the
/// strongest one available: whatever the input, the escaped literal parses back
/// through the real parser as exactly that input.
test "quickcheck: jstr round-trips through a real parser" {
  @quickcheck.check(count=500, (text : String) => {
    let literal = jstr(text)
    if !@json.valid(literal) {
      return false
    }
    let decoded : String? = try {
      let back : String = @json.from_json(@json.parse(literal))
      Some(back)
    } catch {
      _ => None
    } noraise {
      value => value
    }
    match decoded {
      Some(back) => back == text
      None => false
    }
  })
}

///|
/// The object and array builders feed the event log and every notification
/// payload, so their output has to parse — and an arbitrary key or value must not
/// be able to escape its own literal and add a sibling field.
test "quickcheck: jobj and jarr always parse" {
  @quickcheck.check(count=300, (fields : Array[(String, String)]) => {
    @json.valid(jobj(fields.map(pair => (pair.0, jstr(pair.1)))))
  })
  @quickcheck.check(count=300, (items : Array[String]) => {
    @json.valid(jarr(items.map(jstr)))
  })
}

///|
/// Version comparison runs on parsed versions, and parsing is lenient by design
/// (any prefix is skipped, missing segments read as zero). The two properties an
/// upgrade decision leans on are that the order is antisymmetric, and that it
/// reports equality exactly when the versions are equal.
test "quickcheck: semver compare is an order" {
  @quickcheck.check(count=500, (versions : (String, String)) => {
    let (left, right) = versions
    let a = parse(left)
    let b = parse(right)
    compare(a, b) == -compare(b, a) && (compare(a, b) == 0) == (a == b)
  })
}

///|
/// Fold an arbitrary integer into the range a real release segment lives in.
fn in_range(value : Int32) -> Int32 {
  let reduced = value % 1000000
  if reduced < 0 {
    -reduced
  } else {
    reduced
  }
}

///|
/// Rendering is the inverse of parsing, over the range a real release lives in:
/// this is also the range bm2 writes back out (state files, upgrade manifests).
/// The integers are folded into that range rather than filtered, so every
/// iteration tests something instead of being discarded.
test "quickcheck: semver parsing round-trips real versions" {
  @quickcheck.check(count=300, (parts : (Int32, Int32, Int32)) => {
    let (major, minor, patch) = parts
    let text = "\{in_range(major)}.\{in_range(minor)}.\{in_range(patch)}"
    let version = parse(text)
    // The input is what a release looks like, `to_string` reproduces it, and
    // parsing what we rendered is a no-op.
    version.to_string() == text && parse(version.to_string()) == version
  })
}

///|
/// Rejoin `parts` the way a caller would have to after splitting.
fn join(parts : Array[String], sep : String) -> String {
  let buf = StringBuilder()
  let mut first = true
  for part in parts {
    if !first {
      buf.write_string(sep)
    }
    first = false
    buf.write_string(part)
  }
  buf.to_string()
}

///|
/// `split` takes log lines and endpoint files apart by hand, so the parts have to
/// rejoin into exactly the input: no lost byte, no duplicated separator.
test "quickcheck: split round-trips" {
  @quickcheck.check(count=300, (input : (String, String)) => {
    let (text, sep) = input
    // An empty separator is the one input the contract excludes.
    if sep.is_empty() {
      return true
    }
    join(split(text, sep), sep) == text
  })
}

///|
/// URL encoding must leave nothing behind that a query string treats as
/// structure: every output character is unreserved, or `%` plus two uppercase
/// hex digits.
test "quickcheck: url_encode emits only unreserved or escaped bytes" {
  @quickcheck.check(count=300, (text : String) => {
    let encoded = url_encode(text)
    let mut index = 0
    while index < encoded.length() {
      let ch = encoded[index].unsafe_to_char()
      if ch == '%' {
        // A percent escape: two uppercase hex digits must follow.
        if index + 2 >= encoded.length() {
          return false
        }
        if !is_upper_hex(encoded[index + 1].unsafe_to_char()) ||
          !is_upper_hex(encoded[index + 2].unsafe_to_char()) {
          return false
        }
        index += 3
      } else if is_unreserved_char(ch) {
        index += 1
      } else {
        return false
      }
    }
    true
  })
}

///|
fn is_upper_hex(ch : Char) -> Bool {
  ch is ('0'..<='9') || ch is ('A'..<='F')
}

///|
/// The RFC 3986 unreserved set, written out here rather than reused from the
/// implementation, so the property pins the standard and not the code.
fn is_unreserved_char(ch : Char) -> Bool {
  ch is ('0'..<='9') ||
  ch is ('A'..<='Z') ||
  ch is ('a'..<='z') ||
  ch == '-' ||
  ch == '.' ||
  ch == '_' ||
  ch == '~'
}
