## Language Server Protocol client: transport, framing, lifecycle, diagnostics and
## request results. No UI: darger.nim polls it from its main loop, so nothing here may
## block for long.
import std/[os, osproc, json, tables, strutils, net, nativesockets, times, algorithm]
from std/unicode import Rune, `$`, runeLen
from buffer import Buffer, snapshot, splice, offset, point
when defined(windows): import std/winlean
else:
  import std/posix
  # A server that dies mid-write must give EPIPE, not kill the editor with SIGPIPE.
  # Blocked rather than ignored: children inherit an ignored signal, while osproc
  # resets the mask of the processes it starts.
  var pipeSet, oldSet: Sigset
  discard sigemptyset(pipeSet)
  discard sigaddset(pipeSet, SIGPIPE)
  discard pthread_sigmask(SIG_BLOCK, pipeSet, oldSet)

type
  LspState* = enum lsStarting, lsReady, lsFailed, lsStopped
  Diagnostic* = object
    line*, col*, endLine*, endCol*: int  ## rune columns in the text the server saw
    severity*: int                       ## 1 error, 2 warning, 3 info, 4 hint
    message*, code*: string
  Callback* = proc(result, error: JsonNode) {.closure.}
  Client* = ref object
    state*: LspState
    nextId: int
    pending: Table[int, Callback]
    sent: Table[int, (string, float)]  # method and send time of the pending, for expire
    serverCapabilities: JsonNode
    triggerCharacters*: seq[string]
    diagnostics*: Table[string, seq[Diagnostic]]  ## by uri, sorted by position
    generation*: int                               ## bumped whenever diagnostics change
    docs: Table[string, seq[seq[Rune]]]            ## the text last sent, for UTF-16 columns
    lastError*, lastMessage*, logPath*, command*, root*: string
    exitCode*: int                                 ## the server's, once shutdown reaped it
    process: Process
    socket: Socket
    inbuf: string
    outbuf: string  # framed messages the server has not taken yet
    log: File
    closing: bool

# --- positions and uris

proc units(r: Rune): int = (if int(r) > 0xFFFF: 2 else: 1)

proc utf16Col*(line: seq[Rune], runeCol: int): int =
  ## The UTF-16 code unit column of runeCol (surrogate pairs count 2).
  for i in 0..<min(runeCol, line.len): result += units(line[i])

proc runeCol*(line: seq[Rune], utf16Col: int): int =
  ## The rune column of a UTF-16 column; one inside a pair rounds down, past the end clamps.
  var n = 0
  while result < line.len and n + units(line[result]) <= utf16Col:
    n += units(line[result])
    inc result

proc uriOf*(path: string): string =
  ## file:// uri of path, percent-encoding every byte but unreserved ones and '/'.
  var p = absolutePath(path)
  when defined(windows):
    p = "/" & p.replace('\\', '/')  # file:///C:/...
    if p.len > 2 and p[2] == ':': p[1] = p[1].toUpperAscii  # servers may send c:
  result = "file://"
  for i, ch in p:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/'} or
        (defined(windows) and ch == ':' and i == 2): result.add ch
    else: result.add '%' & toHex(ord(ch), 2)

proc pathOf*(uri: string): string =
  var s = if uri.startsWith("file://"): uri[7..^1] else: uri
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len and s[i+1] in HexDigits and s[i+2] in HexDigits:
      result.add chr(parseHexInt(s[i+1..i+2]))
      i += 3
    else:
      result.add s[i]
      inc i
  when defined(windows):
    if result.len >= 3 and result[0] == '/' and result[2] == ':': result = result[1..^1]
    result = result.replace('/', '\\')

proc rootOf*(path: string): string =
  ## The nearest ancestor holding .git, else the file's directory.
  result = parentDir(absolutePath(path))
  var dir = result
  while dir.len > 0:
    if dirExists(dir / ".git") or fileExists(dir / ".git"): return dir
    let up = parentDir(dir)
    if up == dir: break
    dir = up

# --- servers

var servers = {
  "Nim": @["nimlangserver"],
  "Python": @["pyright-langserver --stdio", "pylsp"],
  "Ruby": @["solargraph stdio", "ruby-lsp"],
  "GDScript": @["tcp://127.0.0.1:6005"],
  "JS/TS": @["typescript-language-server --stdio"],
  "C/C++": @["clangd"],
  "Rust": @["rust-analyzer"],
  "Go": @["gopls"],
  "Shell": @["bash-language-server start"],
  "JSON": @["vscode-json-language-server --stdio"],
  "YAML": @["yaml-language-server --stdio"],
  "Markdown": @["marksman server"]}.toTable

