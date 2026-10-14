///|
fn resolved(vars : Array[(String, String)]) -> @i18n.Lang {
  @i18n.resolve(Map(vars))
}

///|
/// `BM2_LANG` 压过系统 locale:临时切语言时不该被环境拦住。
test "BM2_LANG wins over the locale" {
  assert_eq(
    resolved([("BM2_LANG", "zh"), ("LANG", "en_US.UTF-8")]),
    @i18n.Lang::Zh,
  )
  assert_eq(
    resolved([("BM2_LANG", "en"), ("LANG", "zh_CN.UTF-8")]),
    @i18n.Lang::En,
  )
}

///|
/// POSIX 里 `LC_ALL` 压 `LANG`。
test "LC_ALL outranks LANG" {
  assert_eq(
    resolved([("LC_ALL", "zh_CN.UTF-8"), ("LANG", "en_US.UTF-8")]),
    @i18n.Lang::Zh,
  )
  assert_eq(
    resolved([("LC_ALL", "en_US.UTF-8"), ("LANG", "zh_CN.UTF-8")]),
    @i18n.Lang::En,
  )
}

///|
/// locale 里只有语言那一段算数。
test "only the language part of a locale matters" {
  assert_eq(resolved([("LANG", "zh")]), @i18n.Lang::Zh)
  assert_eq(resolved([("LANG", "zh_CN.UTF-8")]), @i18n.Lang::Zh)
  assert_eq(resolved([("LANG", "zh-Hans")]), @i18n.Lang::Zh)
  assert_eq(resolved([("LANG", "ZH_CN")]), @i18n.Lang::Zh)
}

///|
/// 不说的语言一律英文,空环境也一样——一个语言总比半屏中文半屏英文清楚。
test "anything bm2 does not speak is English" {
  assert_eq(resolved([]), @i18n.Lang::En)
  assert_eq(resolved([("LANG", "C")]), @i18n.Lang::En)
  assert_eq(resolved([("LANG", "POSIX")]), @i18n.Lang::En)
  assert_eq(resolved([("LANG", "en_US.UTF-8")]), @i18n.Lang::En)
  assert_eq(resolved([("LANG", "ja_JP.UTF-8")]), @i18n.Lang::En)
}

///|
/// 设了但是空的变量等于没设。
test "an empty variable is not a choice" {
  assert_eq(
    resolved([("BM2_LANG", ""), ("LANG", "zh_CN.UTF-8")]),
    @i18n.Lang::Zh,
  )
  assert_eq(
    resolved([("BM2_LANG", ""), ("LC_ALL", ""), ("LANG", "")]),
    @i18n.Lang::En,
  )
}

///|
/// The list and the name table cannot drift: every language that is listed has to
/// read back under the name it lists itself with, and `of_request` — which is what a
/// caller over the socket goes through — has to agree with both. The count assertion
/// is the speed bump: a new variant has to be added here too, which is where
/// `languages()` gets looked at.
test "the language list and the name table agree" {
  let listed = @i18n.languages()
  assert_eq(listed.length(), 2)
  for lang in listed {
    let name = lang.name()
    match @i18n.Lang::from_name(name) {
      Some(back) =>
        if back != lang {
          fail("a listed language reads back as another one: " + name)
        }
      None => fail("a language bm2 lists cannot be read back: " + name)
    }
    assert_true(@i18n.of_request(Some(name)) == lang)
    // The environment path reads the language subtag out of whatever the shell has,
    // so every language has to be recognised under its own name and inside a locale
    // — `zh` and `zh_CN.UTF-8` are the same answer.
    assert_true(@i18n.resolve(Map([("LANG", name)])) == lang)
    assert_true(@i18n.resolve(Map([("LANG", name + "_XX.UTF-8")])) == lang)
  }
}
