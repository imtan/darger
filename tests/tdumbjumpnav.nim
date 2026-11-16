{.define: headless.}
import std/[os, tables, times, tempfiles, json]
import ../src/[core, buffer, render, lisp, lsp, grep]
import ../src/ext/langserver

let home = createTempDir("darger-dumbjump-", "")
putEnv("HOME", home) # no real init, project history, or server logs
createDir(home / "project" / ".git")
createDir(home / "project" / "src")
createDir(home / "project" / "other")
renderer = Renderer(frameCols: 100, frameRows: 40)
layoutPanes()
proc eval(s: string) = discard interp.evalString(s, "<test>")
proc openText(text: string, path = "main.nim"): Buffer =
  result = newBuffer(text)
  result.path = home / "project" / "src" / path
  switchTo(result)
  mode = ""
  xrefStack = @[]
  clients.clear()
  clients["Nim"] = nil
  setServer("Nim", "")

block noServer:
  let origin = openText("let needle = 1\necho needle")
  b.cursor = (1, 8)
  eval("(lsp-definition)")
  doAssert b == origin and b.cursor == (0, 4) and xrefStack.len == 1
  xrefBack()
  doAssert b == origin and b.cursor == (1, 8)
  eval("(lsp-type-definition)")
  doAssert b.cursor == (1, 8) and xrefStack.len == 0
  eval("(lsp-implementation)")
  doAssert b.cursor == (1, 8) and xrefStack.len == 0
  clients["Nim"] = Client(state: lsStarting)
  eval("(lsp-definition)")
  doAssert b.cursor == (0, 4) and xrefStack.len == 1
  xrefBack()

block consult:
  let origin = openText("let needle = 1\nproc f(needle: int) =\n  echo needle")
  b.cursor = (2, 8)
  eval("(dumb-jump-go)")
  doAssert mode == "dumb-jump" and targets.len == 2
  doAssert b.cursor == (1, 7) and xrefStack.len == 0 # first preview
  abandonLine()
  doAssert b == origin and b.cursor == (2, 8) and xrefStack.len == 0
  eval("(dumb-jump-go)")
  moveCandidate(1, true)
  doAssert b.cursor == (0, 4)
  confirmMini()
  doAssert mode == "" and xrefStack.len == 1
  xrefBack()
  doAssert b == origin and b.cursor == (2, 8)

block project:
  writeFile(home / "project" / "src" / "definition.nim", "proc needle*() = discard")
  writeFile(home / "project" / "other" / "definition.nim", "proc needle*() = discard")
  writeFile(home / "project" / "src" / "comment.nim", "#[\nproc needle() = discard\n]#")
  let origin = openText("needle()")
  b.cursor = (0, 2)
  # A stale declaration on disk must not override the current buffer.
  writeFile(b.path, "proc needle() = discard")
  eval("(dumb-jump-go)")
  doAssert mode == "dumb-jump" and targets.len == 2, $targets
  doAssert b.path == home / "project" / "src" / "definition.nim"
  confirmMini()
  xrefBack()
  doAssert b == origin and b.cursor == (0, 2)
  # The same project lookup works when only grep is on PATH.
  let savedPath = getEnv("PATH")
  putEnv("PATH", "/usr/bin:/bin")
  eval("(dumb-jump-go)")
  doAssert mode == "dumb-jump" and targets.len == 2
  abandonLine()
  putEnv("PATH", savedPath)

block literalSearch:
  let dir = home / "literal"
  createDir(dir)
  writeFile(dir / "a.el", "(defvar *needle* 1)\n(defvar needle 2)")
  for fallback in [false, true]:
    let savedPath = getEnv("PATH")
    if fallback: putEnv("PATH", "/usr/bin:/bin")
    let found = runGrep(dir, "*needle*", literal = true)
    doAssert found.error == "" and found.hits.len == 1
    putEnv("PATH", savedPath)

block missing:
  discard openText("unknownName()")
  b.cursor = (0, 3)
  eval("(dumb-jump-go)")
  doAssert echoLine == "No definition for unknownName" and xrefStack.len == 0

block emptyServerReply:
  let origin = openText("let needle = 1\necho needle")
  b.cursor = (1, 8)
  let fake = currentSourcePath().parentDir / "fake_lsp.py"
  let c = newClient("python3 " & quoteShell(fake), home, "dumbjump-test")
  clients["Nim"] = c
  setServer("Nim", "python3 " & quoteShell(fake))
  c.initialize()
  template waitFor(condition: untyped) =
    block:
      let deadline = epochTime() + 5
      while not condition and epochTime() < deadline:
        discard c.poll()
        sleep(10)
      doAssert condition
  waitFor(c.state == lsReady)
  eval("(lsp-definition)")
  waitFor(xrefStack.len == 1)
  doAssert b == origin and b.cursor == (0, 4)
  xrefBack()
  eval("(lsp-definition)")
  b.cursor = (1, 0) # a late response cannot move the user
  var answered = false
  c.request("test/echo", newJObject(), proc(res, error: JsonNode) = answered = true)
  waitFor(answered)
  doAssert b.cursor == (1, 0) and xrefStack.len == 0
  b.cursor = (1, 8)
  eval("(lsp-definition)")
  inc b.version # even with the cursor unchanged, an edited buffer invalidates a reply
  answered = false
  c.request("test/echo", newJObject(), proc(res, error: JsonNode) = answered = true)
  waitFor(answered)
  doAssert b.cursor == (1, 8) and xrefStack.len == 0
  b.cursor = (1, b.lines[1].len)
  b.insert(" target") # the fake server returns the first occurrence of target
  b.cursor = (1, 8)
  eval("(lsp-definition)")
  waitFor(xrefStack.len == 1)
  doAssert b.cursor.line == 1 # LSP's answer takes priority over the declaration on line 0
  c.shutdown()
echo "dumbjump navigation ok"