proc setServer*(lang, command: string) =
  ## Overrides lang's server; "" leaves it without one.
  servers[lang] = if command.strip.len > 0: @[command.strip] else: @[]

proc hasServer*(lang: string): bool = servers.getOrDefault(lang).len > 0

proc hostPort(command: string): (string, int) =
  let s = command[6..^1]  # after tcp://
  let colon = s.rfind(':')
  if colon < 0: raise newException(ValueError, "Expected tcp://host:port")
  (s[0..<colon], parseInt(s[colon+1..^1]))

proc connectTcp(command: string): Socket =
  let (host, port) = hostPort(command)
  result = newSocket(buffered = false)
  try: result.connect(host, Port(port), timeout = 100)
  except CatchableError:
    result.close()
    raise

proc available(command: string): bool =
  if command.startsWith("tcp://"):
    try:
      connectTcp(command).close()
      true
    except CatchableError: false
  else:
    let words = command.splitWhitespace
    words.len > 0 and findExe(words[0]).len > 0

proc serverFor*(lang: string): string =
  ## The first of lang's server commands that is installed (or whose port answers), else "".
  for command in servers.getOrDefault(lang):
    if available(command): return command

proc missingServer*(lang: string): string =
  ## Why serverFor(lang) is "", e.g. "clangd not found"; "" when lang has no server at all.
  var parts: seq[string]
  for command in servers.getOrDefault(lang):
    if command.startsWith("tcp://"): parts.add command[6..^1] & " refused"
    else: parts.add command.splitWhitespace()[0]
  if parts.len == 0: ""
  elif parts[^1].endsWith(" refused"): parts.join(", ")
  else: parts.join(", ") & " not found"

proc languageId*(lang, path: string): string =
  let ext = splitFile(path).ext.toLowerAscii
  case lang
  of "JS/TS":
    case ext
    of ".ts": "typescript"
    of ".tsx": "typescriptreact"
    of ".jsx": "javascriptreact"
    else: "javascript"
  of "C/C++": (if ext in [".c", ".h"]: "c" else: "cpp")
  of "Shell": "shellscript"
  else: lang.toLowerAscii

# --- framing

proc frame*(body: string): string = "Content-Length: " & $body.len & "\r\n\r\n" & body

proc takeFrames*(buf: var string, malformed: var bool): seq[string] =
  ## Removes the complete message bodies at the front of buf; a partial frame stays.
  ## A header without a valid Content-Length empties buf and sets malformed.
  var pos = 0
  while pos < buf.len:
    let stop = buf.find("\r\n\r\n", pos)
    if stop < 0:
      if buf.len - pos > 4096: (malformed = true; buf.setLen 0; return)
      break
    var length = -1
    for line in buf[pos..<stop].split("\r\n"):
      let colon = line.find(':')
      if colon > 0 and cmpIgnoreCase(line[0..<colon].strip, "Content-Length") == 0:
        try: length = parseInt(line[colon+1..^1].strip)
        except ValueError: discard
    if length < 0: (malformed = true; buf.setLen 0; return)
    if buf.len < stop + 4 + length: break
    result.add buf[stop+4 ..< stop+4+length]
    pos = stop + 4 + length
  if pos > 0: buf.delete(0..<pos)

# --- transport

const logCap = 4 shl 20  # bytes; clangd logs every message

proc logRaw(c: Client, s: string) =
  if c.log == nil or s.len == 0: return
  try:
    if c.log.getFilePos > logCap:  # ponytail: start over rather than rotate
      c.log.close()
      c.log = nil
      c.log = open(c.logPath, fmWrite)
      c.log.write("(log truncated)\n")
    c.log.write(s)
    c.log.flushFile()
  except IOError: discard

proc logLine(c: Client, s: string) = c.logRaw(s & "\n")

proc wouldBlock(): bool =
  let e = osLastError().int
  when defined(windows): e == WSAEWOULDBLOCK
  else: e == EAGAIN.int or e == EWOULDBLOCK.int or e == EINTR.int

proc append(into: var string, p: pointer, n: int) =
  let old = into.len
  into.setLen(old + n)
  copyMem(into[old].addr, p, n)

