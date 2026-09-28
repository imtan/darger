import std/unicode
import ../src/[review, buffer]

proc check(original, proposed: string, count: int) =
  var r = newReview(original, proposed)
  doAssert r.hunks.len == count
  doAssert r.appliedText() == original
  for decision in r.decisions.mitems: decision = accepted
  doAssert r.appliedText() == proposed
  for decision in r.decisions.mitems: decision = rejected
  doAssert r.appliedText() == original

block changes:
  check("", "a\nb\n", 1)
  check("a\n", "a\nb\n", 1)
  check("a\nb\n", "", 1)
  check("a\nb\n", "a\n", 1)
  check("a\nb\nc\n", "a\nB\nc\n", 1)
  check("a\nb", "a\nB", 1)
  check("a\n", "a", 1)
  check("a", "a\n", 1)
  check("", "", 0)
  check("a\n", "a\n", 0)
  check("\n\n", "\n", 1)
  check("日本語\n末尾", "日本語\n変更", 1)

block partial:
  var r = newReview("a\nb\nc\nd\ne", "A\nb\nC\nd\nE")
  doAssert r.hunks.len == 3
  r.decisions[0] = accepted
  r.decisions[1] = rejected
  doAssert r.appliedText() == "A\nb\nc\nd\ne"
  r.decisions[2] = accepted
  doAssert r.appliedText() == "A\nb\nc\nd\nE"
  let view = r.view(1)
  doAssert view.text == "+A\nb\n-c\nd\n+E"
  doAssert view.colors == @[2'i8, 0, 3, 0, 2]
  doAssert view.starts == @[0, 2, 4]

block display:
  var r = newReview("a\nb\nc", "a\nB\nc")
  doAssert r.view(0).text == "a\n-b\n+B\nc"
  doAssert r.view(0).colors == @[0'i8, 3, 4, 0]
  r.decisions[0] = accepted
  doAssert r.view(0).text == "a\n+B\nc"
  r.decisions[0] = rejected
  doAssert r.view(0).text == "a\n-b\nc"
  var deletion = newReview("a", "")
  deletion.decisions[0] = accepted
  doAssert deletion.view(0).text == ""
  doAssert deletion.view(0).starts == @[0]
  var insertion = newReview("", "b")
  insertion.decisions[0] = rejected
  doAssert insertion.view(0).text == ""

block undo:
  let b = newBuffer("a\n日本語\nz")
  b.cursor = (1, 1)
  var r = newReview(b.text, "a\n変更\nz")
  r.decisions[0] = accepted
  let text = r.appliedText()
  doAssert b.text == "a\n日本語\nz"
  b.snapshot()
  b.splice(0, b.text.runeLen, text)
  b.finish()
  doAssert b.modified and b.text == "a\n変更\nz"
  discard b.command("undo")
  doAssert b.text == "a\n日本語\nz" and b.cursor == (1, 1) and not b.modified

echo "All review checks passed"
