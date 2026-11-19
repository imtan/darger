{.define: headless.}
import std/[os, strutils, json, tables, times]
import ../src/[core, buffer, buffers, render, lisp, review, ideprotocol, ideserver, lsp, syntax]
import ../src/ext/[idebridge, agent, claude, compile, revert, langserver]

doAssert getEnv("HOME").startsWith(getTempDir()) or getEnv("HOME").startsWith("/tmp/")
let root = getHomeDir() / "project"
createDir(root)
setCurrentDir(root)
writeFile(root / "a.nim", "proc hello() =\n  echo \"old\"\n\nhello()\n")
writeFile(root / "agenda.org", "* TODO Test agenda\n")
renderer = Renderer(frameCols: 100, frameRows: 40)
layoutPanes()
discard interp.evalString(defaultBindings, "<ide-test>")
for source in defaults: discard interp.evalString(source, "<ide-test>")
discard interp.evalString("(setq understanding-ledger nil)", "<ide-test>")
visit(root / "a.nim")
let original = b
let old = b.text
let proposed = old.replace("old", "new")
proc eval(s: string) = discard interp.evalString(s, "<ide-test>")
proc command(name: string, args: seq[Value] = @[]) = discard interp.call(symbol(name), args)
proc pump() =
  for i in 0..20:
    discard pollIde()
    sleep(1)
var replies = initTable[int, JsonNode]()
let server = IdeServer(root: root)
proc receive(socket: IdePeer): tuple[opcode: int, text: string] =
  var wire = socket.takeOutput()
  while wire.len > 0:
    let opcode = ord(wire[0]) and 15
    var size = ord(wire[1]) and 127
    var at = 2
    if size in [126, 127]:
      let count = if size == 126: 2 else: 8
      size = 0
      for byte in wire[2..<2+count]: size = size * 256 + ord(byte)
      at += count
    let text = wire[at..<at+size]
    wire = wire[at+size..^1]
    if opcode == 1:
      let value = parseJson(text)
      if value.hasKey("id"): replies[value["id"].getInt] = value
proc response(socket: IdePeer, id: int): JsonNode =
  discard socket.receive()
  doAssert id in replies, "Missing response " & $id
  result = replies[id]
  replies.del(id)
proc call(socket: IdePeer, id: int, name: string, args = newJObject()) =
  let answer = handleIdeMessage(server, socket, $(%*{"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": name, "arguments": args}}))
  if answer != nil: replies[id] = answer
  pump()
proc diff(socket: IdePeer, id: int, text: string, tab = "test") =
  socket.call(id, "openDiff", %*{"old_file_path": root / "a.nim", "new_file_path": root / "a.nim", "new_file_contents": text, "tab_name": tab})
proc resultData(socket: IdePeer, id: int): JsonNode =
  parseJson(socket.response(id)["result"]["content"][0]["text"].getStr)

let client = IdePeer(ready: true)
let path = getHomeDir() / "test.lock"
let token = newAuthToken()
doAssert token.len == 32 and token.allCharsInSet({'0'..'9', 'a'..'f'})
doAssert newAuthToken() != token
let lock = lockInfo(getCurrentProcessId(), @[root], token)
writeLock(path, $lock)
doAssert getFilePermissions(path) == {fpUserRead, fpUserWrite}
var collision = false
try: writeLock(path, "overwrite")
except OSError: collision = true
doAssert collision and parseJson(readFile(path)) == lock
client.call(1, "getWorkspaceFolders")
doAssert client.resultData(1)["rootPath"].getStr == root
client.call(2, "darger_buffer_text")
doAssert client.resultData(2)["text"].getStr == old
client.call(3, "darger_imenu")
doAssert client.resultData(3).len > 0
client.call(4, "darger_xref_definition", %*{"line": 3, "character": 2})
doAssert client.resultData(4)[0]["line"].getInt == 0
client.call(5, "darger_project_files")
doAssert client.resultData(5).len == 2
eval("(setq org-agenda-files '(\"" & root / "agenda.org" & "\"))")
client.call(6, "darger_org_agenda")
doAssert client.resultData(6).len == 1
# Selection uses UTF-16, including a supplementary character.
let unicodeBuffer = newBuffer("日本😀語\nend")
unicodeBuffer.path = root / "unicode.txt"
switchTo(unicodeBuffer)
unicodeBuffer.mark = (0, 1)
unicodeBuffer.cursor = (0, 3)
unicodeBuffer.regionActive = true
let selection = selectionOf(unicodeBuffer)
doAssert selection["text"].getStr == "本😀"
doAssert selection["selection"]["end"]["character"].getInt == 4
switchTo(original)
# Nothing changes before human review, accepted contents are returned but not saved.
client.diff(10, proposed)
doAssert reviewOpen() and reviewTarget == original and original.text == old
dispatchReview("a")
pump()
let approved = client.response(10)["result"]["content"]
doAssert approved[0]["text"].getStr == "FILE_SAVED" and approved[1]["text"].getStr == proposed
doAssert original.text == proposed and readFile(original.path) == old

