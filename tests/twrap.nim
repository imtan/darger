import std/[strutils, unicode]
import ../src/[wrap, buffer]

proc fits(text: string, width: int) =
  for line in text.split('\n'):
    var cells = 0
    for r in line.runes: cells += runeWidth(r)
    doAssert cells <= width, line

proc kinsoku(text: string) =
  for line in text.split('\n'):
    let rs = strutils.strip(line).toRunes
    if rs.len > 0:
      doAssert rs[0] notin "、。」』）】".toRunes, line
      doAssert rs[^1] notin "「『（【".toRunes, line

doAssert wrapText("short  line\n\nlast\n", 20) == "short  line\n\nlast\n"
doAssert wrapText("one two three four", 9) == "one two\nthree\nfour"
doAssert wrapText("abcdefghij", 4) == "abcd\nefgh\nij"
doAssert wrapText("日本語の文章です", 8) == "日本語の\n文章です"
doAssert wrapText("- one two three four", 11) == "- one two\n  three\n  four"
doAssert wrapText("* 日本語の文章です", 10) == "* 日本語の\n  文章です"
doAssert wrapText("12. one two three", 11) == "12. one two\n    three"
doAssert wrapText("one two\n\nthree four\n", 5) == "one\ntwo\n\nthree\nfour\n"
doAssert wrapText("", 5) == ""
doAssert wrapText("   \n\n", 2) == "   \n\n"
doAssert wrapText("日本語", 0) == "日本語"
doAssert wrapText("e\u0301e\u0301e\u0301", 2) == "e\u0301e\u0301\ne\u0301"
for text in ["Englishと日本語 mixed textです。次の文です。", "あいう、えお。かきく。",
    "あい「うえ」おか", "あい『うえ』おか", "あい（うえ）おか", "あい【うえ】おか",
    "- あいうえお、かきくけこ。", "1. 日本語とLatin wordsを混ぜます。"]:
  for width in 8..20:
    let wrapped = wrapText(text, width)
    fits(wrapped, width)
    kinsoku(wrapped)
    doAssert wrapped.replace("\n", "").replace(" ", "") == text.replace(" ", "")
for punctuation in "、。」』）】".runes:
  let wrapped = wrapText("あいう" & $punctuation & "えお", 6)
  fits(wrapped, 6)
  kinsoku(wrapped)
for punctuation in "「『（【".runes:
  let wrapped = wrapText("あい" & $punctuation & "うえお", 6)
  fits(wrapped, 6)
  kinsoku(wrapped)
echo "wrap ok"
