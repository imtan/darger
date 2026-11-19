{.define: headless.}
import std/[os, strutils, json, tables, net, times]
import ../src/[core, buffer, buffers, render, lisp, review, ideprotocol, ideserver, lsp, syntax]
import ../src/ext/[idebridge, agent, claude, compile, revert]

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
proc masked(text: string, opcode = 1): string =
  result = wsFrame(text, opcode)
  let offset = if text.len < 126: 2 elif text.len <= 65535: 4 else: 10
  result[1] = char(ord(result[1]) or 128)
  result = result[0..<offset] & "abcd" & text
  for i in 0..<text.len: result[offset+4+i] = char(ord(text[i]) xor ord("abcd"[i mod 4]))
proc receive(socket: Socket): tuple[opcode: int, text: string] =
  let head = socket.recv(2, timeout = 2000)
  doAssert head.len == 2
  result.opcode = ord(head[0]) and 15
  var size = ord(head[1]) and 127
  if size in [126, 127]:
    let bytes = socket.recv((if size == 126: 2 else: 8), timeout = 2000)
    size = 0
    for byte in bytes: size = size * 256 + ord(byte)
  if size > 0: result.text = socket.recv(size, timeout = 2000)
proc response(socket: Socket, id: int): JsonNode =
  for i in 0..40:
    let packet = socket.receive()
    doAssert packet.opcode == 1
    let value = parseJson(packet.text)
    if value{"id"}.getInt(-1) == id: return value
  raise newException(ValueError, "Missing response")
proc connect(server: IdeServer, token: string): Socket =
  result = newSocket()
  result.connect("127.0.0.1", Port(server.port))
  result.send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nx-claude-code-ide-authorization: " & token & "\r\n\r\n")
  pump()
proc readHeaders(socket: Socket): string =
  while not result.endsWith("\r\n\r\n"):
    let byte = socket.recv(1, timeout = 2000)
    doAssert byte.len == 1, "Connection closed during handshake"
    result.add byte
proc call(socket: Socket, id: int, name: string, args = newJObject()) =
  socket.send(masked($(%*{"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": name, "arguments": args}})))
  pump()
proc diff(socket: Socket, id: int, text: string, tab = "test") =
  socket.call(id, "openDiff", %*{"old_file_path": root / "a.nim", "new_file_path": root / "a.nim", "new_file_contents": text, "tab_name": tab})
proc resultData(socket: Socket, id: int): JsonNode =
  parseJson(socket.response(id)["result"]["content"][0]["text"].getStr)

let server = ensureIde(root)
let path = server.lockPath
let lock = parseJson(readFile(path))
doAssert lock["pid"].getInt == getCurrentProcessId()
doAssert lock["workspaceFolders"][0].getStr == root and lock["ideName"].getStr == "darger"
doAssert lock["authToken"].getStr.len == 32 and lock["transport"].getStr == "ws"
doAssert getFilePermissions(path) == {fpUserRead, fpUserWrite}
doAssert ideEnvironment(root) == @[("CLAUDE_CODE_SSE_PORT", $server.port), ("ENABLE_IDE_INTEGRATION", "true")]
# Never overwrite another lock or symlink.
var collision = false
try: writeLock(path, "overwrite")
except OSError: collision = true
doAssert collision and parseJson(readFile(path)) == lock
let unrelated = parentDir(path) / "other.lock"
writeFile(unrelated, "keep")
let bad = connect(server, "incorrect")
doAssert bad.readHeaders().startsWith("HTTP/1.1 401")
bad.close()
let client = connect(server, server.token)
doAssert client.readHeaders().startsWith("HTTP/1.1 101")
doAssert server.connected() and "Claude ⇄" in modeLineHook()
client.send(masked("probe", 9))
pump()
let pong = client.receive()
doAssert pong == (10, "probe")
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
let other = connect(server, server.token)
doAssert other.readHeaders().startsWith("HTTP/1.1 101")
other.call(15, "closeAllDiffTabs")
doAssert other.response(15)["result"]["content"][0]["text"].getStr == "CLOSED_0_DIFF_TABS"
doAssert reviewOpen()
client.call(16, "close_tab", %*{"tab_name": "test"})
doAssert client.response(14)["result"]["content"][0]["text"].getStr == "DIFF_REJECTED"
doAssert client.response(16)["result"]["content"][0]["text"].getStr == "TAB_CLOSED"
doAssert not reviewOpen() and original in reg
# Tools filtered at both listing and invocation; legacy keys preserved.
eval("(setq claude-code-ide-tools '(getCurrentSelection))")
client.call(17, "darger_buffer_text")
doAssert client.response(17)["error"]["code"].getInt == -32602
doAssert keymap["C-c C r"].symName == "claude-code-send-region"
# Disconnecting rejects its pending review, and the server accepts a fresh client.
eval("(setq claude-code-ide-tools '(openDiff))")
client.diff(18, old)
client.close()
pump()
doAssert not reviewOpen()
other.close()
eval("(setq claude-code-ide nil)")
pump()
doAssert not fileExists(path) and readFile(unrelated) == "keep"
doAssert ideServers.len == 0 and "Claude ⇄" notin modeLineHook()
doAssert ensureIde(root) == nil
# Close frames complete without leaving a live peer.
eval("(setq claude-code-ide t)")
let again = ensureIde(root)
let closing = connect(again, again.token)
doAssert closing.readHeaders().startsWith("HTTP/1.1 101")
closing.send(masked("\x03\xe8", 8))
pump()
doAssert closing.receive() == (8, "\x03\xe8")
closing.close()
stopIde()
echo "IDE loopback auth, lock lifecycle, tools, review results, ownership, disconnect and disable ok"
