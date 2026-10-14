import std/[unicode, tables, strutils, os, monotimes, times]
import ../src/skk

const dict = "かんじ /漢字/幹事/感じ/監事/官寺/寛治/莞爾/完爾/完治/換字/冠辞/完児/\n" &
  "おくr /送/\nかt /勝/買/\nかな /仮名;note/(concat \"a\\057b\")/\n"

proc engine(): Skk =
  result = newSkk(parseDictionary(dict))
  discard result.toggle()

proc press(s: Skk, c: char): SkkResult = s.feed(Rune(c.ord))

proc typeText(s: Skk, text: string): string =
  for r in text.runes: result.add s.feed(r).text

block romaji:
  for (roman, kana) in [("kya", "きゃ"), ("nn", "ん"), ("kanji", "かんじ"), ("xtu", "っ"),
      ("xtsu", "っ"), ("z/", "・"), ("z.", "…"), ("zh", "←"), ("z[", "『"), ("shi", "し"),
      ("chi", "ち"), ("tsu", "つ"), ("dhi", "でぃ"), ("thu", "てゅ"), ("fu", "ふ"),
      ("ja", "じゃ"), ("jyo", "じょ"), ("n'a", "んあ"), ("xya", "ゃ"), ("xwa", "ゎ"),
      ("kitte", "きって"), ("-~!?:[]", "ー〜！？：「」"), ("wo", "を"), ("va", "ゔぁ")]:
    let s = engine()
    doAssert s.typeText(roman) == kana and s.pending == "", roman
  let s = engine()
  doAssert s.typeText("kk") == "っ" and s.preedit == "k"
  doAssert s.feed(skCtrlG).consumed and s.preedit == ""
  doAssert s.typeText("nk") == "ん" and s.preedit == "k"
  doAssert s.feed(skBackspace).consumed and s.pending == ""
  let paren = s.press('(')
  doAssert paren.text == "（）" and paren.move == -1 and paren.consumed
  let close = s.feed(Rune(')'.ord), "）".runeAt(0))
  doAssert close.text == "" and close.move == 1
  doAssert s.press(')').text == "）"
  for c in ".,1 /":
    let r = s.press(c)
    doAssert not r.consumed and r.text == "", $c
  doAssert not s.feed(skSpace).consumed and not s.feed(skEnter).consumed
  doAssert not s.feed(skBackspace).consumed and not s.feed(skCtrlG).consumed
  discard s.typeText("n")
  let enter = s.feed(skEnter)
  doAssert enter.text == "ん" and not enter.consumed

block conversion:
  let s = engine()
  doAssert s.typeText("Kanji") == "" and s.preedit == "▽かんじ"
  doAssert s.feed(skSpace).preedit == "▼漢字"
  doAssert s.feed(skSpace).preedit == "▼幹事"
  doAssert s.press('x').preedit == "▼漢字"
  let r = s.feed(skEnter)
  doAssert r.text == "漢字" and r.consumed and s.stage == Direct and r.preedit == ""
  discard s.typeText("Kanji")
  doAssert s.feed(skEnter).text == "かんじ" and s.stage == Direct  # no newline
  discard s.typeText("Kanji")
  discard s.feed(skSpace)
  doAssert s.press('a').text == "漢字あ"  # other key: kakutei, then the key
  discard s.typeText("Kanji")
  discard s.feed(skSpace)
  discard s.press('x')
  doAssert s.stage == Reading and s.preedit == "▽かんじ"

block listMode:
  let s = engine()
  discard s.typeText("Kanji")
  var r: SkkResult
  for i in 1..5: r = s.feed(skSpace)  # convert + 4 more = 5th candidate
  doAssert s.index == 4 and r.preedit == "▼官寺"
  doAssert r.echo == "▶A:官寺 S:寛治 D:莞爾 F:完爾 J:完治 K:換字 L:冠辞  [残り 1]", r.echo
  doAssert s.feed(skSpace).echo == "▶A:完児  [残り 0]"
  let past = s.feed(skSpace)  # past the last candidate: registration, as in DDSKK
  doAssert past.register == "かんじ" and s.stage == Direct and past.preedit == ""
  s.cancelRegister()
  doAssert s.stage == Reading and s.preedit == "▽かんじ"
  for i in 1..6: discard s.feed(skSpace)
  doAssert s.index == 11
  doAssert s.press('x').echo.startsWith("▶A:官寺")
  doAssert s.press('u').text == "" and s.stage == Choosing
  doAssert s.press('x').preedit == "▼監事" and s.page == ""
  discard s.feed(skSpace)
  let pick = s.press('d')
  doAssert pick.text == "莞爾" and pick.echo == "" and s.stage == Direct