when defined(windows):
  proc drainPipe(h: Handle, into: var string): bool =
    ## Appends what the pipe holds without blocking; false once it is broken (exited).
    while true:
      var avail: int32
      if not peekNamedPipe(h, nil, 0, nil, avail.addr, nil): return false
      if avail <= 0: return true
      var chunk = newString(avail)
      var got: int32
      if readFile(h, chunk[0].addr, avail, got.addr, nil) == 0: return false
      into.add chunk[0..<got]
else:
  proc drainFd(fd: cint, into: var string): bool =
    ## Appends what the non-blocking fd holds; false at end of file.
    var chunk: array[65536, char]
    while true:
      let n = posix.read(fd, chunk[0].addr, chunk.len)
      if n > 0: into.append(chunk[0].addr, n)
      elif n == 0: return false
      else: return wouldBlock()

proc drainSocket(s: Socket, into: var string): bool =
  var chunk: array[65536, char]
  while true:
    let n = s.recv(chunk[0].addr, chunk.len)
    if n > 0: into.append(chunk[0].addr, n)
    elif n == 0: return false
    else: return wouldBlock()

proc exited(c: Client): bool =
  try: c.process.peekExitCode() != -1
  except OSError: true

proc fail(c: Client, why: string) =
  ## Marks c failed, stops its server (poll reaps it) and answers every pending request
  ## with an error.
  if c.state in {lsFailed, lsStopped}: return
  c.state = lsFailed
  c.lastError = why
  c.outbuf = ""
  if not c.closing:  # shutdown stops them itself
    if c.process != nil and not c.exited:
      try: c.process.terminate()
      except CatchableError: discard
    if c.socket != nil:
      c.socket.close()
      c.socket = nil
  c.diagnostics.clear()  # stale marks would outlive the server that made them
  inc c.generation
  c.logLine("failed: " & why)
  let waiting = c.pending
  c.pending.clear()
  c.sent.clear()
  let error = %*{"code": -32099, "message": why}
  for cb in waiting.values: cb(newJNull(), error)

proc flush(c: Client) =
  ## Writes as much of outbuf as the server takes without blocking (the rest waits for
  ## the next poll), so a server busy writing to us cannot deadlock against our write.
  var sent = 0
  if c.socket != nil:
    while sent < c.outbuf.len:
      let n = c.socket.send(c.outbuf[sent].addr, c.outbuf.len - sent)
      if n > 0: sent += n
      elif n < 0 and wouldBlock(): break
      else: raise newException(IOError, "Connection lost")
  else:
    when defined(windows):
      # ponytail: an anonymous pipe cannot be non-blocking, so write 4 KB at a time and drain
      # the server's output in between; a single reply larger than its pipe can still stall.
      while sent < c.outbuf.len:
        var errors = ""
        discard drainPipe(Handle(c.process.errorHandle), errors)
        c.logRaw(errors)
        discard drainPipe(Handle(c.process.outputHandle), c.inbuf)
        var n: int32
        if writeFile(Handle(c.process.inputHandle), c.outbuf[sent].addr,
            int32(min(4096, c.outbuf.len - sent)), n.addr, nil) == 0:
          raiseOSError(osLastError())
        sent += n
    else:
      while sent < c.outbuf.len:
        let n = posix.write(c.process.inputHandle, c.outbuf[sent].addr, c.outbuf.len - sent)
        if n > 0: sent += n
        elif n < 0 and wouldBlock(): break
        else: raiseOSError(osLastError())
  if sent > 0: c.outbuf.delete(0..<sent)

proc sendRaw(c: Client, data: string) =
  if c.outbuf.len > 64 shl 20: raise newException(IOError, "Server stopped reading")
  c.outbuf.add data
  c.flush()

proc send(c: Client, msg: JsonNode) =
  if c.state in {lsFailed, lsStopped}: return
  try: c.sendRaw(frame($msg))
  except CatchableError as e: c.fail("write: " & e.msg)

proc request*(c: Client, meth: string, params: JsonNode, cb: Callback = nil): int {.discardable.} =
  ## Sends a request; cb gets (result, error) from poll, error nil on success.
  result = c.nextId
  inc c.nextId
  if c.state in {lsFailed, lsStopped}:
    if cb != nil: cb(newJNull(), %*{"code": -32099, "message": c.lastError})
    return
  if cb != nil:
    c.pending[result] = cb
    # initialize has no deadline (a slow server is still starting); shutdown has its own
    if meth notin ["initialize", "shutdown"]: c.sent[result] = (meth, epochTime())
  c.send(%*{"jsonrpc": "2.0", "id": result, "method": meth, "params": params})

