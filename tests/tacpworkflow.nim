{.define: headless.}
import std/[os, strutils, times, tables, unicode, json]
import ../src/[core, buffer, buffers, render, lisp, acp, syntax]
import ../src/ext/[agent, acp, agentplan, reviewcomments, compile]

# HOME is replaced by the caller before core is imported.
let home = getHomeDir()
doAssert "tmp" in home or "/var/folders/" in home
let repo = home / "repo"
createDir(repo)
let fixture = absolutePath("tests/fake_acp.py")
let python = findExe("python3")
doAssert python.len > 0
proc eval(text: string) = discard interp.evalString(text, "<acp-test>")
proc call(name: string) = discard interp.call(symbol(name), @[])
template waitFor(condition: untyped) =
  block:
    let deadline = epochTime() + 8
    while not (condition) and epochTime() < deadline:
      discard pollAcp()
      sleep(5)
    doAssert condition, "Timed out: " & astToStr(condition) & " / " & echoLine
proc answer(value: string) =
  doAssert mode == "acp-choice"
  setMini(value)
  confirmMini()
proc reviewed(take: bool) =
  doAssert reviewOpen()
  dispatchReview(if take: "y" else: "k")
  if reviewOpen(): dispatchReview("q")

echo "ACP: init"
renderer = Renderer(frameCols: 100, frameRows: 40)
layoutPanes()
eval(defaultBindings)
for source in defaults: eval(source)
eval("(setq understanding-ledger nil)")
eval("(setq agent-notify nil)")
eval("(setq agent-plan-directory nil)")
let globals = keymap
let command = quoteShell(python) & " -u " & quoteShell(fixture)
eval("(setq acp-agents '((\"fake\" . " & $stringValue(command) & ")))")
writeFile(repo / "file.txt", "disk\n")
let origin = loadBuffer(repo / "file.txt")
reg.add(origin, "file.txt")
origin.splice(0, origin.text.runeLen, "unsaved\n")
switchTo(origin)
echo "ACP: starting"
let s = startAcp("fake", repo)
echo "ACP: started"
waitFor(s.state.phase == apReady)
doAssert s.state.id == "fake-session" and s.chat.started
doAssert s.chat.buf.isReadOnly and s.chat.buf.hasLocalKey("C-c C-k")
doAssert currentChatRoot() == repo

echo "ACP: write approval is deferred through preview, permission and file review"
s.submit("write")
waitFor(reviewOpen())
doAssert origin.text == "unsaved\n" and readFile(origin.path) == "disk\n"
doAssert "Hello world" in s.chat.buf.text and "[>] Edit" in s.chat.buf.text
doAssert "Thinking quietly" notin s.chat.buf.text
switchTo(s.chat.buf)
call("acp-toggle-thoughts")
doAssert "Thinking quietly" in s.chat.buf.text
doAssert facesOf(s.chat.buf).len > 0
switchTo(reviewBuf)
reviewed(true) # preview changes a scratch buffer only
waitFor(mode == "acp-choice")
doAssert readFile(origin.path) == "disk\n"
answer("1")
waitFor(reviewOpen())
doAssert reviewTarget == origin
doAssert origin.text == "unsaved\n" and readFile(origin.path) == "disk\n"
reviewed(true)
waitFor(s.state.phase == apReady)
doAssert origin.text == "changed\n" and readFile(origin.path) == "changed\n"
doAssert "WRITE_OK" in s.state.reply

echo "ACP: rejection and stale disk preserve files"
for conflict in [false, true]:
  origin.splice(0, origin.text.runeLen, "unsaved\n")
  s.submit("write")
  waitFor(reviewOpen())
  reviewed(true)
  waitFor(mode == "acp-choice")
  answer("1")
  waitFor(reviewOpen())
  if conflict: writeFile(origin.path, "external\n")
  reviewed(conflict)
  waitFor(s.state.phase == apReady)
  doAssert origin.text == "unsaved\n"
  doAssert readFile(origin.path) == (if conflict: "external\n" else: "changed\n")
  doAssert "WRITE_REJECTED" in s.state.reply

