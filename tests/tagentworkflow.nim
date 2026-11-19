{.define: headless.}
import std/[os, tempfiles, strutils, tables, times, unicode]
import ../src/[core, buffer, buffers, render, lisp, review, chat]
import ../src/ext/[agent, agentrules, notify]

let home = createTempDir("darger-agent-workflow-", "")
putEnv("HOME", home)
let root = home / "project"
createDir(root / ".git")
createDir(home / ".claude")
createDir(home / ".codex")
writeFile(home / ".claude/CLAUDE.md", "private user rule\n")
writeFile(home / ".codex/AGENTS.md", "private codex rule\n")
writeFile(root / "CLAUDE.md", "project rule\n")
proc eval(s: string) = discard interp.evalString(s, "<agent-test>")
proc rulesKey(key: string) = discard interp.call(symbol("agent-rules-key"), @[stringValue(key)])
renderer = Renderer(frameCols: 100, frameRows: 40)
layoutPanes()
eval(defaultBindings)
for source in defaults: eval(source)
eval("(setq understanding-ledger nil)")
let origin = newBuffer("source\n")
origin.path = root / "file.nim"
switchTo(origin)
let globals = keymap

block rulesView:
  openAgentRules()
  let display = b
  doAssert display.isReadOnly and reg.displayName(b) == "*agent-rules*"
  doAssert "private user rule" notin b.text and "private codex rule" notin b.text
  doAssert "project rule" notin b.text
  for key in ["enter", "C-m", "C-j", "g", "q"]: doAssert b.hasLocalKey(key)
  doAssert keymap == globals
  for i, line in display.lines:
    if (root / "CLAUDE.md") in $line: display.cursor = (i, 0)
  let point = display.cursor
  rulesKey("enter")
  doAssert b.path == root / "CLAUDE.md"
  xrefBack()
  doAssert b == display and b.cursor == point
  writeFile(root / "CLAUDE.local.md", "local\n")
  rulesKey("g")
  doAssert "CLAUDE.local.md" in b.text
  rulesKey("q")
  doAssert b != display
  switchTo(origin)

block memoryOpen:
  let path = root / "CLAUDE.md"
  let target = reg.byPath(path)
  target.splice(0, 0, "unsaved\n")
  let before = target.text
  reviewMemory(path, "keep changes small")
  doAssert reviewState.hunks.len == 1 and reviewState.stats(0).removed == 0
  doAssert target.text == before and readFile(path) == "project rule\n"
  dispatchReview("y")
  doAssert target.text == before
  dispatchReview("q")
  doAssert target.text == before & "- keep changes small\n" and target.modified
  doAssert readFile(path) == "project rule\n"
  doAssert b == origin
  let accepted = target.text
  reviewMemory(path, "reject me")
  dispatchReview("k")
  dispatchReview("q")
  doAssert target.text == accepted
  reviewMemory(path, "cancel me")
  dispatchReview("y")
  finishReview(true)
  doAssert target.text == accepted
  reviewMemory(path, "stale")
  target.splice(0, 0, "concurrent\n")
  dispatchReview("a")
  doAssert target.text == "concurrent\n" & accepted
  doAssert "destination buffer changed" in echoLine

block memoryDisk:
  let path = root / "AGENTS.md"
  reviewMemory(path, "new file")
  doAssert not fileExists(path)
  dispatchReview("k")
  dispatchReview("q")
  doAssert not fileExists(path)
  reviewMemory(path, "new file")
  dispatchReview("y")
  dispatchReview("enter")
  doAssert readFile(path) == "- new file\n" and reg.byPath(path) == nil
  writeFile(path, "no final newline")
  reviewMemory(path, "second")
  doAssert reviewState.hunks.len == 1 and reviewState.stats(0).removed == 0
  dispatchReview("a")
  doAssert readFile(path) == "no final newline\n- second\n"
  reviewMemory(path, "stale")
  writeFile(path, "external edit\n")
  dispatchReview("a")
  doAssert readFile(path) == "external edit\n" and "destination changed" in echoLine
  reviewMemory(path, "opened meanwhile")
  let display = b
  visit(path)
  let target = b
  switchTo(display)
  dispatchReview("a")
  doAssert target.text == "external edit\n- opened meanwhile\n"
  doAssert readFile(path) == "external edit\n"
  let formatted = root / "formatted.md"
  writeFile(formatted, "\xEF\xBB\xBFexisting\r\n")
  reviewMemory(formatted, "preserve format")
  dispatchReview("a")
  doAssert readFile(formatted) == "\xEF\xBB\xBFexisting\r\n- preserve format\r\n"

block prompts:
  switchTo(origin)
  eval("(agent-remember)")
  doAssert mode == "agent-memory-text"
  setMini("from prompt")
  confirmMini()
  doAssert mode == "agent-memory-file" and mini.text == root / "CLAUDE.md"
  confirmMini()
  doAssert reviewOpen() and mode == ""
  dispatchReview("k")
  dispatchReview("q")

proc waitAgent() =
  let deadline = epochTime() + 5
  while agentProcess != nil and epochTime() < deadline:
    discard pollAgent()
    sleep(10)
  doAssert agentProcess == nil

block notices:
  # Extensions loaded after agent may replace the initial mode-line provider.
  modeLineHook = proc(): string = " Existing hints"
  switchTo(origin)
  launchAgent("printf 'proposed\\n'", "", root)
  waitAgent()
  doAssert reviewOpen() and origin.text == "source\n"
  doAssert noticeText == "agent ✓ done" and modeLineHook() == " Existing hints  " & noticeText
  discard filterKey("C-n")
  doAssert noticeText == ""
  finishReview(true)
  launchAgent("exit 7", "", root)
  waitAgent()
  doAssert noticeText == "agent ✗ failed" and not reviewOpen()
  discard filterRune(Rune('z'))
  doAssert noticeText == ""
  notifyAgent(origin, terminal = true)
  doAssert noticeText == "agent ✓ done"
  eval("(setq agent-notify nil)")
  discard pollAgentNotice()
  doAssert noticeText == ""
  notifyAgent(origin, failed = true)
  doAssert noticeText == ""
  eval("(setq agent-notify t)")
  # A malformed successful response is still a failed turn.
  launchAgent("printf '\\377'", "", root)
  waitAgent()
  doAssert noticeText == "agent ✗ failed"
  clearAgentNotice()
  var failed = false
  try: launchAgent("true", "", root / "missing")
  except CatchableError: failed = true
  doAssert failed and noticeText == "agent ✗ failed"
  clearAgentNotice()
  # Stream errors must be notified even with a zero process exit code.
  let transcript = newBuffer()
  reg.add(transcript, "*test chat*")
  launchAgent("printf '%s\\n' '{\"type\":\"result\",\"is_error\":true,\"result\":\"failed\"}'", "", root)
  agentChat = ChatSession(root: root, buf: transcript, turn: appendTurn("", root, "test"))
  waitAgent()
  doAssert noticeText == "agent ✗ failed"
  launchAgent("printf 'chat reply\\n'", "", root)
  agentChat = ChatSession(root: root, buf: transcript, turn: appendTurn("", root, "test"))
  waitAgent()
  doAssert noticeText == "agent ✓ done" and "chat reply" in transcript.text
  var received = ""
  onAgentResult = proc(text: string) = received = text
  launchAgent("printf 'writing result\\n'", "", root)
  waitAgent()
  doAssert received == "writing result\n" and noticeText == "agent ✓ done"
  notifyAgent(origin)
  killBuffer(origin)
  doAssert noticeText == ""

echo "rules navigation, reviewed memory, conflicts, prompts and agent completion notifications ok"
