import std/[unicode, strutils]
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

block refine:
  doAssert changedSpan("line one".toRunes, "line two".toRunes) == (5 ..< 8, 5 ..< 8)
  doAssert changedSpan("abc".toRunes, "abXc".toRunes) == (2 ..< 2, 2 ..< 3)      # pure insertion: empty on the left
  doAssert changedSpan("same".toRunes, "same".toRunes) == (4 ..< 4, 4 ..< 4)
  doAssert changedSpan("日本語の文".toRunes, "日本の文".toRunes) == (2 ..< 3, 2 ..< 2)
  var r = newReview("keep\nline one\nline two\n", "keep\nline ONE\nline two\nadded\n")
  doAssert r.hunks.len == 2 and r.stats(0) == (1, 1) and r.stats(1) == (0, 1)
  doAssert r.hunkLabel(0) == "1  -1 +1  line ONE" and r.hunkLabel(1) == "2  -0 +1  added"
  let v = r.view(0)
  doAssert v.text.splitLines()[1] == "-line one" and v.text.splitLines()[2] == "+line ONE"
  doAssert v.bgs[1] == @[0'i8, 0, 0, 0, 0, 0, 11, 11, 11] and v.bgs[2] == @[0'i8, 0, 0, 0, 0, 0, 12, 12, 12]  # "one" / "ONE", current hunk
  doAssert v.bgs[3].len == 0                   # "added" has no partner
  let w = r.view(1)
  doAssert w.bgs[1][6] == 9 and w.bgs[2][6] == 10  # not the current hunk
  r.decisions[0] = accepted
  doAssert r.view(0).bgs[1].len == 0 and r.hunkLabel(0).endsWith("[taken]  line ONE")

block texts:
  let r = newReview("keep\nline one\nline two\n", "keep\nline ONE\nline two\nadded\n")
  doAssert r.proposedText() == "keep\nline ONE\nline two\nadded\n"
  doAssert r.hunkText(0) == ("line one\n", "line ONE\n") and r.hunkText(1) == ("", "added\n")

block editHunk:
  var r = newReview("a\nb\nc\nd\ne\n", "A\nb\nC\nd\nE\n")
  r.decisions[0] = accepted
  r.decisions[2] = rejected
  let edited = r.withHunk(1, "new\nlines\n")
  doAssert edited.proposedText() == "A\nb\nnew\nlines\nd\nE\n"
  doAssert edited.appliedText() == "a\nb\nc\nd\ne\n"
  doAssert edited.hunks.len == 3
  doAssert edited.decisions == @[pending, pending, pending]
  doAssert r.proposedText() == "A\nb\nC\nd\nE\n"
  doAssert r.decisions == @[accepted, pending, rejected]
  doAssert newReview("a\nb\nc\n", "A\nB\nC\n").withHunk(0, "A\nb\nC").hunks.len == 2
  doAssert r.withHunk(1, "c").hunks.len == 2
  doAssert r.withHunk(1, "").proposedText() == "A\nb\nd\nE\n"
  doAssert r.withHunk(1, "").hunks.len == 3
  doAssert newReview("a\n", "a\nadded\n").withHunk(0, "").hunks.len == 0
  doAssert newReview("a\nb\nc\n", "a\nc\n").withHunk(0, "b").hunks.len == 0
  doAssert newReview("a\n", "A").withHunk(0, "B").proposedText() == "B\n"
  doAssert newReview("a", "A\n").withHunk(0, "B").proposedText() == "B\n"
  doAssert newReview("a", "A").withHunk(0, "B").proposedText() == "B"
  doAssert newReview("a\r\n", "A\r\n").withHunk(0, "B").proposedText() == "B\r\n"
  doAssert newReview("", "A\n").withHunk(0, "B\n").proposedText() == "B\n"
  doAssert newReview("日本語\n", "変更\n").withHunk(0, "編集").proposedText() == "編集\n"
  echo "Hunk edit checks passed"

block sides:
  var r = newReview("head\nold one\nold two\nmiddle\nlast\ntail\n",
                    "head\nnew one\nmiddle\nnew last\nextra\ntail\n")
  let v = r.sideBySide(1)
  doAssert v.left.text == "head\nold one\nold two\nmiddle\nlast\n\ntail"
  doAssert v.right.text == "head\nnew one\n\nmiddle\nnew last\nextra\ntail"
  doAssert v.left.starts == @[1, 4] and v.right.starts == v.left.starts
  doAssert v.left.colors == @[0'i8, 1, 1, 0, 3, 0, 0]
  doAssert v.right.colors == @[0'i8, 2, 0, 0, 4, 4, 0]
  doAssert v.left.bgs[1] == @[9'i8, 9, 9, 0, 0, 0, 0]
  doAssert v.right.bgs[1] == @[10'i8, 10, 10, 0, 0, 0, 0]
  doAssert v.right.bgs[4] == @[12'i8, 12, 12, 12, 0, 0, 0, 0]
  doAssert v.left.bgs[5].len == 0 and v.right.bgs[5].len == 0
  r.decisions[0] = accepted
  r.decisions[1] = rejected
  let decided = r.sideBySide(0)
  doAssert decided.left.colors == @[0'i8, 0, 0, 0, 1, 0, 0]
  doAssert decided.right.colors == @[0'i8, 4, 0, 0, 0, 0, 0]
  doAssert decided.left.starts == v.left.starts
  doAssert decided.left.bgs[1].len == 0 and decided.right.bgs[1].len == 0
  let inserted = newReview("", "a\nb\n").sideBySide(0)
  doAssert inserted.left.text == "\n" and inserted.right.text == "a\nb"
  doAssert inserted.left.colors == @[0'i8, 0] and inserted.right.colors == @[4'i8, 4]
  let deleted = newReview("a\nb", "").sideBySide(0)
  doAssert deleted.left.text == "a\nb" and deleted.right.text == "\n"
  doAssert deleted.left.colors == @[3'i8, 3] and deleted.right.colors == @[0'i8, 0]
  let unicode = newReview("日本語の文\r\n", "日本の文\r\n").sideBySide(0)
  doAssert unicode.left.bgs[0] == @[0'i8, 0, 11, 0, 0]
  doAssert unicode.right.bgs[0] == @[0'i8, 0, 0, 0]
  let ending = newReview("a\n", "a").sideBySide(0)
  doAssert ending.left.text == "a" and ending.right.text == "a"
  doAssert ending.left.bgs[0].len == 0
  doAssert newReview("", "").sideBySide(0).left.starts.len == 0
  let same = newReview("same\n", "same\n").sideBySide(0)
  doAssert same.left.text == "same" and same.right.colors == @[0'i8]
  echo "Side-by-side review checks passed"

echo "All review checks passed"
