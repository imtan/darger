{.define: headless.}
import std/[os, osproc, tempfiles, strutils, unicode, tables, sets, streams]
import ../src/[magit, branchdiff, core, buffer, buffers, render, lisp, syntax]
import ../src/ext/[magit, agent]

let entries = parseStatus("?? new file\0 M changed\0M  staged\0MM both\0R  renamed\0old name\0RM newer\0older\0")
doAssert entries.len == 6
doAssert entries[0].untracked and not entries[0].staged and not entries[0].unstaged
doAssert entries[0].path == "new file"
doAssert entries[1].unstaged and not entries[1].staged
doAssert entries[2].staged and not entries[2].unstaged
doAssert entries[3].staged and entries[3].unstaged
doAssert entries[4].oldPath == "old name" and entries[4].path == "renamed"
doAssert entries[4].statusLabel(true) == "R old name -> renamed"
doAssert entries[5].staged and entries[5].unstaged
doAssert entries[5].statusLabel(false) == "M older -> newer"
doAssert parseStatus("").len == 0
doAssert parseStatus("R  incomplete\0").len == 0
let special = parseStatus("?? 日本語\nwith\ttab\0 D deleted\0 C copy\0original\0")
doAssert special.len == 3
doAssert special[0].path == "日本語\nwith\ttab"
doAssert special[0].statusLabel(false) == "? 日本語\\nwith\\ttab"
doAssert special[1].unstaged
doAssert special[2].oldPath == "original"
echo "magit ok"

block pure:
  let patch = "diff --git a/a b/a\nindex 123..456 100644\n--- a/a\n+++ b/a\n" &
    "@@ -1,2 +1,2 @@\n-old\r\n+new\r\n context\r\n" &
    "@@ -10 +10 @@\n-last\n+end\n\\ No newline at end of file\n"
  let patches = hunkPatches(patch)
  doAssert patches.len == 2 and "-old\r\n" in patches[0]
  doAssert "@@ -10" notin patches[0] and "@@ -1,2" notin patches[1]
  doAssert patches[1].endsWith("\\ No newline at end of file\n")
  let rows = fileRows(StatusEntry(path: "a"), secUnstaged, true, patch)
  doAssert rows[2].kind == dkRemoved and rows[2].newLine == 1
  doAssert rows[4].kind == dkContext and rows[4].newLine == 2
  doAssert rows[2].patch == patches[0] and rows[^1].patch == patches[1]
  var state: FoldState
  state.toggle(rows[0])
  doAssert rows[0].key in state.expanded
  doAssert (secStaged, "a") notin state.expanded
  state.toggle(rows[2])
  doAssert rows[0].key notin state.expanded
  let heading = Row(section: secUnstaged, heading: true)
  state.toggle(heading)
  doAssert secUnstaged in state.hidden
  state.toggleAll(@[rows[0].key])
  doAssert secUnstaged notin state.hidden and rows[0].key in state.expanded
  state.toggleAll(@[rows[0].key])
  doAssert rows[0].key notin state.expanded

let home = createTempDir("darger-magit-", "")
putEnv("HOME", home)
let repo = home / "repo"
createDir(repo)
proc git(args: string): string =
  let process = startProcess("git -C " & quoteShell(repo) & " -c commit.gpgsign=false " & args,
    options = {poUsePath, poEvalCommand, poStdErrToStdOut})
  try:
    process.inputStream.close()
    result = process.outputStream.readAll()
    doAssert process.waitForExit() == 0, result
  finally: process.close()
proc eval(s: string) = discard interp.evalString(s, "<magit-test>")
proc action(key: string) = discard interp.call(localKeys[b][key], @[])
proc lineStarting(s: string, start = 0): int =
  for i in start..<b.lines.len:
    if ($b.lines[i]).startsWith(s): return i
  doAssert false, "Missing: " & s & "\n" & b.text
proc fileLine(path: string, section = "Unstaged"): int =
  let start = lineStarting(section) + 1
  for i in start..<b.lines.len:
    let line = $b.lines[i]
    if line.len == 0: break
    if (line.startsWith("  ▸ ") or line.startsWith("  ▾ ")) and line.endsWith(path): return i
  doAssert false, "Missing file: " & path & " in " & section & "\n" & b.text
