///|
/// A semantic version triple.
pub(all) struct Semver {
  major : Int32
  minor : Int32
  patch : Int32
} derive(Eq, Debug)

///|
pub extend Semver with Eq::{equal, not_equal}

///|
pub extend Semver with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Which segment a bump increments.
pub(all) enum Bump {
  Patch
  Minor
  Major
}

///|
/// Extract the first `major.minor.patch` triple found in `text`. Lenient by
/// design: any prefix is skipped ("v1.4.0", "bun 1.4.0 (official)"), the scan
/// stops at the first character that is not a digit or a dot, and missing
/// segments read as zero — so pre-release suffixes ("0.3.0-beta.1") compare
/// as their release triple. Text with no digits yields all zeros, which
/// callers can treat as "unknown version".
pub fn parse(text : String) -> Semver {
  let buf = StringBuilder()
  let mut started = false
  for ch in text {
    if !started {
      if ch is ('0'..<='9') {
        started = true
        buf.write_char(ch)
      }
    } else if ch is ('0'..<='9') || ch == '.' {
      buf.write_char(ch)
    } else {
      break
    }
  }
  let parts = buf.to_string().split(".").to_array()
  Semver::{
    major: segment(parts, 0),
    minor: segment(parts, 1),
    patch: segment(parts, 2),
  }
}

///|
fn segment(parts : Array[StringView], index : Int32) -> Int32 {
  if index < parts.length() {
    digits(parts[index].to_owned())
  } else {
    0
  }
}

///|
/// Numeric prefix of one version segment; non-digits stop the scan.
fn digits(text : String) -> Int32 {
  let mut n = 0
  for ch in text {
    if !(ch is ('0'..<='9')) {
      break
    }
    n = n * 10 + ch.to_int() - 48
  }
  n
}

///|
/// Segment-by-segment ordering: -1, 0, or 1.
pub fn compare(a : Semver, b : Semver) -> Int32 {
  if a.major != b.major {
    return if a.major < b.major { -1 } else { 1 }
  }
  if a.minor != b.minor {
    return if a.minor < b.minor { -1 } else { 1 }
  }
  if a.patch != b.patch {
    return if a.patch < b.patch { -1 } else { 1 }
  }
  0
}

///|
/// Increment one segment, zeroing the ones below it.
pub fn bump(version : Semver, kind : Bump) -> Semver {
  match kind {
    Major => Semver::{ major: version.major + 1, minor: 0, patch: 0, }
    Minor =>
      Semver::{ major: version.major, minor: version.minor + 1, patch: 0, }
    Patch =>
      Semver::{
        major: version.major,
        minor: version.minor,
        patch: version.patch + 1,
      }
  }
}

///|
/// Render back to `major.minor.patch`.
pub fn Semver::to_string(self : Semver) -> String {
  "\{self.major}.\{self.minor}.\{self.patch}"
}