proc notify*(c: Client, meth: string, params: JsonNode) =
  c.send(%*{"jsonrpc": "2.0", "method": meth, "params": params})

proc newClient*(command, root: string, lang = ""): Client =
  ## Spawns the server (or connects to tcp://host:port); failure leaves it lsFailed.
  result = Client(command: command, root: root, nextId: 1, serverCapabilities: newJNull())
  var tag = if lang.len > 0: lang else: command.replace("tcp://", "").splitWhitespace().join(" ")
  for ch in tag.mitems:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '+', '-', '_'}: ch = '-'
  result.logPath = getTempDir() / ("darger-lsp-" & tag & "-" & $getCurrentProcessId() & ".log")
  try: result.log = open(result.logPath, fmWrite)
  except IOError: discard
  result.logLine("start " & command & " in " & root)
  try:
    if command.startsWith("tcp://"):
      result.socket = connectTcp(command)
      result.socket.getFd.setBlocking(false)
    else:
      let words = command.splitWhitespace
      if words.len == 0: raise newException(ValueError, "Empty server command")
      let exe = findExe(words[0])
      if exe.len == 0: raise newException(OSError, words[0] & " not found")
      let dir = if dirExists(root): root else: ""
      when defined(windows):
        # npm installs servers as .cmd scripts, which CreateProcess cannot start directly.
        let script = splitFile(exe).ext.toLowerAscii in [".cmd", ".bat"]
        result.process = startProcess(if script: "cmd.exe" else: exe, dir,
          (if script: @["/d", "/c", exe] else: @[]) & words[1..^1], options = {poUsePath, poDaemon})
      else:
        result.process = startProcess(exe, dir, words[1..^1], options = {poUsePath})
        for fd in [result.process.inputHandle, result.process.outputHandle,
                   result.process.errorHandle]:
          discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
  except CatchableError as e:
    result.state = lsFailed
    result.lastError = e.msg
    result.logLine("failed: " & e.msg)

# --- messages

proc publish(c: Client, params: JsonNode) =
  var uri = params{"uri"}.getStr
  # Servers re-encode uris their own way (clangd leaves ':' unescaped), so key by ours.
  if uri.startsWith("file://"): uri = uriOf(pathOf(uri))
  let lines = c.docs.getOrDefault(uri)
  proc at(p: JsonNode): (int, int) =
    let line = p{"line"}.getInt
    let unit = p{"character"}.getInt
    (line, if line in 0..lines.high: runeCol(lines[line], unit) else: unit)
  var ds: seq[Diagnostic]
  for d in params{"diagnostics"}.getElems:
    let (l0, c0) = at(d{"range", "start"})
    let (l1, c1) = at(d{"range", "end"})
    let code = d{"code"}
    ds.add Diagnostic(line: l0, col: c0, endLine: l1, endCol: c1,
      severity: clamp(d{"severity"}.getInt(1), 1, 4), message: d{"message"}.getStr,
      code: if code == nil or code.kind == JNull: "" elif code.kind == JString: code.getStr else: $code)
  ds.sort(proc(a, b: Diagnostic): int = cmp((a.line, a.col), (b.line, b.col)))
  c.diagnostics[uri] = ds
  inc c.generation

