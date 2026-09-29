import std/[os, strutils, tempfiles]
import ../src/complete

block matching:
  doAssert matches("", "anything")
  doAssert matches("buf nim", "src/buffer.nim")
  doAssert matches("NIM BUF", "src/buffer.nim")
  doAssert not matches("buf rs", "src/buffer.nim")
  doAssert matches("  find  ", "find-file")
  doAssert matches("日本", "にほん日本語")
  doAssert matches("ÄB", "xäbx")
  doAssert not matches("語 英", "日本語")

block filtering:
  let all = @["kill-buffer", "buffer-list", "switch-to-buffer", "bob", "Buffer-Menu"]
  doAssert filter("buf", all) == @["buffer-list", "Buffer-Menu", "kill-buffer", "switch-to-buffer"]
  doAssert filter("", all) == all
  doAssert filter("to buf", all) == @["switch-to-buffer"]
  doAssert filter("buf kill", all) == @["kill-buffer"]
  doAssert filter("xyz", all).len == 0
  doAssert filter("日本", @["英語", "語日本", "日本語"]) == @["日本語", "語日本"]
  # An exact name beats a longer one that also starts with it (C-x k foo kills foo).
  doAssert filter("foo", @["*scratch*", "foo.txt", "foo"]) == @["foo", "foo.txt"]
  doAssert filter(" FOO ", @["foo.txt", "Foo"]) == @["Foo", "foo.txt"]
  doAssert filter("foo txt", @["foo.txt", "foo"]) == @["foo.txt"]

block files:
  let dir = createTempDir("tcomplete-", "")
  createDir(dir / "sub")
  createDir(dir / ".git")
  writeFile(dir / "b.txt", "")
  writeFile(dir / "A.nim", "")
  writeFile(dir / ".hidden", "")
  let root = dir & "/"
  proc listed(input: string): tuple[dir: string, tail: string, items: seq[string]] =
    let (d, t) = splitInput(input)  # as darger's refreshCandidates lists them
    (d, t, listDir(d, t.startsWith(".")))
  var r = listed(root)
  doAssert r.dir == root and r.tail == ""
  doAssert r.items == @["A.nim", "b.txt", "sub/"], $r.items
  r = listed(root & "su")
  doAssert r.tail == "su" and r.items == @["A.nim", "b.txt", "sub/"]
  r = listed(root & ".h")
  doAssert r.tail == ".h" and r.items == @[".git/", ".hidden", "A.nim", "b.txt", "sub/"], $r.items
  doAssert filter(r.tail, r.items) == @[".hidden"]
  r = listed(root & "sub/")
  doAssert r.dir == root & "sub/" and r.items.len == 0
  r = listed(root & "missing/x")
  doAssert r.tail == "x" and r.items.len == 0
  r = listed("plain")
  doAssert r.dir == getCurrentDir() & DirSep and r.tail == "plain"
  # ~ is expanded where confirmMini expands it, so the listed file is the one opened.
  when defined(windows): doAssert splitInput("~/").dir == "~/"
  else: doAssert splitInput("~/").dir == getHomeDir()
  removeDir(dir)
echo "tcomplete ok"