client.diff(11, old)
dispatchReview("k")
dispatchReview("q")
pump()
doAssert client.response(11)["result"]["content"][0]["text"].getStr == "DIFF_REJECTED"
doAssert original.text == proposed
# A manually edited hunk is returned exactly, not the original proposal.
client.diff(12, old)
reviewState = reviewState.withHunk(0, "  echo \"edited\"\n")
dispatchReview("a")
pump()
let edited = client.response(12)["result"]["content"]
doAssert edited[0]["text"].getStr == "FILE_SAVED"
doAssert "edited" in edited[1]["text"].getStr and edited[1]["text"].getStr == original.text
# Target edits while the review is open must not be overwritten.
client.diff(13, old)
original.insert("human")
let human = original.text
dispatchReview("a")
pump()
doAssert client.response(13)["result"]["content"][0]["text"].getStr == "DIFF_REJECTED"
doAssert original.text == human
# Cancellation resolves the held RPC; another client cannot close it.
client.diff(14, old)
let other = IdePeer(ready: true)
other.call(15, "closeAllDiffTabs")
doAssert other.response(15)["result"]["content"][0]["text"].getStr == "CLOSED_0_DIFF_TABS"
doAssert reviewOpen()
client.call(16, "close_tab", %*{"tab_name": "test"})
doAssert client.response(14)["result"]["content"][0]["text"].getStr == "DIFF_REJECTED"
doAssert client.response(16)["result"]["content"][0]["text"].getStr == "TAB_CLOSED"
doAssert not reviewOpen() and original in reg
# Partial decisions return the actual result, and y on every hunk finishes automatically.
let multi = newBuffer("one\nkeep1\nkeep2\nkeep3\nkeep4\nlast\n")
multi.path = root / "multi.nim"
switchTo(multi)
proc multiDiff(id: int) =
  client.call(id, "openDiff", %*{"old_file_path": multi.path, "new_file_path": multi.path,
    "new_file_contents": "ONE\nkeep1\nkeep2\nkeep3\nkeep4\nLAST\n", "tab_name": "multi"})
multiDiff(30)
doAssert reviewState.hunks.len == 2
dispatchReview("y")
dispatchReview("k")
dispatchReview("q")
pump()
let partial = client.response(30)["result"]["content"]
doAssert partial[0]["text"].getStr == "FILE_SAVED"
doAssert partial[1]["text"].getStr == "ONE\nkeep1\nkeep2\nkeep3\nkeep4\nlast\n"
multiDiff(31)
dispatchReview("y")
pump()
doAssert not reviewOpen() and client.response(31)["result"]["content"][0]["text"].getStr == "FILE_SAVED"
# The caller's matching write marks the approved buffer clean; newer human edits win.
doAssert multi.modified
writeFile(multi.path, multi.text)
sleep(510)
pump()
doAssert not multi.modified
# Queue behind an unrelated review without replacing it; MCP cancellation resolves it.
switchTo(original)
beginReview(old, "User")
let unrelatedReview = reviewBuf
client.diff(32, proposed)
doAssert reviewBuf == unrelatedReview
finishReview(true)
pump()
doAssert reviewOpen()
discard handleIdeMessage(server, client, $notification("notifications/cancelled", %*{"requestId": 32}))
pump()
doAssert client.response(32)["result"]["content"][0]["text"].getStr == "DIFF_REJECTED"
# Saving uses the normal guard: a superseded file requires the user's answer.
client.call(33, "checkDocumentDirty", %*{"filePath": original.path})
doAssert client.resultData(33)["isDirty"].getBool
client.call(34, "saveDocument", %*{"filePath": original.path})
doAssert client.resultData(34)["saved"].getBool and readFile(original.path) == original.text
original.insert("more")
writeFile(original.path, "external edit with different length\n")
client.call(35, "saveDocument", %*{"filePath": original.path})
doAssert not client.resultData(35)["saved"].getBool and mode == "supersede"
doAssert readFile(original.path) == "external edit with different length\n"
setMini("n")
confirmMini()
# LSP diagnostics and compilation diagnostics are returned together.
let diagnosticClient = Client(state: lsReady)
diagnosticClient.diagnostics[uriOf(original.path)] = @[Diagnostic(line: 0, col: 0, endLine: 0, endCol: 1, severity: 1, message: "LSP error")]
clients["ide-test"] = diagnosticClient
command("compile", @[stringValue("printf 'a.nim(2, 3) Error: compilation error\\n'")])
let deadline = epochTime() + 5
while compilationJob != nil and epochTime() < deadline:
  discard pollCompilation()
  sleep(5)
doAssert compilationJob == nil
client.call(36, "getDiagnostics", %*{"uri": uriOf(original.path)})
let diagnostics = client.resultData(36)
doAssert diagnostics.len == 1 and diagnostics[0]["diagnostics"].len == 2
clients.del("ide-test")
switchTo(original)
# Tools filtered at both listing and invocation; legacy keys preserved.
eval("(setq claude-code-ide-tools '(getCurrentSelection))")
client.call(17, "darger_buffer_text")
doAssert client.response(17)["error"]["code"].getInt == -32602
doAssert keymap["C-c C r"].symName == "claude-code-send-region"
# Disabling the bridge rejects a pending review without writing the target.
eval("(setq claude-code-ide-tools '(openDiff))")
client.diff(18, old)
stopIde()
doAssert client.response(18)["result"]["content"][0]["text"].getStr == "DIFF_REJECTED"
doAssert not reviewOpen()
eval("(setq claude-code-ide nil)")
doAssert ensureIde(root) == nil
# No transport was started: all requests above use the production MCP/review handlers.
echo "IDE in-memory tools, lock permissions, review results, ownership and disable ok"