proc handle(c: Client, body: string): bool =
  var msg: JsonNode
  try: msg = parseJson(body)
  except CatchableError:
    c.logLine("unparsable message: " & body[0..<min(body.len, 200)])
    return false
  if msg.kind != JObject: return false
  let meth = msg{"method"}.getStr
  let id = msg{"id"}
  if meth.len == 0:  # a response
    if id == nil or id.kind != JInt: return false
    let cb = c.pending.getOrDefault(id.getInt)
    c.pending.del id.getInt
    c.sent.del id.getInt
    let error = msg{"error"}
    if error != nil: c.logLine("error " & $error)
    if cb != nil: cb(if msg{"result"} != nil: msg{"result"} else: newJNull(), error)
    return true
  if id != nil:  # a request from the server: answer so it does not wait on us
    var res: JsonNode
    case meth
    of "workspace/configuration":
      res = newJArray()
      for _ in msg{"params", "items"}.getElems: res.add newJNull()
    of "client/registerCapability", "client/unregisterCapability",
       "window/workDoneProgress/create", "window/showMessageRequest": res = newJNull()
    else: discard
    if res != nil: c.send(%*{"jsonrpc": "2.0", "id": id, "result": res})
    else: c.send(%*{"jsonrpc": "2.0", "id": id,
      "error": {"code": -32601, "message": "Unsupported: " & meth}})
    return false
  case meth
  of "textDocument/publishDiagnostics":
    c.publish(msg{"params"})
    true
  of "window/showMessage":
    c.lastMessage = msg{"params", "message"}.getStr
    c.logLine("message: " & c.lastMessage)
    true
  of "window/logMessage":
    c.logLine(msg{"params", "message"}.getStr)
    false
  else: false

proc poll*(c: Client): bool =
  ## Writes what is queued, reads everything available and dispatches it; true when
  ## anything changed.
  if c.state in {lsFailed, lsStopped}:
    if c.process != nil and not c.closing and c.exited:  # reap the server fail stopped
      c.process.close()
      c.process = nil
    return false
  var alive = true
  var errors = ""
  try: c.flush()
  except CatchableError as e:
    c.logLine("write: " & e.msg)
    alive = false
  try:
    if c.socket != nil:
      if not drainSocket(c.socket, c.inbuf): alive = false
    else:
      when defined(windows):
        discard drainPipe(Handle(c.process.errorHandle), errors)
        if not drainPipe(Handle(c.process.outputHandle), c.inbuf): alive = false
      else:
        discard drainFd(c.process.errorHandle, errors)
        if not drainFd(c.process.outputHandle, c.inbuf): alive = false
  except CatchableError as e:
    c.logLine("read: " & e.msg)
    alive = false
  c.logRaw(errors)
  var malformed = false
  for body in takeFrames(c.inbuf, malformed):
    if c.handle(body): result = true
  if malformed: c.logLine("malformed header; input dropped")
  if not alive and not c.closing:
    c.fail(if c.socket != nil: "Connection closed" else: "Server exited")
    result = true

proc expire*(c: Client, timeout = 10.0): seq[string] =
  ## Drops the callbacks of requests unanswered after timeout seconds (cancelling them
  ## at the server) and returns their methods.
  let now = epochTime()
  var late: seq[int]
  for id, (meth, at) in c.sent:
    if now - at >= timeout:
      late.add id
      result.add meth
  for id in late:
    c.sent.del id
    c.pending.del id
    c.logLine("timed out: " & $id)
    c.notify("$/cancelRequest", %*{"id": id})

proc initialize*(c: Client, cb: Callback = nil) =
  ## Sends initialize; on its answer c becomes lsReady and 'initialized' follows.
  let root = if c.root.len > 0: c.root else: getCurrentDir()
  let params = %*{
    "processId": getCurrentProcessId(),
    "clientInfo": {"name": "darger"},
    "rootPath": root,
    "rootUri": uriOf(root),
    "workspaceFolders": [{"uri": uriOf(root), "name": extractFilename(root)}],
    "capabilities": {
      "general": {"positionEncodings": ["utf-16"]},
      "textDocument": {
        "synchronization": {"didSave": true},
        "completion": {"completionItem": {"snippetSupport": false,
          "documentationFormat": ["plaintext"]}},
        "hover": {"contentFormat": ["plaintext", "markdown"]},
        "definition": {}, "references": {}, "formatting": {},
        "publishDiagnostics": {}}}}
  c.request("initialize", params, proc(res, error: JsonNode) =
    if error != nil and error.kind != JNull:
      c.fail("initialize: " & error{"message"}.getStr)
    elif c.state == lsStarting:
      c.serverCapabilities = if res{"capabilities"} != nil: res{"capabilities"} else: newJObject()
      for t in c.serverCapabilities{"completionProvider", "triggerCharacters"}.getElems:
        c.triggerCharacters.add t.getStr
      c.state = lsReady
      c.notify("initialized", newJObject())
    if cb != nil: cb(res, error))

# --- documents

proc textOf(lines: seq[seq[Rune]]): string =
  for i, line in lines:
    if i > 0: result.add '\n'
    result.add $line

