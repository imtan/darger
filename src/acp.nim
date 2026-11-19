## ACP v1 JSON-RPC messages and session presentation, independent of the editor.
import std/[json, strutils, tables, unicode]
import review

const maxAcpMessage* = 8 * 1024 * 1024

type
  AcpPhase* = enum apStarting, apReady, apPrompting, apCancelling, apFailed
  AcpEntry* = object
    kind*, text*, id*: string
  AcpState* = object
    id*: string
    phase*: AcpPhase
    loadSession*: bool
    entries*: seq[AcpEntry]
    tools*: Table[string, JsonNode]
    plan*: JsonNode
    reply*: string
  AcpView* = object
    text*: string
    colors*: seq[int8] # 1 dim, 2 removed, 3 added

proc request*(id: int, meth: string, params: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "method": meth, "params": params}
proc notification*(meth: string, params: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "method": meth, "params": params}
proc response*(id, value: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "result": value}
proc failure*(id: JsonNode, message: string, code = -32000): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}
proc initializeParams*(): JsonNode =
  %*{"protocolVersion": 1, "clientInfo": {"name": "darger", "version": "0.1.0"},
    "clientCapabilities": {"fs": {"readTextFile": true, "writeTextFile": true}, "terminal": true}}
proc sessionParams*(root: string; id = ""): JsonNode =
  result = %*{"cwd": root, "mcpServers": []}
  if id.len > 0: result["sessionId"] = %id
proc promptParams*(id, text: string): JsonNode =
  %*{"sessionId": id, "prompt": [{"type": "text", "text": text}]}
proc permissionResult*(option = ""): JsonNode =
  if option.len == 0: %*{"outcome": {"outcome": "cancelled"}}
  else: %*{"outcome": {"outcome": "selected", "optionId": option}}

proc takeMessages*(input: var string): seq[JsonNode] =
  var start = 0
  while true:
    let stop = input.find('\n', start)
    if stop < 0: break
    if stop - start > maxAcpMessage: raise newException(ValueError, "ACP message too large")
    let line = input[start..<stop]
    start = stop + 1
    if line.len == 0: continue
    if validateUtf8(line) >= 0: raise newException(ValueError, "Invalid ACP UTF-8")
    let msg = parseJson(line)
    if msg.kind != JObject or msg{"jsonrpc"}.getStr != "2.0":
      raise newException(ValueError, "Invalid ACP JSON-RPC message")
    result.add msg
  input = input[start..^1]
  if input.len > maxAcpMessage: raise newException(ValueError, "ACP message too large")

proc mergeTool*(s: var AcpState, update: JsonNode): JsonNode =
  if update == nil or update.kind != JObject: raise newException(ValueError, "Invalid tool call")
  let id = update{"toolCallId"}.getStr
  if id.len == 0: raise newException(ValueError, "Missing toolCallId")
  if id notin s.tools:
    s.tools[id] = %*{"toolCallId": id, "kind": "other", "status": "pending"}
    s.entries.add AcpEntry(kind: "tool", id: id)
  for key, value in update:
    if value.kind != JNull: s.tools[id][key] = value
  s.tools[id]

proc update*(s: var AcpState, u: JsonNode) =
  let kind = u{"sessionUpdate"}.getStr
  case kind
  of "agent_message_chunk", "agent_thought_chunk", "user_message_chunk":
    let content = u{"content"}
    let text = if content{"type"}.getStr == "text": content{"text"}.getStr
      else: "[" & content{"type"}.getStr & "]"
    let id = u{"messageId"}.getStr
    if s.entries.len > 0 and s.entries[^1].kind == kind and s.entries[^1].id == id:
      s.entries[^1].text.add text
    else: s.entries.add AcpEntry(kind: kind, text: text, id: id)
    if kind == "agent_message_chunk": s.reply.add text
  of "tool_call", "tool_call_update": discard s.mergeTool(u)
  of "plan":
    if s.plan == nil: s.entries.add AcpEntry(kind: "plan")
    s.plan = u{"entries"}
  else: discard # unadvertised optional capabilities and future updates

proc render*(s: AcpState, thoughts = false): AcpView =
  var view: AcpView
  proc add(text: string, color: int8 = 0) =
    for line in text.splitLines:
      view.text.add line & "\n"
      view.colors.add color
  for entry in s.entries:
    case entry.kind
    of "agent_message_chunk": add("\n## Agent\n" & entry.text)
    of "user_message_chunk": add("\n## You\n" & entry.text)
    of "agent_thought_chunk":
      add("\n## Thinking" & (if thoughts: "\n" & entry.text else: " [collapsed; M-x acp-toggle-thoughts]"), 1)
    of "plan":
      add("\n## Plan")
      if s.plan != nil and s.plan.kind == JArray:
        for item in s.plan:
          let mark = case item{"status"}.getStr
            of "completed": "x"
            of "in_progress": ">"
            else: " "
          add("- [" & mark & "] " & item{"content"}.getStr)
    of "tool":
      let tool = s.tools[entry.id]
      add("\n### " & tool{"kind"}.getStr & " · " & tool{"status"}.getStr & " · " & tool{"title"}.getStr)
      let content = tool{"content"}
      if content != nil and content.kind == JArray:
        for item in content:
          case item{"type"}.getStr
          of "content": add(item{"content", "text"}.getStr)
          of "terminal": add("Terminal: " & item{"terminalId"}.getStr)
          of "diff":
            add(item{"path"}.getStr)
            let diff = newReview(item{"oldText"}.getStr, item{"newText"}.getStr).view(-1)
            let lines = diff.text.splitLines
            for i, line in lines:
              let c = if i < diff.colors.len: diff.colors[i] else: 0
              add(line, if c == 1: 2 elif c == 2: 3 else: 0)
          else: discard
    else: add(entry.text)
  view

proc readSlice*(text: string, line = 1, limit = -1): string =
  if line < 1 or limit < -1: raise newException(ValueError, "Invalid line/limit")
  if line == 1 and limit == -1: return text
  var at = 1
  for chunk in text.splitLines(keepEol = true):
    if at >= line and (limit < 0 or at - line < limit): result.add chunk
    inc at

proc trimOutput*(text: var string, limit: int): bool =
  if text.len <= limit: return false
  var start = text.len - max(0, limit)
  while start < text.len and (ord(text[start]) and 0xc0) == 0x80: inc start
  text = text[start..^1]
  true

proc terminalText*(bytes: string): string =
  ## Keep partial UTF-8 until the next output read; replace invalid bytes for JSON.
  var i = 0
  while i < bytes.len:
    let c = ord(bytes[i])
    let size = if c < 0x80: 1 elif c in 0xc2..0xdf: 2
      elif c in 0xe0..0xef: 3 elif c in 0xf0..0xf4: 4 else: 0
    if size > 0 and i + size > bytes.len:
      var partial = true
      for j in i + 1..<bytes.len:
        if (ord(bytes[j]) and 0xc0) != 0x80: partial = false
      if partial: break
    if size > 0 and i + size <= bytes.len and validateUtf8(bytes[i..<i + size]) == -1:
      result.add bytes[i..<i + size]
      i += size
    else:
      result.add "\uFFFD"
      inc i