proc selectFile(path: string, section = "Unstaged") = b.cursor = (fileLine(path, section), 0)

renderer = Renderer(frameCols: 100, frameRows: 40)
layoutPanes()
eval(defaultBindings)
for source in defaults: eval(source)
eval("(setq understanding-ledger nil)")
let globalKeys = keymap
discard git("init -b main")
discard git("config user.email test@example.invalid")
discard git("config user.name Test")
var before = ""
for i in 1..30: before.add "line " & $i & "\n"
writeFile(repo / "a.txt", before)
writeFile(repo / "both.txt", "base\n")
writeFile(repo / "deleted", "gone\n")
writeFile(repo / "old name", "rename\n")
writeFile(repo / "crlf", "old\r\ncontext\r\n")
writeFile(repo / "no-newline", "old")
discard git("add .")
discard git("commit -m initial")
writeFile(repo / "both.txt", "index\n")
discard git("add both.txt")
writeFile(repo / "both.txt", "worktree\n")
let after = before.replace("line 2\n", "first\n").replace("line 25\n", "last\n")
writeFile(repo / "a.txt", after)
discard git("rm deleted")
discard git("mv 'old name' 'new name'")
writeFile(repo / "crlf", "new\r\ncontext\r\n")
writeFile(repo / "no-newline", "new")
writeFile(repo / "untracked", "  spaces  \nno newline")
writeFile(repo / "binary", "\0binary\0")
writeFile(repo / "big", repeat("line\n", 4000))
writeFile(repo / "huge", repeat("x", 512 * 1024 + 1))
writeFile(repo / "empty", "")
writeFile(repo / "日本語\tfile\n", "special\n")

let original = newBuffer(after)
original.path = repo / "a.txt"
switchTo(original)
eval("(magit-status)")
let display = b
doAssert reg.displayName(display) == "*magit*" and display.isReadOnly
doAssert display.text.startsWith("Head: main") and "Enter open (M-, back)" in display.text
doAssert "@@ " notin display.text
for key in ["s", "u", "k", "c", "P", "F", "g", "q", "n", "p", "?", "r", "tab", "C-i", "S-tab", "enter"]:
  doAssert display.hasLocalKey(key), key
doAssert keymap == globalKeys
let textBefore = b.text
discard runCommand("newline")
doAssert b.text == textBefore and echoLine == "Buffer is read-only"

# Direct local command calls, never synthetic key events.
selectFile("a.txt")
action("tab")
doAssert "+first" in b.text and "+last" in b.text
let header = b.cursor.line
b.cursor = (lineStarting("+first"), 0)
action("C-i")
doAssert b.cursor.line == header and "+first" notin b.text
action("C-i")
action("g")
doAssert "+first" in b.text and b.cursor.line == header
b.cursor = (lineStarting("Unstaged"), 0)
action("tab")
doAssert "+first" notin b.text and "a.txt" notin b.text
action("g")
doAssert "a.txt" notin b.text
action("tab")
doAssert "+first" in b.text
for section in ["Untracked", "Staged", "Recent commits"]:
  b.cursor = (lineStarting(section), 0)
  action("tab")
  doAssert ($b.lines[b.cursor.line]).endsWith("▸")
  action("tab")
  doAssert ($b.lines[b.cursor.line]).endsWith("▾")

selectFile("both.txt")
action("tab")
doAssert "-index" in b.text and "+worktree" in b.text and "-base" notin b.text
selectFile("both.txt", "Staged")
action("tab")
doAssert "-base" in b.text and "+index" in b.text
for name in ["untracked", "binary", "big", "huge", "empty", "日本語\\tfile\\n"]:
  selectFile(name, "Untracked")
  action("tab")
doAssert "+  spaces  " in b.text and "+no newline" in b.text
doAssert "(binary file)" in b.text and "(large untracked file; diff omitted)" in b.text
doAssert b.lines.len < 130 and "+special" in b.text
doAssert facesOf(display)[lineStarting("+first")][0] == fAnsi2
doAssert facesOf(display)[lineStarting("-line 2")][0] == fAnsi1
doAssert facesOf(display)[lineStarting("@@ ")][0] == fType
action("S-tab")
doAssert "@@ " notin b.text and "  ▾ " notin b.text
action("S-tab")
doAssert "+first" in b.text and "  ▸ " notin b.text and b.lines.len < 160