proc didOpen*(c: Client, uri, languageId: string, lines: seq[seq[Rune]], version: int) =
  c.docs[uri] = lines
  c.notify("textDocument/didOpen", %*{"textDocument": {"uri": uri, "languageId": languageId,
    "version": version, "text": textOf(lines)}})

proc didChange*(c: Client, uri: string, lines: seq[seq[Rune]], version: int) =
  ## Full sync: the whole text each time.
  c.docs[uri] = lines
  c.notify("textDocument/didChange", %*{"textDocument": {"uri": uri, "version": version},
    "contentChanges": [{"text": textOf(lines)}]})

proc didSave*(c: Client, uri: string) =
  c.notify("textDocument/didSave", %*{"textDocument": {"uri": uri}})

proc didClose*(c: Client, uri: string) =
  c.docs.del uri
  if uri in c.diagnostics:
    c.diagnostics.del uri
    inc c.generation
  c.notify("textDocument/didClose", %*{"textDocument": {"uri": uri}})

# --- shutdown

proc askShutdown(c: Client) =
  c.request("shutdown", newJNull(), proc(res, error: JsonNode) =
    if c.state == lsReady: c.notify("exit", newJNull()))

proc shutdown*(cs: openArray[Client]) =
  ## Asks every server to exit, waits up to 1 s for all of them, then kills the rest.
  ## ponytail: a TCP server (Godot) is shared with its editor, so it is only disconnected.
  var waiting: seq[Client]
  for c in cs:
    if c == nil or c.state == lsStopped: continue
    c.closing = true
    if c.process != nil:
      if c.state == lsReady: c.askShutdown()
      waiting.add c
  let deadline = epochTime() + 1
  while epochTime() < deadline:
    var left = false
    for c in waiting:
      if not c.exited:
        discard c.poll()
        left = true
    if not left: break
    sleep(10)
  for c in cs:
    if c == nil or c.state == lsStopped: continue
    if c.process != nil:
      try:
        if not c.exited:
          c.process.terminate()
          let stop = epochTime() + 0.2
          while not c.exited and epochTime() < stop: sleep(10)
          if not c.exited: c.process.kill()
        c.exitCode = c.process.waitForExit(500)
        c.process.close()
      except CatchableError as e: c.logLine("shutdown: " & e.msg)
      c.process = nil
    if c.socket != nil:
      c.socket.close()
      c.socket = nil
    c.state = lsStopped
    c.pending.clear()
    c.sent.clear()
    if c.log != nil:  # named per editor process, so not left behind
      c.log.close()
      c.log = nil
      discard tryRemoveFile(c.logPath)

proc shutdown*(c: Client) = shutdown([c])

# --- results

type
  TextEdit* = object
    line*, col*, endLine*, endCol*: int  ## UTF-16 columns
    newText*: string
  CompItem* = object
    label*, detail*, filterText*, sortText*: string
    text*: string        ## what accepting inserts: insertText or textEdit.newText, snippets stripped
    kind*: int
    edit*: bool          ## text replaces from (line, col), UTF-16, instead of the prefix start
    line*, col*: int
    extra*: seq[TextEdit]  ## additionalTextEdits, e.g. clangd's #include
  Location* = object
    path*: string
    line*, col*: int     ## the start, UTF-16 column (rune column once converted)

proc snippetText(s: string, i: var int, nested: bool): string =
  while i < s.len:
    let ch = s[i]
    if ch == '\\' and i + 1 < s.len and s[i+1] in {'$', '}', '\\'}:
      result.add s[i+1]
      i += 2
    elif ch == '}' and nested:
      inc i
      return
    elif ch == '$' and i + 1 < s.len and s[i+1] in IdentChars:  # $1, $0, $VAR
      inc i
      while i < s.len and s[i] in IdentChars: inc i
    elif ch == '$' and i + 1 < s.len and s[i+1] == '{':
      i += 2
      while i < s.len and s[i] in IdentChars: inc i
      if i < s.len and s[i] == ':':
        inc i
        result.add snippetText(s, i, true)
      elif i < s.len and s[i] == '|':  # ${1|a,b|}: the first choice
        inc i
        var first = true
        while i < s.len and not (s[i] == '|' and i + 1 < s.len and s[i+1] == '}'):
          if s[i] == ',': first = false
          elif first: result.add s[i]
          inc i
        i += 2
      elif i < s.len and s[i] == '}': inc i
    else:
      result.add ch
      inc i

