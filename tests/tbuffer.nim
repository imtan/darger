import std/[unicode, os]
import ../src/buffer

proc run(b: Buffer, commands: varargs[string]) =
  for command in commands: discard b.command(command)

block:
  let b = newBuffer()
  b.insert("é界")
  doAssert b.cursor == (0, 2)
  b.run("newline")
  b.insert("x")
  b.run("backspace", "backspace")
  doAssert b.text == "é界"
  b.run("backward", "delete")
  doAssert b.text == "é"
block:
  let b = newBuffer("abc\ndef")
  b.run("kill-line", "kill-line")
  doAssert b.text == "def" and b.kills == @["abc\n"]
  b.run("kill-line", "yank")
  doAssert b.text == "abc\ndef"
block:
  let b = newBuffer("one, two\nthree")
  b.run("forward-word")
  doAssert b.cursor == (0, 3)
  b.run("forward-word", "backward-word")
  doAssert b.cursor == (0, 5)
  b.run("mark", "forward-word", "kill-region")
  doAssert b.text == "one, \nthree" and b.kills[0] == "two"
  b.run("yank")
  doAssert b.text == "one, two\nthree"
  b.kills.add "FOUR"
  b.run("yank-pop")
  doAssert b.text == "one, FOUR\nthree"
  doAssert b.kills == @["two", "FOUR"]
  b.run("backward")
  doAssert b.command("yank-pop") == "Previous command was not a yank"
block: # Backspace/Delete remove an active region without killing it.
  let b = newBuffer("one two three")
  b.run("forward-word", "forward", "mark", "forward-word", "backspace")
  doAssert b.text == "one  three" and b.cursor == (0, 4) and not b.regionActive and b.kills.len == 0
  b.run("mark", "backward-word", "delete")
  doAssert b.text == " three" and b.cursor == (0, 0)
  b.run("undo")
  doAssert b.text == "one  three"
  b.run("mark", "mark", "eol", "backspace")  # deactivated mark: plain one-character backspace
  doAssert b.text == "one  thre"
block:
  let b = newBuffer()
  for c in "abc": b.insert($c, true)
  b.insert(" ", true)
  for c in "def": b.insert($c, true)
  b.run("undo")
  doAssert b.text == "abc "
  b.run("undo")
  doAssert b.text == "abc"
  b.run("undo")
  doAssert b.text == "" and not b.modified
  b.insert("a", true)
  b.run("bol", "eol")
  b.insert("b", true)
  b.run("undo")
  doAssert b.text == "a"
block:
  let b = newBuffer("abcdef\nx\nabcdef")
  b.cursor = (0, 5)
  b.run("next-line")
  doAssert b.cursor == (1, 1)
  b.run("next-line")
  doAssert b.cursor == (2, 5)
  b.run("previous-line", "previous-line")
  doAssert b.cursor == (0, 5)
  b.run("transpose")
  doAssert b.text == "abcdfe\nx\nabcdef"
  b.run("eol", "transpose")
  doAssert b.lines[0] == "abcdef".toRunes
block:
  let b = newBuffer("one ONE one")
  doAssert b.findMatch("one", 0, 1) == 0
  doAssert b.findMatch("one", 1, 1) == 4
  doAssert b.findMatch("one", 9, 1, true) == 0
  doAssert b.findMatch("one", -1, -1, true) == 8
  doAssert b.findMatch("one", 7, -1) == 4
  doAssert b.findMatch("ONE", 0, 1) == 4
  doAssert b.findMatch("One", 0, 1) == -1
block:
  createDir("nimcache")
  let path = absolutePath("nimcache/crlf-test.txt")
  writeFile(path, "é\r\nx\r\n")
  let b = loadBuffer(path)
  doAssert b.crlf and b.text == "é\nx\n"
  b.insert("!")
  b.save()
  doAssert readFile(path) == "!é\r\nx\r\n" and not b.modified
  let fresh = loadBuffer("nimcache/not-created.txt")
  doAssert fresh.text == "" and fresh.path.len > 0
block:
  let b = newBuffer("\t界x\n012345678901234")
  b.cursor = (0, 2)
  doAssert b.cellCol(b.cursor) == 10
  b.run("next-line")
  doAssert b.cursor == (1, 10)
  b.run("previous-line", "tab")
  doAssert b.lines[0] == "\t界  x".toRunes
block:
  let b = newBuffer("a b c")
  b.run("eob", "backward-kill-word", "backward-kill-word")
  doAssert b.kills == @["b c"] and b.text == "a "
  b.run("yank", "undo", "undo")
  doAssert b.text == "a b "
  b.run("bob", "mark", "forward", "copy-region")
  doAssert b.kills[0] == "a" and b.text == "a b "
block:
  let b = newBuffer("  hello WORLD")
  b.run("indent", "upcase", "downcase")
  doAssert b.text == "  HELLO world"
  b.run("bob", "capitalize")
  doAssert b.text == "  Hello world"
  b.run("open-line")
  doAssert b.text == "  Hello\n world" and b.cursor == (0, 7)