# Enter visits the new side (including removed lines) and M-, restores the exact view.
for (prefix, expected) in [("+first", 1), ("-line 2", 1), (" line 3", 2), ("+last", 24)]:
  let row = lineStarting(prefix)
  display.cursor = (row, 2)
  renderer.top = 3
  renderer.left = 1
  action("enter")
  doAssert b == original and b.cursor.line == expected and not reviewOpen()
  doAssert echoLine == "M-, returns to *magit*"
  xrefBack()
  doAssert b == display and b.cursor == (row, 2)
  doAssert renderer.top == 3 and renderer.left == 1
selectFile("a.txt")
let origin = b.cursor
action("enter")
doAssert b == original and not reviewOpen()
xrefBack()
doAssert b == display and b.cursor == origin
selectFile("deleted", "Staged")
let depth = xrefStack.len
action("enter")
doAssert b == display and "deleted" in echoLine and xrefStack.len == depth
selectFile("new name", "Staged")
action("enter")
doAssert b.path == repo / "new name" and not reviewOpen()
xrefBack()

# Stage one hunk, then unstage it; the other hunk and the working tree stay intact.
b.cursor = (lineStarting("+first"), 0)
action("s")
doAssert git("show :a.txt") == before.replace("line 2\n", "first\n")
doAssert readFile(repo / "a.txt") == after and "+last" in b.text
selectFile("a.txt", "Staged")
action("tab")
b.cursor = (lineStarting("@@ ", b.cursor.line), 0)
action("u")
doAssert git("show :a.txt") == before
doAssert "+first" in b.text and "+last" in b.text
doAssert "  ▾ M a.txt" in b.text
# Reappearing in the staged section retains its expansion too.
b.cursor = (lineStarting("+last"), 0)
action("s")
doAssert git("show :a.txt") == before.replace("line 25\n", "last\n")
selectFile("a.txt", "Staged")
doAssert ($b.lines[b.cursor.line]).startsWith("  ▾ ")
b.cursor = (lineStarting("+last", b.cursor.line), 0)
action("u")
doAssert git("show :a.txt") == before

# Literal paths, CRLF and a missing final newline survive patch application.
for name in ["crlf", "no-newline"]:
  selectFile(name)
  b.cursor = (lineStarting("@@ ", b.cursor.line), 0)
  action("s")
  doAssert git("show :" & name) == readFile(repo / name)
  selectFile(name, "Staged")
  action("tab")
  b.cursor = (lineStarting("@@ ", b.cursor.line), 0)
  action("u")
  doAssert git("show :" & name) == (if name == "crlf": "old\r\ncontext\r\n" else: "old")
b.cursor = (lineStarting("+special"), 0)
action("s")
doAssert git("show " & quoteShell(":日本語\tfile\n")) == "special\n"
selectFile("日本語\\tfile\\n", "Staged")
action("u")
doAssert "+special" in b.text
# Untracked hunks stage the whole file; ordinary file rows retain whole-file actions.
b.cursor = (lineStarting("+no newline"), 0)
action("s")
doAssert git("show :untracked") == "  spaces  \nno newline"
selectFile("untracked", "Staged")
action("u")
selectFile("a.txt")
action("s")
doAssert git("show :a.txt") == after
selectFile("a.txt", "Staged")
action("u")
doAssert git("show :a.txt") == before

# r preserves the former Enter review; returning from it can use xref too.
selectFile("a.txt")
let reviewOrigin = b.cursor
action("r")
doAssert reviewOpen() and reviewTarget == original and b == reviewBuf
doAssert "git HEAD" in echoLine
discard interp.call(symbol("review-key"), @[stringValue("q")])
xrefBack()
doAssert b == display and b.cursor == reviewOrigin and original.text == after
action("?")
doAssert "TAB" in echoLine and "M-," in echoLine and "r: review" in echoLine
action("q")
doAssert b != display and display in reg
switchTo(display)
killBuffer(display)
doAssert display notin localKeys and not display.isReadOnly
echo "magit folds, section diffs, hunk staging, source/xref navigation and review ok"