proc stripSnippet*(s: string): string =
  ## A snippet's plain text: $1 / $0 / $VAR dropped, ${1:x} -> x, ${1|a,b|} -> a.
  var i = 0
  snippetText(s, i, false)

proc parseEdits*(res: JsonNode): seq[TextEdit] =
  if res == nil or res.kind != JArray: return
  for n in res:
    let r = n{"range"}
    if r == nil: continue
    result.add TextEdit(line: r{"start", "line"}.getInt, col: r{"start", "character"}.getInt,
      endLine: r{"end", "line"}.getInt, endCol: r{"end", "character"}.getInt,
      newText: n{"newText"}.getStr.replace("\r\n", "\n"))

proc incompleteList*(res: JsonNode): bool =
  ## A CompletionList the server cut short: narrowing it needs a new request.
  res != nil and res.kind == JObject and res{"isIncomplete"}.getBool

proc parseCompletion*(res: JsonNode): seq[CompItem] =
  ## CompletionItem[] or CompletionList, sorted by sortText (else label).
  if res == nil: return
  let items = if res.kind == JArray: res elif res.kind == JObject: res{"items"} else: nil
  if items == nil or items.kind != JArray: return
  for n in items:
    if n.kind != JObject: continue
    var it = CompItem(label: n{"label"}.getStr.strip, detail: n{"detail"}.getStr.strip,
      filterText: n{"filterText"}.getStr, sortText: n{"sortText"}.getStr, kind: n{"kind"}.getInt)
    let edit = n{"textEdit"}
    if edit != nil and edit.kind == JObject:
      it.text = edit{"newText"}.getStr
      let start = if edit{"range"} != nil: edit{"range", "start"} else: edit{"insert", "start"}
      if start != nil:
        it.edit = true
        it.line = start{"line"}.getInt
        it.col = start{"character"}.getInt
    elif n{"insertText"} != nil: it.text = n{"insertText"}.getStr
    else: it.text = it.label
    if n{"insertTextFormat"}.getInt(1) == 2: it.text = stripSnippet(it.text)
    it.extra = parseEdits(n{"additionalTextEdits"})
    result.add it
  result.sort(proc(a, b: CompItem): int =
    cmp(if a.sortText.len > 0: a.sortText else: a.label, if b.sortText.len > 0: b.sortText else: b.label))

proc kindTag*(kind: int): string =
  ## One letter per CompletionItemKind: f function, v variable, m method, c class/struct,
  ## k keyword, t type, s snippet, o other.
  case kind
  of 3, 4: "f"
  of 2: "m"
  of 5, 6, 10, 21: "v"
  of 7, 22: "c"
  of 14: "k"
  of 8, 13, 25: "t"
  of 15: "s"
  else: "o"

proc parseLocations*(res: JsonNode): seq[Location] =
  ## Location | Location[] | LocationLink[] (its targetSelectionRange); null = none.
  if res == nil: return
  let all = if res.kind == JArray: res.getElems elif res.kind == JObject: @[res] else: @[]
  for n in all:
    if n.kind != JObject: continue
    let uri = if n{"targetUri"} != nil: n{"targetUri"}.getStr else: n{"uri"}.getStr
    let r = if n{"targetSelectionRange"} != nil: n{"targetSelectionRange"}
            elif n{"targetRange"} != nil: n{"targetRange"} else: n{"range"}
    if uri.len == 0 or r == nil: continue
    result.add Location(path: pathOf(uri), line: r{"start", "line"}.getInt,
      col: r{"start", "character"}.getInt)

proc applyEdits*(b: Buffer, edits: openArray[TextEdit]): bool =
  ## Applies edits made against b's current text as one undo step, in reverse document
  ## order; the cursor stays on the same text where it can. An edit overlapping one after
  ## it is invalid and skipped. False when there are none.
  ## ponytail: one splice (a full-text rebuild) per edit; batch them if huge files matter.
  if edits.len == 0: return false
  proc at(line, unit: int): int =
    if line > b.lines.high: return b.offset((b.lines.high, b.lines[^1].len))
    let l = max(0, line)
    b.offset((l, runeCol(b.lines[l], unit)))
  var spans: seq[(int, int, int, string)]  # start, index, end, text
  for i, e in edits: spans.add (at(e.line, e.col), i, at(e.endLine, e.endCol), e.newText)
  # A replace goes before an insert at its start, and inserts at one position keep their
  # array order: the later one goes in first.
  spans.sort(proc(x, y: (int, int, int, string)): int = cmp((y[0], y[2], y[1]), (x[0], x[2], x[1])))
  var cursor = b.offset(b.cursor)
  var limit = high(int)  # the start of the span applied last
  b.snapshot()
  for (a, _, z0, s) in spans:
    let z = max(a, z0)
    if z > limit: continue
    limit = a
    let n = s.runeLen
    if z <= cursor: cursor += n - (z - a)
    elif a < cursor: cursor = a + min(n, cursor - a)  # inside a replaced span
    b.splice(a, z, s)
  b.cursor = b.point(cursor)
  true