block stepping:  # C-n / C-p (and the arrows) move one candidate at a time
  let s = engine()
  discard s.typeText("Kanji")
  discard s.feed(skSpace)
  doAssert s.feed(skNext).preedit == "▼幹事"
  doAssert s.feed(skPrev).preedit == "▼漢字"
  doAssert s.feed(skPrev).preedit == "▽かんじ" and s.stage == Reading  # before the first: back to ▽
  discard s.feed(skSpace)
  for i in 1..4: discard s.feed(skNext)
  var r = s.feed(skNext)  # the 6th candidate: on the first page, selected marked
  doAssert s.index == 5 and r.preedit == "▼寛治"
  doAssert r.echo == "A:官寺 ▶S:寛治 D:莞爾 F:完爾 J:完治 K:換字 L:冠辞  [残り 1]", r.echo
  doAssert s.pageItems.selected == 1 and s.pageItems.keys == @["a", "s", "d", "f", "j", "k", "l"]
  doAssert s.press('f').text == "完爾"  # pick keys count from the page start, not the selection
  let t = engine()  # (s has learnt 完爾, which reorders its candidates)
  discard t.typeText("Kanji")
  discard t.feed(skSpace)
  for i in 1..11: discard t.feed(skNext)
  doAssert t.index == 11 and t.feed(skNext).echo == "No more candidates" and t.index == 11
  doAssert t.feed(skPrev).echo.startsWith("A:官寺")  # back onto the first page
  doAssert t.feed(skEnter).text == "冠辞"
  # outside ▼ the keys are not consumed: pending romaji is flushed, a ▽ reading committed
  doAssert s.typeText("n") == "" and s.feed(skNext).text == "ん"
  discard s.typeText("Kanji")
  let moved = s.feed(skPrev)
  doAssert moved.text == "かんじ" and not moved.consumed and s.stage == Direct

block registration:  # a reading without candidates asks for the word
  let s = engine()
  discard s.typeText("Nai")
  let r = s.feed(skSpace)
  doAssert r.register == "ない" and s.stage == Direct and r.preedit == "" and r.echo == ""
  doAssert s.registerWord("無い") == "無い" and s.user["ない"] == @["無い"]
  discard s.typeText("Nai")
  doAssert s.feed(skSpace).preedit == "▼無い"
  discard s.feed(skCtrlG); discard s.feed(skCtrlG)
  discard s.typeText("ToB")  # okuri-ari: converted as soon as the okurigana completes
  let o = s.press('u')
  doAssert o.register == "と*ぶ", o.register
  doAssert s.registerWord("飛") == "飛ぶ" and s.user.hasKey("とb")
  let empty = newSkk()
  discard empty.toggle()
  discard empty.typeText("Kanji")
  doAssert empty.feed(skSpace).echo == "No dictionary" and empty.stage == Reading

block commit:  # kakutei before another editor command
  let s = engine()
  discard s.typeText("Kanji")
  discard s.feed(skSpace)
  doAssert s.composing
  doAssert s.commit().text == "漢字" and s.stage == Direct and s.enabled and not s.composing
  discard s.typeText("k")
  doAssert s.composing and s.commit().text == "" and s.pending == ""

block okuri:
  let s = engine()
  discard s.typeText("OkuR")
  doAssert s.preedit == "▽おく*r"
  doAssert s.press('i').preedit == "▼送り"
  doAssert s.feed(skCtrlJ).text == "送り"
  doAssert s.user.hasKey("おくr") and not s.user.hasKey("おく")
  discard s.typeText("KaTt")
  doAssert s.preedit == "▽か*っt"
  doAssert s.press('a').preedit == "▼勝った"
  discard s.feed(skCtrlG)
  doAssert s.stage == Reading
  discard s.feed(skCtrlG)
  doAssert s.preedit == ""