block:
  let b = newBuffer()
  for i in 0..<205: b.insert("x")
  for i in 0..<200: b.run("undo")
  doAssert b.text == "xxxxx" and b.command("undo") == "No further undo information"
  for i in 0..<65:
    b.insert("x")
    b.run("backward-kill-word")
  doAssert b.kills.len == 60
block:
  for (code, width) in [(0x61, 1), (0x3042, 2), (0x1F600, 2),
                        (0x0301, 0), (0xFE0F, 0), (0x200D, 0),
                        (0x1F3FB, 0), (0xE0100, 0), (0x2600, 1)]:
    doAssert runeWidth(Rune(code)) == width
  let line = "aあb😀c".toRunes
  for col, cell in [0, 1, 3, 4, 6, 7]:
    doAssert cellCol(line, col) == cell
    doAssert runeCol(line, cell) == col
  doAssert runeCol(line, 2) == 1 and runeCol(line, 5) == 3
  let marked = "e\u0301x".toRunes
  doAssert cellCol(marked, 2) == 1 and runeCol(marked, 1) == 2
  doAssert cellCol("\tあ".toRunes, 2) == 10
block: # #8: failed yank-pop must never authorize another yank-pop.
  let b = newBuffer("hello world")
  b.cursor.col = 5
  b.run("kill-line", "yank", "bob", "kill-line", "yank-pop", "yank-pop")
  doAssert b.text == "" and b.last != "yank-pop"
block: # #6: undo retains a distinct mark.
  let b = newBuffer("hello world")
  b.run("mark", "eol")
  b.insert("!")
  b.run("undo", "exchange")
  doAssert b.cursor == (0, 0) and b.mark == (0, 11)
block: # #3: the BOM remains a file prefix, never an editable rune.
  let path = "nimcache/bom-test.txt"
  writeFile(path, "\xEF\xBB\xBFhello\r\n")
  let b = loadBuffer(path)
  b.insert("x")
  b.save()
  doAssert b.bom and readFile(path) == "\xEF\xBB\xBFxhello\r\n"
block: # #1/#9: extending a repeated match stays there; DEL pops state.
  let b = newBuffer("fox foo")
  var s = b.startSearch(1)
  b.searchStep(s, "f")
  b.searchStep(s, "f", true)
  b.searchStep(s, "fo")
  doAssert s.state.matchStart == 4 and b.cursor == (0, 6)
  b.searchBackspace(s)
  doAssert s.state.query == "f" and s.state.matchStart == 4
block: # #4/#10: fail first, wrap only on the repeat, at the far edge.
  let b = newBuffer("ab ab")
  b.run("eob")
  var s = b.startSearch(1)
  b.searchStep(s, "ab")
  doAssert s.state.failing and b.cursor == (0, 5)
  b.searchStep(s, "ab", true)
  doAssert s.state.wrapped and s.state.matchStart == 0
  doAssert b.findMatch("ab", -10, -1, true) == 3
block: # #5: forward/backward repeats skip overlaps.
  let b = newBuffer("aaaa")
  var s = b.startSearch(1)
  b.searchStep(s, "aa")
  b.searchStep(s, "aa", true)
  doAssert s.state.matchStart == 2
  b.run("eob")
  s = b.startSearch(-1)
  b.searchStep(s, "aa")
  b.searchStep(s, "aa", true)
  doAssert s.state.matchStart == 0
  b.searchStep(s, "aa", true, 1)
  doAssert s.state.matchStart == 0 and b.cursor == (0, 2)
block: # #22: a short temporary write cannot replace the destination.
  let path = "nimcache/atomic-test.txt"
  atomicWrite(path, "original")
  var failed = false
  try:
    atomicWrite(path, "replacement", proc(f: File, data: string) = checkedWrite(f, "x"))
  except IOError: failed = true
  doAssert failed and readFile(path) == "original"
  atomicWrite(path, "retry")
  doAssert readFile(path) == "retry"
block: # #24: failed replacement cleans its unique temp and permits retry.
  let path = "nimcache/readonly-test.txt"
  atomicWrite(path, "original")
  let permissions = getFilePermissions(path)
  var failed = false
  try:
    setFilePermissions(path, {fpUserRead})
    try: atomicWrite(path, "replacement")
    except IOError, OSError: failed = true
  finally: setFilePermissions(path, permissions)
  when defined(windows): doAssert failed and readFile(path) == "original"
  atomicWrite(path, "retry")
  doAssert readFile(path) == "retry"
block: # #25: directory targets are rejected before a temp is created.
  let b = newBuffer("unsaved")
  b.insert("x")
  var failed = false
  try: b.save("nimcache/")
  except IOError: failed = true
  doAssert failed and b.modified and b.path == ""
echo "All buffer checks passed"
