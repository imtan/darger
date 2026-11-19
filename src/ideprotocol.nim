## Claude's WebSocket MCP dialect. Pure framing and RPC; no editor or filesystem.
import std/[base64, sha1, strutils, tables, json, unicode, sequtils]

const maxIdeMessage* = 8 * 1024 * 1024

type
  WsFrame* = object
    opcode*: int
    final*: bool
    payload*: string
  WsDecoder* = object
    fragment: string
    fragmented: bool

proc wsAccept*(key: string): string =
  let digest = Sha1Digest(secureHash(key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
  encode(digest)

proc handshake*(request, token: string): string =
  let lines = request.split("\r\n")
  var headers: Table[string, string]
  if lines.len == 0 or lines[0] != "GET / HTTP/1.1":
    return "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
  for line in lines[1..^1]:
    let at = line.find(':')
    if at > 0:
      let name = line[0..<at].toLowerAscii
      if name in headers: return "HTTP/1.1 400 Bad Request\r\n\r\n"
      headers[name] = strutils.strip(line[at+1..^1])
  if token.len == 0 or headers.getOrDefault("x-claude-code-ide-authorization") != token:
    return "HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n"
  let key = headers.getOrDefault("sec-websocket-key")
  var validKey = false
  try: validKey = decode(key).len == 16
  except ValueError: discard
  if not validKey or headers.getOrDefault("sec-websocket-version") != "13" or
      headers.getOrDefault("upgrade").toLowerAscii != "websocket" or
      "upgrade" notin headers.getOrDefault("connection").toLowerAscii.split(",").mapIt(strutils.strip(it)):
    return "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
  "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " & wsAccept(key) & "\r\n\r\n"

proc wsFrame*(payload: string, opcode = 1): string =
  result.add char(0x80 or opcode)
  if payload.len < 126: result.add char(payload.len)
  elif payload.len <= 65535:
    result.add char(126)
    for shift in [8, 0]: result.add char((payload.len shr shift) and 255)
  else:
    result.add char(127)
    for shift in countdown(56, 0, 8): result.add char((uint64(payload.len) shr shift) and 255)
  result.add payload

proc takeFrame*(input: var string, frame: var WsFrame): bool =
  if input.len < 2: return
  let a = ord(input[0])
  let b = ord(input[1])
  let op = a and 15
  if (a and 0x70) != 0 or (b and 0x80) == 0 or op notin [0, 1, 8, 9, 10]:
    raise newException(ValueError, "Invalid WebSocket frame")
  var size = uint64(b and 127)
  var offset = 2
  if size in [126'u64, 127'u64]:
    let count = if size == 126: 2 else: 8
    if input.len < 2 + count: return
    size = 0
    for i in 2..<2+count: size = (size shl 8) or uint64(ord(input[i]))
    offset += count
    if (count == 2 and size < 126) or (count == 8 and size < 65536):
      raise newException(ValueError, "Non-canonical WebSocket length")
  if size > maxIdeMessage.uint64 or (op >= 8 and (size > 125 or (a and 128) == 0)):
    raise newException(ValueError, "WebSocket frame too large or fragmented control")
  if input.len < offset + 4 + int(size): return
  frame = WsFrame(opcode: op, final: (a and 128) != 0, payload: newString(int(size)))
  for i in 0..<int(size): frame.payload[i] = char(ord(input[offset+4+i]) xor ord(input[offset+i mod 4]))
  input = input[offset+4+int(size)..^1]
  if op == 8:
    if size == 1: raise newException(ValueError, "Invalid close payload")
    if size >= 2:
      let code = ord(frame.payload[0]) * 256 + ord(frame.payload[1])
      if code < 1000 or code >= 5000 or code in [1004, 1005, 1006, 1015] or
          (code >= 1016 and code < 3000) or validateUtf8(frame.payload[2..^1]) != -1:
        raise newException(ValueError, "Invalid close status")
  true

proc message*(decoder: var WsDecoder, frame: WsFrame): string =
  ## Control frames are handled by transport; an empty result is not a message.
  if frame.opcode >= 8: return
  if frame.opcode == 0:
    if not decoder.fragmented: raise newException(ValueError, "Unexpected continuation")
  elif decoder.fragmented: raise newException(ValueError, "Missing continuation")
  decoder.fragment.add frame.payload
  if decoder.fragment.len > maxIdeMessage: raise newException(ValueError, "Message too large")
  decoder.fragmented = not frame.final
  if frame.final:
    result = move(decoder.fragment)
    if validateUtf8(result) != -1: raise newException(ValueError, "Invalid UTF-8")

proc rpcResult*(id, value: JsonNode): JsonNode = %*{"jsonrpc": "2.0", "id": id, "result": value}
proc rpcError*(id: JsonNode, code: int, message: string): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}
proc toolText*(text: string): JsonNode = %*{"content": [{"type": "text", "text": text}]}
proc toolJson*(value: JsonNode): JsonNode = toolText($value)
proc diffResult*(accepted: bool, contents, tab: string): JsonNode =
  %*{"content": [{"type": "text", "text": (if accepted: "FILE_SAVED" else: "DIFF_REJECTED")},
    {"type": "text", "text": (if accepted: contents else: tab)}]}
proc notification*(name: string, params: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "method": name, "params": params}
proc lockInfo*(pid: int, roots: seq[string], token: string): JsonNode =
  %*{"pid": pid, "workspaceFolders": roots, "ideName": "darger", "transport": "ws", "authToken": token}

type ToolHandler* = proc(name: string, args, id: JsonNode): JsonNode {.closure.}

proc dispatchRpc*(wire: string, tools: JsonNode, handler: ToolHandler): JsonNode =
  var req: JsonNode
  try: req = parseJson(wire)
  except ValueError: return rpcError(newJNull(), -32700, "Parse error")
  if req.kind != JObject or req{"jsonrpc"}.getStr != "2.0" or (not req.hasKey("method") or req["method"].kind != JString):
    return rpcError(newJNull(), -32600, "Invalid Request")
  if not req.hasKey("id"): return nil # notifications never receive a response
  let id = req["id"]
  if id.kind notin {JString, JInt, JNull}: return rpcError(newJNull(), -32600, "Invalid id")
  case req["method"].getStr
  of "initialize":
    result = rpcResult(id, %*{"protocolVersion": "2025-03-26", "capabilities": {"tools": {"listChanged": true}},
      "serverInfo": {"name": "darger", "version": "0.1.0"}})
  of "ping": result = rpcResult(id, newJObject())
  of "tools/list": result = rpcResult(id, %*{"tools": tools})
  of "tools/call":
    let name = req{"params", "name"}.getStr
    var spec: JsonNode
    for t in tools:
      if t{"name"}.getStr == name: spec = t
    if spec == nil: return rpcError(id, -32602, "Unknown or disabled tool: " & name)
    let args = req{"params", "arguments"}
    if args != nil and args.kind != JObject: return rpcError(id, -32602, "Arguments must be an object")
    let values = if args == nil: newJObject() else: args
    for key in spec["inputSchema"]["required"]:
      if not values.hasKey(key.getStr): return rpcError(id, -32602, "Missing " & key.getStr)
    for key, value in values:
      let kind = spec{"inputSchema", "properties", key, "type"}.getStr
      if (kind == "string" and value.kind != JString) or (kind == "boolean" and value.kind != JBool) or
          (kind == "integer" and value.kind != JInt): return rpcError(id, -32602, "Invalid " & key)
    try:
      let answer = handler(name, values, id)
      if answer != nil: result = rpcResult(id, answer) # nil: deferred openDiff/LSP
    except CatchableError as e: result = rpcError(id, -32000, e.msg)
  else: result = rpcError(id, -32601, "Method not found")

const ideToolNames* = ["openFile", "openDiff", "getCurrentSelection", "getLatestSelection",
  "getOpenEditors", "getWorkspaceFolders", "getDiagnostics", "checkDocumentDirty", "saveDocument",
  "close_tab", "closeAllDiffTabs", "darger_xref_definition", "darger_references", "darger_buffer_text",
  "darger_list_buffers", "darger_imenu", "darger_org_agenda", "darger_project_files"]

proc toolSpecs*(allowed: seq[string]): JsonNode =
  result = newJArray()
  for name in ideToolNames:
    if name notin allowed: continue
    var properties = newJObject()
    var required = newJArray()
    proc field(key, kind: string, mandatory = false) =
      properties[key] = %*{"type": kind}
      if mandatory: required.add %key
    var description = ""
    case name
    of "openFile":
      description = "Open a local file and optionally select text. Does not change its contents."
      field("filePath", "string", true)
      for key in ["startText", "endText"]: field(key, "string")
      for key in ["preview", "selectToEndOfLine", "makeFrontmost"]: field(key, "boolean")
    of "openDiff":
      description = "Propose file contents for human hunk review; waits for approval or rejection. Returns final approved contents; caller writes the file."
      for key in ["old_file_path", "new_file_path", "new_file_contents", "tab_name"]: field(key, "string", true)
    of "checkDocumentDirty", "saveDocument":
      description = if name == "saveDocument": "Save an open document, respecting editor save guards; never saves a pending review." else: "Read an open document's dirty status."
      field("filePath", "string", true)
    of "close_tab":
      description = "Close only this connection's named diff. Never closes ordinary buffers."
      field("tab_name", "string", true)
    of "getDiagnostics":
      description = "Read LSP and compilation diagnostics; optionally filter by file URI."
      field("uri", "string")
    of "darger_xref_definition", "darger_references":
      description = "Read locations at a file position (zero-based line, UTF-16 character). Defaults to current buffer and point. Definitions fall back to dumb-jump."
      field("filePath", "string")
      field("line", "integer")
      field("character", "integer")
    of "darger_buffer_text", "darger_imenu":
      description = if name == "darger_buffer_text": "Read an open buffer, including unsaved text. Defaults to current buffer." else: "Read headings and definitions in an open buffer."
      field("filePath", "string")
      field("bufferName", "string")
    of "darger_org_agenda": description = "Read configured Org agenda files, using unsaved open buffers."
    of "darger_project_files": description = "List project-relative files, using Darger's project file discovery."
    of "darger_list_buffers": description = "List open Darger buffers, names, paths and dirty state."
    of "getCurrentSelection": description = "Read current file selection, with zero-based UTF-16 positions."
    of "getLatestSelection": description = "Read the last file selection, retained while the terminal is focused."
    of "getOpenEditors": description = "List open file editors."
    of "getWorkspaceFolders": description = "Read this IDE connection's project folder."
    of "closeAllDiffTabs": description = "Close this connection's pending diffs."
    else: discard
    result.add %*{"name": name, "description": description,
      "inputSchema": {"type": "object", "properties": properties, "required": required}}
