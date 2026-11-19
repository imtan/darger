{.define: headless.}
import std/[os, osproc, tempfiles, strutils, tables, times, unicode]
import ../src/[core, buffer, buffers, render, lisp, checkpoints, review]
import ../src/ext/[agent, checkpoints, branchdiff]

let home = createTempDir("darger-checkpoint-workflow-", "")
putEnv("HOME", home)
let root = home / "repo"
createDir(root)
proc git(args: string): string =
  let r = execCmdEx("git -C " & quoteShell(root) & " -c commit.gpgsign=false " & args)
  doAssert r.exitCode == 0, r.output
  r.output
proc eval(s: string) = discard interp.evalString(s, "<checkpoint-test>")
proc action(key: string) = discard interp.call(symbol("agent-checkpoints-key"), @[stringValue(key)])
proc waitAgent() =
  let deadline = epochTime() + 5
  while agentProcess != nil and epochTime() < deadline:
    discard pollAgent()
    sleep(10)
  doAssert agentProcess == nil
proc acceptAll() =
  var count = 0
  while reviewOpen():
    inc count
    doAssert count < 20
    dispatchReview("a")

renderer = Renderer(frameCols: 100, frameRows: 40)
layoutPanes()
eval(defaultBindings)
for source in defaults: eval(source)
eval("(setq understanding-ledger nil)")
let globals = keymap
discard git("init -b main")
discard git("config user.name Test")
discard git("config user.email test@example.invalid")
writeFile(root / "a", "before\n")
writeFile(root / "deleted", "deleted before\n")
discard git("add .")
discard git("commit -m initial")
writeFile(root / "untracked", "untracked before\n")
writeFile(root / "empty", "")
let origin = newBuffer()
origin.path = root / "origin"
switchTo(origin)
chatRoot = root
sendChat("change local files", "printf 'after\\n' > a; printf 'new\\n' > added; rm deleted empty; printf 'changed\\n' > untracked; printf 'done\\n'")
waitAgent()
let session = chats[root]
doAssert session.checkpoint != nil and session.checkpoint.complete
let cp = loadCheckpoint(session.checkpoint.storage)
doAssert cp.before["a"].data == "before\n" and cp.changed.len == 5
let index = git("write-tree")
openCheckpoints()
let list = b
doAssert list.isReadOnly and "change local files" in list.text and "5 files" in list.text
for key in ["enter", "C-m", "C-j", "r", "q"]: doAssert list.hasLocalKey(key)
doAssert keymap == globals
list.cursor = (3, 0)
action("enter")
doAssert reg.displayName(b) == "*branch-diff*" and b.isReadOnly and "+after" in b.text
switchTo(list)
action("r")
doAssert reviewOpen() and readFile(root / "a") == "after\n"
doAssert listCheckpoints(root).len == 2  # redo saved before the first decision
dispatchReview("k")
dispatchReview("q")
doAssert readFile(root / "a") == "after\n"
acceptAll()
doAssert not fileExists(root / "added") and fileExists(root / "empty")
doAssert readFile(root / "deleted") == "deleted before\n"
doAssert readFile(root / "untracked") == "untracked before\n"
doAssert git("write-tree") == index
# Rewind the redo point through the same human review.
let redo = loadCheckpoint(listCheckpoints(root)[1].storage)
reviewCheckpoint(redo)
acceptAll()
doAssert readFile(root / "a") == "after\n" and fileExists(root / "added")
doAssert not fileExists(root / "deleted") and not fileExists(root / "empty")
# Cancellation never writes accepted decisions from a still-open review.
reviewCheckpoint(cp)
dispatchReview("y")
finishReview(true)
doAssert readFile(root / "a") == "after\n"
# Replacing the review cancels its callback; a later rewind must still work.
reviewCheckpoint(cp)
switchTo(origin)
beginReview("unrelated\n", "another review")
finishReview(true)
reviewCheckpoint(cp)
doAssert reviewOpen()
finishReview(true)
# A disk write during review wins; a dirty buffer is skipped.
reviewCheckpoint(cp)
writeFile(root / "a", "concurrent\n")
dispatchReview("a")
acceptAll()
doAssert readFile(root / "a") == "concurrent\n" and "changed during review" in echoLine
visit(root / "a")
let opened = b
opened.splice(0, 0, "unsaved\n")
reviewCheckpoint(cp)
doAssert not reviewOpen() and "skipped" in echoLine
doAssert readFile(root / "a") == "concurrent\n"
# A clean open buffer is updated along with the file and can undo the change.
opened.revert()
reviewCheckpoint(cp)
dispatchReview("y")
dispatchReview("w")
if reviewOpen(): dispatchReview("q")
doAssert readFile(root / "a") == "before\n" and opened.text == "before\n" and not opened.modified
# Non-Git round trip, empty new file and CRLF/BOM bytes.
let plain = home / "plain"
createDir(plain)
writeFile(plain / "text", "\xEF\xBB\xBFbefore\r\n")
let pc = createCheckpoint(plain, "plain-session", "plain")
writeFile(plain / "text", "after\n")
writeFile(plain / "new-empty", "")
finishCheckpoint(pc)
reviewCheckpoint(loadCheckpoint(pc.storage))
acceptAll()
doAssert readFile(plain / "text") == "\xEF\xBB\xBFbefore\r\n" and not fileExists(plain / "new-empty")
# Mixed y/k decisions apply only accepted hunks, including an unchanged middle.
writeFile(plain / "text", "first\ncontext\nlast\n")
let desired = createCheckpoint(plain, "mixed-session", "desired")
writeFile(plain / "text", "FIRST\ncontext\nLAST\n")
reviewCheckpoint(desired)
doAssert reviewState.hunks.len == 2
dispatchReview("y")
dispatchReview("k")
dispatchReview("q")
doAssert readFile(plain / "text") == "first\ncontext\nLAST\n"
# An edited buffer appearing during review cannot be overwritten.
reviewCheckpoint(desired)
visit(plain / "text")
let concurrentBuffer = b
concurrentBuffer.splice(0, 0, "unsaved\n")
switchTo(reviewBuf)
dispatchReview("a")
doAssert readFile(plain / "text") == "first\ncontext\nLAST\n"
doAssert concurrentBuffer.text.startsWith("unsaved\n")
switchTo(list)
action("q")
doAssert b != list and keymap == globals

echo "automatic turn checkpoints, list/diff keys, reviewed rewind/redo, conflicts and non-Git ok"
