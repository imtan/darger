{.define: headless.}
import std/[os, osproc, tempfiles, strutils, tables, unicode]
import ../src/[core, buffer, buffers, render, lisp, ledger]
import ../src/ext/[branchdiff, understand]

let home = createTempDir("darger-branchdiff-", "")
putEnv("HOME", home)
let repo = home / "repo"
createDir(repo)
proc git(args: string) =
  let r = execCmdEx("git -C " & quoteShell(repo) & " -c commit.gpgsign=false " & args)
  doAssert r.exitCode == 0, r.output
proc eval(s: string) = discard interp.evalString(s, "<branch-diff-test>")
proc action(key: string) = discard interp.call(symbol("branch-diff-key"), @[stringValue(key)])
proc lineStarting(s: string): int =
  for i, line in b.lines:
    if ($line).startsWith(s): return i
  doAssert false, "Missing: " & s & "\n" & b.text

renderer = Renderer(frameCols: 100, frameRows: 40)
layoutPanes()
eval(defaultBindings)
for source in defaults: eval(source)
eval("(setq understanding-ledger nil)")
let globalKeys = keymap

git("init -b main")
git("config user.email test@example.invalid")
git("config user.name Test")
writeFile(repo / "a.txt", "before\ncontext\nend\n")
writeFile(repo / "old name", "unchanged\n")
writeFile(repo / "deleted", "gone\n")
git("add .")
git("commit -m initial")
git("branch release")
git("checkout -b feature")
writeFile(repo / "committed", "branch commit\n")
git("add committed")
git("commit -m feature")
git("checkout main")
writeFile(repo / "base-only", "must not appear\n")
git("add base-only")
git("commit -m base")
git("checkout feature")
writeFile(repo / "a.txt", "after\ncontext\nend\n")
git("mv 'old name' 'new name'")
git("rm deleted")
writeFile(repo / "staged", "staged\n")
git("add staged")
writeFile(repo / "new empty", "")
writeFile(repo / "binary", "\0binary\0")
writeFile(repo / "日本語\tfile\n", "  spaces  \nno newline")
writeFile(repo / "big", repeat("line\n", 4000))
createSymlink("a.txt", repo / "link")

let original = newBuffer("before\ncontext\nend\n")
original.path = repo / "a.txt"
switchTo(original)
# A remembered base takes precedence over the setting; its remembered tip range
# must not turn branch-diff into a tip comparison.
rememberBase(basesPath(), repo, "main", "tip")
eval("(setq understanding-base-branch \"does-not-exist\")")
openBranchDiff()
let display = b
doAssert reg.displayName(display) == "*branch-diff*" and display.isReadOnly and display.path == ""
doAssert display.text.startsWith("feature ← main")
doAssert "base-only" notin display.text and "+branch commit" in display.text
doAssert "(renamed from old name)" in display.text and "(deleted)" in display.text
for name in ["new empty", "binary", "staged", "日本語\\tfile\\n", "link"]:
  doAssert name in display.text, name
discard lineStarting("▸ big")
doAssert b.lines.len < 100
for key in ["n", "p", "tab", "S-tab", "enter", "b", "g", "q"]:
  doAssert display.hasLocalKey(key), key
doAssert keymap == globalKeys
let before = display.text
discard runCommand("newline")
doAssert display.text == before and echoLine == "Buffer is read-only"
doAssert facesOf(display).len == display.lines.len

# Folding and navigation operate on file headings, preserving source rows.
b.cursor = (0, 0)
action("n")
doAssert ($b.lines[b.cursor.line]).startsWith("▾ ")
let first = b.cursor.line
action("n")
doAssert b.cursor.line > first
action("p")
doAssert b.cursor.line == first
b.cursor = (lineStarting("+after"), 0)
action("tab")
doAssert ($b.lines[b.cursor.line]).startsWith("▸ a.txt") and "+after" notin b.text
action("tab")
doAssert "+after" in b.text
action("S-tab")
doAssert "▾ " notin b.text and "@@ " notin b.text
action("S-tab")
doAssert "▸ " notin b.text and b.lines.len > 4000

# Direct command calls: no generated keyboard events, and xref return is exact.
for prefix in ["+after", "-before", " context", "▾ a.txt"]:
  let row = lineStarting(prefix)
  display.cursor = (row, 0)
  action("enter")
  doAssert b == original
  doAssert b.cursor.line == (if prefix == " context": 1 else: 0)
  xrefBack()
  doAssert b == display and b.cursor.line == row
b.cursor = (lineStarting("▾ deleted"), 0)
let depth = xrefStack.len
action("enter")
doAssert b == display and "deleted" in echoLine and xrefStack.len == depth

# Refresh obtains new disk content; base selection uses the shared prompt/memory.
writeFile(repo / "a.txt", "refreshed\ncontext\nend\n")
action("g")
doAssert "+refreshed" in b.text and "+after" notin b.text
b.cursor = (lineStarting("▾ a.txt"), 0)
action("b")
doAssert mode == "understanding-base"
setMini("release")
confirmMini()
doAssert baseFor(loadBases(basesPath()), repo) == "release"
doAssert rangeFor(loadBases(basesPath()), repo) == "tip"
doAssert "feature ← release" in b.text
# The original understanding callback still owns its own base and rebuild.
switchTo(original)
openUnderstanding()
doAssert reg.displayName(b) == "*understanding*"
eval("(understanding-base)")
setMini("main")
confirmMini()
doAssert "Branch feature vs main" in b.text
switchTo(display)
action("q")
doAssert b != display and display in reg
switchTo(display)
killBuffer(display)
doAssert display notin localKeys and not display.isReadOnly

# No repository, a clean comparison, fallback order and a repository with no usual base.
let outside = newBuffer()
outside.path = home / "outside.txt"
switchTo(outside)
openBranchDiff()
doAssert b == outside and echoLine == "Not in a git repository"
let clean = home / "clean"
createDir(clean)
let r = execCmdEx("git -C " & quoteShell(clean) & " init -b odd")
doAssert r.exitCode == 0
let init = execCmdEx("git -C " & quoteShell(clean) & " -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false commit --allow-empty -m initial")
doAssert init.exitCode == 0
let source = newBuffer()
source.path = clean / "file"
switchTo(source)
eval("(setq understanding-base-branch nil)")
openBranchDiff()
doAssert echoLine == "No other branch to compare with"
let create = execCmdEx("git -C " & quoteShell(clean) & " branch unusual")
doAssert create.exitCode == 0
openBranchDiff()
doAssert mode == "understanding-base"
setMini("unusual")
confirmMini()
doAssert "nothing changed against unusual" in b.text
# The setting works when no base has been remembered for the repository.
let setting = home / "setting"
createDir(setting)
doAssert execCmdEx("git clone -q " & quoteShell(clean) & " " & quoteShell(setting)).exitCode == 0
let settingSource = newBuffer()
settingSource.path = setting / "file"
switchTo(settingSource)
eval("(setq understanding-base-branch \"origin/unusual\")")
openBranchDiff()
doAssert "nothing changed against origin/unusual" in b.text
for usual in ["develop", "master", "main"]:
  doAssert execCmdEx("git -C " & quoteShell(setting) & " branch " & usual).exitCode == 0
  switchTo(settingSource)
  eval("(setq understanding-base-branch nil)")
  openBranchDiff()
  doAssert "nothing changed against " & usual in b.text

echo "branch diff git range, untracked files, local commands, xref, refresh and base selection ok"