block backspace:
  let s = engine()
  discard s.typeText("Kanji")
  discard s.feed(skSpace)
  doAssert s.feed(skBackspace).preedit == "▽かんじ" and s.reading == "かんじ"
  doAssert s.feed(skBackspace).preedit == "▽かん"
  discard s.feed(skBackspace)
  discard s.feed(skBackspace)
  doAssert s.preedit == "▽" and s.stage == Reading
  doAssert s.feed(skBackspace).preedit == "" and s.stage == Direct

block learning:
  let s = engine()
  discard s.typeText("Kanji")
  discard s.feed(skSpace)
  discard s.feed(skSpace)
  doAssert s.feed(skEnter).text == "幹事"
  discard s.typeText(";kanji")  # sticky shift behaves like "Kanji"
  doAssert s.preedit == "▽かんじ" and s.feed(skSpace).preedit == "▼幹事"
  doAssert s.feed(skSpace).preedit == "▼漢字"
  discard s.feed(skEnter)
  doAssert s.user["かんじ"] == @["漢字", "幹事"]
  discard s.typeText("OkuRi")
  discard s.feed(skEnter)
  let text = serializeDictionary(s.user)
  doAssert text == ";; okuri-ari entries.\nおくr /送/\n;; okuri-nasi entries.\nかんじ /漢字/幹事/\n"
  doAssert parseDictionary(text) == s.user
  let path = getTempDir() / "tskk-user-jisyo"
  removeFile(path)
  let u = newSkk(parseDictionary(dict))
  u.loadUserDictionary(path)
  doAssert u.user.len == 0 and u.userPath == path
  discard u.toggle()
  discard u.typeText("Kanji")
  discard u.feed(skSpace)
  discard u.feed(skSpace)
  discard u.feed(skEnter)
  doAssert readFile(path) == ";; okuri-ari entries.\n;; okuri-nasi entries.\nかんじ /幹事/\n"
  removeFile(path)

block modes:
  let s = engine()
  doAssert s.tag == "[かな]"
  discard s.typeText("Kanji")
  doAssert s.press('q').text == "カンジ"
  doAssert s.press('q').tag == "[カナ]"
  doAssert s.typeText("kya-") == "キャー"
  discard s.typeText("Kanji")
  doAssert s.preedit == "▽カンジ" and s.feed(skSpace).preedit == "▼漢字"
  discard s.feed(skCtrlG)
  doAssert s.press('q').text == "かんじ" and s.mode == Katakana
  doAssert s.press('q').tag == "[かな]"
  doAssert s.press('l').tag == "[SKK]" and not s.press('a').consumed
  doAssert not s.feed(skSpace).consumed
  doAssert s.feed(skCtrlJ).consumed and s.mode == Hiragana
  discard s.typeText("Kanji")
  let off = s.toggle()  # C-x C-j lives in the editor; turning off commits
  doAssert off.text == "かんじ" and off.tag == "" and not s.enabled
  doAssert not s.press('a').consumed and not s.feed(skCtrlJ).consumed
  doAssert s.toggle().tag == "[かな]" and s.enabled

block noDictionary:
  let s = newSkk()
  discard s.toggle()
  discard s.typeText("Kanji")
  doAssert s.feed(skSpace).echo == "No dictionary" and s.stage == Reading
  doAssert s.feed(skCtrlG).preedit == ""
  doAssert s.typeText("kana") == "かな"
  let t = engine()
  discard t.typeText("Hoge")
  let none = t.feed(skSpace)  # no candidates: the editor is asked to register the word
  doAssert none.register == "ほげ" and none.echo == "" and t.preedit == ""
  t.cancelRegister()
  doAssert t.preedit == "▽ほげ"

doAssert parseDictionary(dict)["かな"] == @["仮名", "(concat \"a\\057b\")"]
doAssert decodeDictionary("かな /仮名/\n") == "かな /仮名/\n"

block realDictionary:
  let path = defaultDictionaryPath()
  if fileExists(path):
    let s = newSkk()
    let started = getMonoTime()
    s.loadDictionary(path)
    echo "SKK-JISYO: ", s.dictionary.len, " entries, ",
      (getMonoTime() - started).inMilliseconds, " ms"
    doAssert s.dictionary.len > 100_000 and s.lookup("かんじ")[0] == "漢字"
    doAssert s.lookup("おく", "r")[0] == "送"

echo "All SKK checks passed"