echo "ACP: new files and empty files require human approval"
s.submit("new")
waitFor(reviewOpen())
doAssert not fileExists(repo / "new.txt")
reviewed(true)
waitFor(s.state.phase == apReady)
doAssert readFile(repo / "new.txt") == "new content\n"
s.submit("empty")
waitFor(mode == "acp-choice")
doAssert not fileExists(repo / "empty.txt")
answer("y")
waitFor(s.state.phase == apReady)
doAssert fileExists(repo / "empty.txt") and readFile(repo / "empty.txt") == ""

echo "ACP: cancellation answers pending permission and ends prompt"
s.submit("write")
waitFor(reviewOpen())
s.cancel()
waitFor(s.state.phase == apReady)
doAssert not reviewOpen() and "PERMISSION_CANCELLED" in s.state.reply
s.submit("cancel")
waitFor(s.state.phase == apPrompting)
s.cancel()
waitFor(s.state.phase == apReady)

echo "ACP: terminals require their own approval and support full lifecycle"
for allowed in [false, true]:
  s.submit("terminal")
  waitFor(mode == "acp-choice")
  answer(if allowed: "y" else: "n")
  waitFor(s.state.phase == apReady)
  doAssert (if allowed: "TERMINAL_OK" else: "TERMINAL_REJECTED") in s.state.reply
let terminal = reg.byName("*acp-terminal*")
doAssert terminal != nil and terminal.isReadOnly and "日本語" in terminal.text
s.submit("outside")
waitFor(s.state.phase == apReady)
doAssert "OUTSIDE_DENIED" in s.state.reply

echo "ACP: selected backend supplies plans and approval to the same session"
eval("(setq agent-backend 'acp)")
switchTo(s.chat.buf)
call("agent-plan")
setMini("Make a plan")
confirmMini()
waitFor(s.state.phase == apReady)
let plan = b
doAssert reg.displayName(plan) == "*agent-plan*", reg.displayName(plan)
doAssert "# Plan" in plan.text and not plan.isReadOnly
plan.splice(0, plan.text.runeLen, "# Edited plan\nVerify first\n")
call("agent-plan-approve")
waitFor(s.state.phase == apReady)
doAssert "# Edited plan" in s.state.reply

echo "ACP: batched review comments and failed compilation use the selected session"
switchTo(plan)
plan.cursor = (1, 0)
call("review-comment")
setMini("Check regressions")
confirmMini()
doAssert comments.len == 1
call("review-comments-send")
waitFor(s.state.phase == apReady)
doAssert comments.len == 0 and "Check regressions" in s.state.reply
switchTo(origin)
call("compile")
setMini("printf 'file.txt:1:1: error: fixture failure\\n'; exit 1")
confirmMini()
block:
  let deadline = epochTime() + 8
  while compilationJob != nil and epochTime() < deadline:
    discard pollCompilation()
    sleep(5)
  doAssert compilationJob == nil
call("compile-ask-agent")
waitFor(s.state.phase == apReady)
doAssert "fixture failure" in s.state.reply

echo "ACP: persisted session identity"
let cache = parseJson(readFile(home / ".darger-acp-sessions.json"))
doAssert cache["fake\n" & repo].getStr == s.state.id

echo "ACP: buffer close disconnects and loadSession resumes with replay"
killBuffer(s.chat.buf)
doAssert s.state.phase == apFailed
let resumed = startAcp("fake", repo)
waitFor(resumed.state.phase == apReady)
doAssert "Restored" in resumed.chat.buf.text
let fresh = startAcp("fake", repo, fresh = true)
waitFor(fresh.state.phase == apReady)
doAssert "Restored" notin fresh.chat.buf.text
killBuffer(fresh.chat.buf)
killBuffer(resumed.chat.buf)
doAssert keymap == globals
let wire = readFile(repo / "wire.jsonl")
for name in ["initialize", "session/new", "session/load", "session/prompt", "session/cancel"]:
  doAssert name in wire
for line in wire.splitLines:
  if line.len > 0: discard parseJson(line)
echo "ACP offline stdio, human review, terminal lifecycle, cancellation, plan routing and session load ok"