proc hoverLines*(res: JsonNode): seq[string] =
  ## The hover's text, lightly de-markdowned: fence lines dropped, backticks removed,
  ## heading #s stripped, blank runs collapsed.
  if res == nil or res.kind != JObject: return
  var text = ""
  var todo = @[res{"contents"}]
  while todo.len > 0:
    let n = todo.pop()
    if n == nil: continue
    case n.kind
    of JString: text.add n.getStr & "\n\n"
    of JObject: text.add n{"value"}.getStr & "\n\n"
    of JArray:
      for i in countdown(n.len - 1, 0): todo.add n[i]
    else: discard
  for raw in text.replace("\r", "").split('\n'):
    if raw.strip.startsWith("```"): continue
    var s = raw.replace("`", "").strip(leading = false)
    if s.startsWith("#"): s = s.strip(trailing = false, chars = {'#'}).strip(trailing = false)
    if s.len == 0 and (result.len == 0 or result[^1].len == 0): continue
    result.add s
  while result.len > 0 and result[^1].len == 0: result.setLen(result.len - 1)

# --- views of the results, for darger.nim

proc diagMarks*(lines: seq[seq[Rune]], ds: seq[Diagnostic]): seq[seq[int8]] =
  ## Per rune of lines, the most severe diagnostic covering it (0 = none; a line without
  ## any stays empty). A line's extra last entry is its end, where a zero-width
  ## diagnostic past the text is marked.
  result = newSeq[seq[int8]](lines.len)
  for d in ds:
    for line in max(0, d.line)..min(d.endLine, lines.high):
      let len = lines[line].len
      let a = if line == d.line: min(d.col, len) else: 0
      var z = if line == d.endLine: min(d.endCol, len) else: len
      if line == d.line and z <= a: z = a + 1
      if a >= z: continue
      if result[line].len == 0: result[line] = newSeq[int8](len + 1)
      for i in a..<z:
        if result[line][i] == 0 or d.severity < result[line][i]: result[line][i] = int8(d.severity)

proc diagRows*(ds: seq[Diagnostic]): seq[string] =
  ## consult-flymake rows: "L:C  E  message" (first line), heads padded to one width.
  var heads: seq[string]
  var width = 0
  for d in ds:
    heads.add $(d.line + 1) & ":" & $(d.col + 1)
    width = max(width, heads[^1].len)
  for i, d in ds:
    let nl = d.message.find('\n')
    result.add alignLeft(heads[i], width) & "  " & "EWIH"[d.severity - 1] & "  " &
      (if nl >= 0: d.message[0..<nl] else: d.message)

proc referenceRows*(locs: seq[Location], linesOf: proc(path: string): seq[seq[Rune]],
                    nameOf: proc(path: string): string): (seq[Location], seq[string]) =
  ## M-? rows "name:line: text", grouped by file in the order first seen and sorted
  ## within one, with their targets in rune columns.
  var files: seq[string]
  var byFile: Table[string, seq[Location]]
  for l in locs:
    if l.path notin byFile: files.add l.path
    byFile.mgetOrPut(l.path, @[]).add l
  for f in files:
    let lines = linesOf(f)
    let name = nameOf(f)
    var group = byFile[f]
    group.sort(proc(x, y: Location): int = cmp((x.line, x.col), (y.line, y.col)))
    for l in group:
      let text = if l.line in 0..lines.high: lines[l.line] else: @[]
      result[0].add Location(path: f, line: l.line, col: runeCol(text, l.col))
      result[1].add name & ":" & $(l.line + 1) & ": " &
        strip($text[0 ..< min(text.len, 200)], trailing = false)
