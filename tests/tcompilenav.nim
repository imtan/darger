{.define: headless.}
import std/[os, osproc, strutils, tables, times]
import ../src/[core, buffer, buffers, render, lisp, syntax]
import ../src/ext/[compile, agent]

doAssert getEnv("HOME").startsWith(getTempDir()) or getEnv("HOME").startsWith("/tmp/"), "Run with a temporary HOME before imports"
let root = getEnv("HOME") / "project with spaces"
createDir(root / "src")
writeFile(root / "darger.nimble", "")
writeFile(root / "src/a.nim", "one\ntwo\nthree\n")
writeFile(root / "b.py", "first\nsecond\nthird\n")
setCurrentDir(root)
proc eval(s: string) = discard interp.evalString(s, "<compile-test>")
proc command(name: string, args: seq[Value] = @[]) = discard interp.call(symbol(name), args)
proc waitCompilation() =
  let deadline = epochTime() + 8
  while compilationJob != nil and epochTime() < deadline:
    discard pollCompilation()
    sleep(10)
  doAssert compilationJob == nil, "Compilation did not finish"
proc answer(text: string) =
  setMini(text)
  confirmMini()
renderer = Renderer(frameCols: 100, frameRows: 40)
layoutPanes()
eval(defaultBindings)
for source in defaults: eval(source)
eval("(setq understanding-ledger nil)")
let original = newBuffer("one\ntwo\nthree\n")
original.path = root / "src/a.nim"
switchTo(original)
command("compile")
doAssert mode == "compile-command" and mini.text == "nimble build"
answer("printf 'src/a.nim(2, 2) Error: broken\\n'; sleep 0.3; printf '  File \"b.py\", line 3\\n' >&2; exit 7")
let display = compilationBuf
doAssert display.isReadOnly and reg.displayName(display) == "*compilation*" and compileRoot == root
for key in ["g", "a", "enter", "C-m", "C-j", "C-c C-k"]: doAssert display.hasLocalKey(key)
doAssert "C-c C-k" notin keymap
doAssert keymap["M-g n"].symName == "next-error" and keymap["M-g p"].symName == "previous-error"
doAssert keymap["C-x `"].symName == "next-error"
let deadline = epochTime() + 2
while "Error: broken" notin display.text and epochTime() < deadline:
  discard pollCompilation()
  sleep(5)
doAssert "Error: broken" in display.text and compilationJob != nil, "Output must stream before exit"
switchTo(original)
waitCompilation()
doAssert b == original and "exit code 7" in display.text and "File \"b.py\"" in display.text
doAssert mode == ""  # default nil never asks
doAssert facesOf(display)[3][0] == fAnsi1
command("next-error")
doAssert b == original and b.cursor == (1, 1)
command("next-error")
doAssert b.path == root / "b.py" and b.cursor == (2, 0)
command("previous-error")
doAssert b == original and b.cursor == (1, 1)
switchTo(display)
display.cursor = (4, 0)
command("compile-visit-error")
doAssert b.path == root / "b.py"
xrefBack()
doAssert b == display and b.cursor == (4, 0)
let before = display.text
discard runCommand("newline")
doAssert display.text == before and echoLine == "Buffer is read-only"
command("compile")
doAssert mini.text == compileCommand
answer("printf 'again\\n'")
waitCompilation()
command("recompile")
waitCompilation()
doAssert "again" in display.text and "exit code 0" in display.text

# Multiple bounded reads drain the complete output, even after the shell exits.
command("compile", @[stringValue("i=0; while [ $i -lt 5000 ]; do printf 'a long ordinary build output line\\n'; i=$((i+1)); done; printf 'src/a.nim(3, 1) Error: final\\n'; exit 2")])
waitCompilation()
doAssert display.text.count("a long ordinary build output line\n") == 5000
doAssert "Error: final" in display.text and "exit code 2" in display.text

# A live replacement is confirmed, and descendants cannot write after cancellation.
command("compile", @[stringValue("(printf ready > child-ready; sleep 0.5; printf leaked > leaked) & wait")])
let childDeadline = epochTime() + 2
while not fileExists(root / "child-ready") and epochTime() < childDeadline: sleep(5)
doAssert fileExists(root / "child-ready")
command("compile", @[stringValue("printf 'replacement\\n'")])
doAssert mode == "compile-restart"
answer("n")
doAssert compilationJob != nil
command("compile", @[stringValue("printf 'replacement\\n'")])
answer("y")
waitCompilation()
sleep(600)
doAssert "replacement" in display.text and not fileExists(root / "leaked")
command("compile", @[stringValue("sleep 10")])
command("compile-stop")
waitCompilation()
doAssert "stopped" in display.text
command("compile", @[stringValue("(sleep 0.5; printf leaked > orphaned) & exit 0")])
waitCompilation()
sleep(600)
doAssert not fileExists(root / "orphaned")

# Completion while the restart question is open cannot grant permission itself.
command("compile", @[stringValue("sleep 0.1")])
command("compile", @[stringValue("printf should-not-run > forbidden")])
waitCompilation()
doAssert mode == "compile-restart" and not fileExists(root / "forbidden")
answer("n")

# Ask exactly once, defer over an unrelated prompt, and never ask on success/stop.
eval("(setq compile-ask-agent-on-failure t)")
command("compile", @[stringValue("exit 1")])
beginMini("compile-command", "Other prompt: ", "ignored")
waitCompilation()
doAssert mode == "compile-command"
mode = ""
discard pollCompilation()
doAssert mode == "compile-agent"
answer("n")
for i in 0..3: discard pollCompilation()
doAssert mode == ""
command("compile", @[stringValue("true")])
waitCompilation()
doAssert mode == ""
command("compile", @[stringValue("sleep 10")])
command("compile-stop")
waitCompilation()
doAssert mode == ""

# Only a local fake agent runs. The ordinary chat/changes/review path is retained.
eval("(setq compile-ask-agent-on-failure nil)")
let git = execCmdEx("git init -q " & quoteShell(root))
doAssert git.exitCode == 0
eval("(setq agent-chat-command \"(cat > received; printf 'fixed\\n' > src/a.nim; printf 'done\\n')\")")
command("compile", @[stringValue("printf 'src/a.nim(2, 2) Error: fix me\\n'; exit 3")])
waitCompilation()
command("compile-ask-agent")
let agentDeadline = epochTime() + 5
while agentProcess != nil and epochTime() < agentDeadline:
  discard pollAgent()
  sleep(10)
doAssert agentProcess == nil
let received = readFile(root / "received")
doAssert "Exit code: 3" in received and "Error: fix me" in received and "2: two" in received
doAssert chatRoot == root and agentChangedRoot == root and "src/a.nim" in agentChanged
doAssert original.text == "one\ntwo\nthree\n", "Chat must not overwrite the visiting buffer"
command("agent-changes")
answer("src/a.nim")
doAssert reviewTarget == original and reviewBuf != nil
command("review-keep")
command("review-finish")
doAssert original.text == "one\ntwo\nthree\n"

# Killing the display stops its job and leaves no dead buffer or stale prompt.
command("compile", @[stringValue("sleep 10")])
killBuffer(compilationBuf)
waitCompilation()
doAssert compilationBuf == nil and display notin localKeys
echo "compile streaming, local keys, xref, restart/stop, consent and agent review workflow ok"
