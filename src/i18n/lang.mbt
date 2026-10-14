///|
/// Human-facing copy, in the languages bm2 speaks.
///
/// The scope is deliberately narrow: help, command output, errors and
/// notifications — what a person reads. Machine-read surfaces are not spelled
/// here. Event logs and state files keep language-neutral keys, because alerting
/// rules, scripts and the notification pipeline read those values by name, and
/// translating them would turn a machine interface into prose.
///
/// A message is a function, not a key in a table: `match` on the language makes a
/// missing translation a compile error instead of a silent fallback to English,
/// and leaves no key namespace to drift out of sync.

///|
/// The languages bm2 speaks. `En` is the default, it is what an unset locale
/// resolves to, and it is the language the tests assert.
pub(all) enum Lang {
  En
  Zh
} derive(Eq, Debug)

///|
pub extend Lang with Debug::{to_repr}

///|
pub extend Lang with Eq::{not_equal, equal}

///|
/// Resolve the language from an environment, in the order an operator overrides
/// it: an explicit `BM2_LANG` first, then the POSIX locale (`LC_ALL` outranks
/// `LANG`), then English.
///
/// Only the language part of a locale is read, so `zh`, `zh_CN.UTF-8`, `zh-Hans`
/// and `ZH_CN` all mean Chinese. `C`, `POSIX` and every language bm2 does not
/// speak mean English — the same answer an empty environment gives, because a
/// half-translated screen is worse than one clear language.
pub fn resolve(vars : Map[String, String]) -> Lang {
  match first_present(vars, ["BM2_LANG", "LC_ALL", "LANG"]) {
    Some(value) => lang_of(value)
    None => En
  }
}

///|
/// `resolve` against this process's own environment. Called once at the edge of
/// a program: the CLI resolves it, puts it in the request, and the daemon renders
/// its answer in that language, so one screen never shows two.
pub fn resolve_env() -> Lang {
  resolve(@env.get_env_vars())
}

///|
/// The first of these variables that is actually set to something. An empty
/// variable is not a choice, it is a shell that exported nothing.
fn first_present(vars : Map[String, String], names : Array[String]) -> String? {
  for name in names {
    match vars.get(name) {
      Some(value) if value.length() > 0 => return Some(value)
      _ => ()
    }
  }
  None
}

///|
/// The language a locale names, read from its first two characters. A locale is
/// `language[_territory][.charset][@modifier]`, so `zh_CN.UTF-8` is Chinese and
/// nothing after the underscore matters.
fn lang_of(value : String) -> Lang {
  if value.length() >= 2 {
    let first = value[0]
    let second = value[1]
    let letter_z = first == 'z' || first == 'Z'
    let letter_h = second == 'h' || second == 'H'
    if letter_z && letter_h {
      return Zh
    }
  }
  En
}

///|
/// The name of a language as configuration writes it: `en`, `zh`. These names are
/// the contract with `bm2.toml`, so they are spelled exactly once, here, and
/// everything that validates or renders them goes through this pair.
pub fn Lang::name(self : Lang) -> String {
  match self {
    En => "en"
    Zh => "zh"
  }
}

///|
/// A language read back from configuration. None means the name is not one bm2
/// speaks, and the caller decides what that costs — a config that names an
/// unknown language is refused, never quietly downgraded.
pub fn Lang::from_name(name : String) -> Lang? {
  match name {
    "en" => Some(En)
    "zh" => Some(Zh)
    _ => None
  }
}

///|
/// Every language this build speaks, in the order they are listed to a person.
///
/// This is the only list. `name` and `from_name` answer for one language, and the
/// tests hold the three together: every language listed here has to read back under
/// the name it gives, so a variant added to the enum but forgotten here, or a name
/// added to one table and not the other, fails the build's tests rather than
/// silently dropping a language.
///
/// Adding a language is still a deliberate walk: the enum gains a variant, `name`
/// and this list gain an entry, and every message function stops compiling until it
/// answers in the new language.
pub fn languages() -> Array[Lang] {
  [En, Zh]
}

///|
/// The language a request asks for, or English. Absent and unrecognised are the
/// same answer on purpose: the request came over a socket, so a name in it cannot
/// be trusted to be one of ours, and the worst case is the default language rather
/// than a failed command.
pub fn of_request(name : String?) -> Lang {
  match name {
    Some(value) => Lang::from_name(value).unwrap_or(En)
    None => En
  }
}
