## ACP v1: editor-owned files, asynchronous terminals and human review gates.
import std/[os, json, tables, strutils, unicode, sequtils]
import ../[core, buffer, buffers, lisp, syntax, review, fileio, acp, acpprocess, compilejob, termtext]
import agent, notify

type
  AcpSession* = ref object
    name*, root*: string
    state*: AcpState
    chat*: ChatSession
    transport: AcpProcess
    nextId: int
    pending: Table[int, string]
    callback: proc(session: ChatSession, text: string, ok: bool)
    queued: string
    planning, thoughts: bool
    colors: seq[int8]
    terminals: Table[string, AcpTerminal]
    terminalSerial: int
    loadId: string
  AcpTerminal = ref object
    job: CompileJob
    buf: Buffer
    output: string
    display: TermText
    limit: int
    truncated: bool
    waiters: seq[JsonNode]
  AcpAction = ref object
    session: AcpSession
    id, params: JsonNode
    kind: string
    target: Buffer
    before, disk, path: string
    existed: bool
    diffs: seq[JsonNode]
    preview: int

var
  acpSessions*: seq[AcpSession]
  currentAcp*: AcpSession
  actions: seq[AcpAction]
  active: AcpAction
  lastAgent = "claude"
  choiceRoot: string
  choiceNew: bool
  inputSession: AcpSession
  wantInput = false

proc send(s: AcpSession, msg: JsonNode) =
  if s.transport != nil: s.transport.send($msg)
proc call(s: AcpSession, meth: string, params: JsonNode) =
  inc s.nextId
  s.pending[s.nextId] = meth
  s.send(request(s.nextId, meth, params))
proc reply(a: AcpAction, value: JsonNode) = a.session.send(response(a.id, value))
proc reject(a: AcpAction, reason: string) = a.session.send(failure(a.id, reason))
proc acpFor*(buf: Buffer): AcpSession =
  for s in acpSessions:
    if s.chat.buf == buf: return s
proc selected(root: string): AcpSession =
  let here = acpFor(b)
  if here != nil and here.root == root: return here
  if currentAcp != nil and currentAcp.root == root: return currentAcp
  for i in countdown(acpSessions.high, 0):
    if acpSessions[i].root == root: return acpSessions[i]

proc refresh(s: AcpSession) =
  let view = s.state.render(s.thoughts)
  let header = "# ACP " & s.name & ": " & s.root & "\n"
  s.colors = @[0'i8]
  s.colors.add view.colors
  discard s.chat.setChatText(header & view.text)

proc scopedPath(root, path: string): string =
  if not path.isAbsolute or '\0' in path: raise newException(ValueError, "ACP requires an absolute local path")
  result = normalizedPath(path)
  let base = expandFilename(root)
  var existing = result
  var suffix: seq[string]
  while not fileExists(existing) and not dirExists(existing):
    if symlinkExists(existing): raise newException(ValueError, "Dangling symlink")
    suffix.insert(extractFilename(existing), 0)
    let parent = parentDir(existing)
    if parent == existing: raise newException(ValueError, "Invalid path")
    existing = parent
  var resolved = expandFilename(existing)
  for part in suffix: resolved = resolved / part
  if resolved != base and not resolved.startsWith(base & DirSep):
    raise newException(ValueError, "Path is outside the ACP project")
  result = resolved

proc openFileBuffer(s: AcpSession, path: string): Buffer =
  result = reg.byPath(path)
  if result != nil: return
  for slot in reg.slots:
    if slot.buf.path.len == 0: continue
    try:
      if scopedPath(s.root, slot.buf.path) == path: return slot.buf
    except CatchableError: discard

proc finishTurn(s: AcpSession, ok: bool) =
  s.state.phase = apReady
  s.planning = false
  let callback = s.callback
  s.callback = nil
  notifyAgent(s.chat.buf, failed = not ok)
  if callback != nil: callback(s.chat, s.state.reply, ok)

proc submit*(s: AcpSession, text: string, planning = false,
             callback: proc(session: ChatSession, text: string, ok: bool) = nil) =
  if s.state.phase notin {apReady, apStarting} or s.queued.len > 0:
    raise newException(ValueError, "ACP session is busy")
  if text.len == 0: return
  s.planning = planning
  s.callback = callback
  if s.state.phase == apStarting:
    s.queued = text
    return
  s.state.reply = ""
  s.state.entries.add AcpEntry(kind: "user_message_chunk", text: text)
  s.state.phase = apPrompting
  s.call("session/prompt", promptParams(s.state.id, text))
  s.refresh()

proc cancel*(s: AcpSession) =
  if s == nil: return
  if s.state.phase == apStarting:
    if s.transport != nil: s.transport.close()
    s.transport = nil
    s.pending.clear()
    s.queued = ""
    s.finishTurn(false)
    s.state.phase = apFailed
    return
  if s.state.phase == apPrompting:
    s.state.phase = apCancelling
    s.send(notification("session/cancel", %*{"sessionId": s.state.id}))
  for i in countdown(actions.high, 0):
    let a = actions[i]
    if a.session == s:
      if a.kind == "session/request_permission": a.reply(permissionResult())
      else: a.reject("Cancelled by user")
      actions.delete(i)
  if active != nil and active.session == s:
    let a = active
    active = nil
    if a.target != nil and reviewTarget == a.target: finishReview(true)
    if mode == "acp-choice": mode = ""
    if a.kind == "session/request_permission": a.reply(permissionResult())
    else: a.reject("Cancelled by user")
  for t in s.terminals.values:
    if t.job != nil: t.job.stop()

proc closeSession(s: AcpSession) =
  s.cancel()
  for t in s.terminals.values:
    if t.job != nil:
      t.job.close()
      t.job = nil
  s.terminals.clear()
  if s.transport != nil:
    s.transport.close()
    s.transport = nil
  s.pending.clear()
  s.queued = ""
  if s.callback != nil: s.finishTurn(false)
  s.state.phase = apFailed

proc sessionCache(): JsonNode =
  let path = getHomeDir() / ".darger-acp-sessions.json"
  try:
    if fileExists(path):
      let value = parseJson(readFile(path))
      if value.kind == JObject: return value
  except CatchableError: discard
  newJObject()

proc remember(s: AcpSession) =
  try:
    var cache = sessionCache()
    cache[s.name & "\n" & s.root] = %s.state.id
    atomicWrite(getHomeDir() / ".darger-acp-sessions.json", $cache)
  except CatchableError as e: echoLine = "ACP session ID not saved: " & e.msg

proc commandFor(name: string): string =
  let setting = interp.env.values.getOrDefault("acp-agents", nilValue())
  for entry in setting.asList:
    if entry.kind == vList and entry.items.len == 3 and entry.items[0].asString == name: return entry.items[2].asString
  raise newException(ValueError, "Unknown ACP agent: " & name)

proc startAcp*(name, root: string, fresh = false): AcpSession =
  if not fresh:
    for s in acpSessions:
      if s.name == name and s.root == root and s.transport != nil:
        currentAcp = s
        switchTo(s.chat.buf)
        return s
  let command = commandFor(name)
  if strutils.strip(command).len == 0: raise newException(ValueError, "Empty ACP command")
  result = AcpSession(name: name, root: root, chat: ChatSession(root: root, buf: newBuffer()))
  if not fresh:
    result.loadId = sessionCache(){name & "\n" & root}.getStr
    for i in countdown(acpSessions.high, 0):
      let old = acpSessions[i]
      if old.name == name and old.root == root:
        result.loadId = old.state.id
        break
  result.transport = startAcpProcess(command, root)
  result.call("initialize", initializeParams())
  acpSessions.add result
  reg.add(result.chat.buf, "*acp:" & name & ":" & extractFilename(root) & "*")
  setReadOnly(result.chat.buf, true)
  setLocalKey(result.chat.buf, "C-c C-k", symbol("acp-cancel"))
  setLocalKey(result.chat.buf, "enter", symbol("acp-chat"))
  setLocalKey(result.chat.buf, "C-m", symbol("acp-chat"))
  setLocalKey(result.chat.buf, "C-j", symbol("acp-chat"))
  currentAcp = result
  lastAgent = name
  result.refresh()
  switchTo(result.chat.buf)

proc terminalResult(t: AcpTerminal): JsonNode =
  result = %*{"output": terminalText(t.output), "truncated": t.truncated}
  if t.job.finished: result["exitStatus"] = %*{"exitCode": t.job.code}

proc pollTerminal(s: AcpSession, t: AcpTerminal): bool {.discardable.} =
  let chunk = t.job.read()
  t.job.poll()
  if chunk.len > 0:
    result = true
    t.output.add chunk
    t.truncated = trimOutput(t.output, t.limit) or t.truncated
    # Rebuild from the bounded tail; escape sequences never reach the UI as actions.
    t.display = TermText()
    t.display.feed(t.output)
    t.buf.splice(0, t.buf.text.runeLen, t.display.text)
    t.buf.modified = false
  # Drain regular-file output before signalling exit, including large final bursts.
  if t.job.finished and chunk.len == 0:
    for id in t.waiters: s.send(response(id, %*{"exitCode": t.job.code}))
    t.waiters = @[]

proc createTerminal(a: AcpAction) =
  let s = a.session
  let p = a.params
  var command = "env"
  let env = p{"env"}
  if env != nil and env.kind != JArray: raise newException(ValueError, "Invalid env array")
  if env != nil:
    for item in env:
      let name = item{"name"}.getStr
      if name.len == 0 or name[0] notin Letters + {'_'} or name.anyIt(it notin IdentChars):
        raise newException(ValueError, "Invalid terminal environment name")
      command.add " " & quoteShell(name & "=" & item{"value"}.getStr)
  command.add " " & quoteShell(p{"command"}.getStr)
  let args = p{"args"}
  if args != nil and args.kind != JArray: raise newException(ValueError, "Invalid args array")
  if args != nil:
    for arg in args: command.add " " & quoteShell(arg.getStr)
  let cwd = scopedPath(s.root, p{"cwd"}.getStr(s.root))
  let t = AcpTerminal(limit: clamp(p{"outputByteLimit"}.getInt(1048576), 0, maxAcpMessage), buf: newBuffer())
  t.job = startCompileJob(command, cwd)
  inc s.terminalSerial
  let id = $s.terminalSerial
  s.terminals[id] = t
  reg.add(t.buf, "*acp-terminal*")
  setReadOnly(t.buf, true)
  a.reply(%*{"terminalId": id})

proc handleRequest(s: AcpSession, msg: JsonNode) =
  let p = msg{"params"}
  let id = msg{"id"}
  let meth = msg{"method"}.getStr
  try:
    if p{"sessionId"}.getStr != s.state.id or s.state.id.len == 0:
      raise newException(ValueError, "Unknown ACP session")
    if s.state.phase == apCancelling:
      if meth == "session/request_permission": s.send(response(id, permissionResult()))
      else: s.send(failure(id, "Turn cancelled"))
      return
    case meth
    of "fs/read_text_file":
      let path = scopedPath(s.root, p{"path"}.getStr)
      let buf = s.openFileBuffer(path)
      let text = if buf != nil: buf.text else: readFile(path)
      s.send(response(id, %*{"content": readSlice(text, p{"line"}.getInt(1), p{"limit"}.getInt(-1))}))
    of "session/request_permission", "fs/write_text_file", "terminal/create":
      if s.planning and meth != "session/request_permission":
        raise newException(ValueError, "Plan awaiting approval: writes and terminals disabled")
      if actions.len >= 32: raise newException(ValueError, "ACP approval queue full")
      let a = AcpAction(session: s, id: id, params: p, kind: meth)
      if meth == "fs/write_text_file":
        a.path = scopedPath(s.root, p{"path"}.getStr)
        if p{"content"} == nil or p["content"].kind != JString: raise newException(ValueError, "Missing content")
      if meth == "terminal/create" and p{"command"}.getStr.len == 0: raise newException(ValueError, "Missing command")
      if meth == "session/request_permission":
        let tool = s.state.mergeTool(p{"toolCall"})
        a.params = p.copy()
        a.params["toolCall"] = tool.copy()
        let options = p{"options"}
        if options == nil or options.kind != JArray or options.len == 0 or options.len > 35:
          raise newException(ValueError, "Invalid permission options")
        if s.planning and tool{"kind"}.getStr notin ["read", "search", "think"]:
          a.reply(permissionResult())
          return
        let contents = tool{"content"}
        if contents != nil and contents.kind == JArray:
          for content in contents:
            if content{"type"}.getStr == "diff": a.diffs.add content
      actions.add a
      notifyAgent(s.chat.buf, terminal = true)
    of "terminal/output", "terminal/wait_for_exit", "terminal/kill", "terminal/release":
      let tid = p{"terminalId"}.getStr
      let t = s.terminals.getOrDefault(tid)
      if t == nil: raise newException(ValueError, "Unknown terminal")
      s.pollTerminal(t)
      case meth
      of "terminal/output": s.send(response(id, t.terminalResult()))
      of "terminal/wait_for_exit": t.waiters.add id
      of "terminal/kill":
        t.job.stop()
        s.send(response(id, newJObject()))
      else:
        for waiter in t.waiters: s.send(failure(waiter, "Terminal released"))
        t.job.close()
        s.terminals.del(tid)
        s.send(response(id, newJObject()))
    else: s.send(failure(id, "Unsupported ACP method: " & meth, -32601))
  except CatchableError as e: s.send(failure(id, e.msg))

proc handle(s: AcpSession, msg: JsonNode) =
  let meth = msg{"method"}.getStr
  if meth.len > 0:
    if msg.hasKey("id"): s.handleRequest(msg)
    elif meth == "session/update" and msg{"params", "sessionId"}.getStr == s.state.id:
      s.state.update(msg["params"]["update"])
      s.refresh()
    return
  let id = msg{"id"}.getInt(-1)
  if id notin s.pending: return
  let operation = s.pending[id]
  s.pending.del(id)
  if msg.hasKey("error"):
    let error = msg["error"]{"message"}.getStr
    s.state.entries.add AcpEntry(text: "ACP error: " & error)
    s.refresh()
    if operation == "session/prompt": s.finishTurn(false)
    else:
      s.closeSession()
      echoLine = "ACP: " & error & " (authenticate the installed agent externally if required)"
    return
  let value = msg{"result"}
  case operation
  of "initialize":
    if value{"protocolVersion"}.getInt != 1: raise newException(ValueError, "Agent does not support ACP v1")
    s.state.loadSession = value{"agentCapabilities", "loadSession"}.getBool
    if s.state.loadSession and s.loadId.len > 0:
      s.state.id = s.loadId
      s.call("session/load", sessionParams(s.root, s.loadId))
    else: s.call("session/new", sessionParams(s.root))
  of "session/new", "session/load":
    if operation == "session/new": s.state.id = value{"sessionId"}.getStr
    if s.state.id.len == 0: raise newException(ValueError, "Missing ACP session ID")
    s.state.phase = apReady
    s.chat.id = s.state.id
    s.chat.started = true
    s.remember()
    if s.queued.len > 0:
      let text = s.queued
      s.queued = ""
      s.submit(text, s.planning, s.callback)
  of "session/prompt": s.finishTurn(s.state.phase != apCancelling and value{"stopReason"}.getStr != "cancelled")
  else: discard

proc showChoice(a: AcpAction) =
  let details = newBuffer(pretty(a.params))
  reg.add(details, "*acp-approval*")
  setReadOnly(details, true)
  switchTo(details)
  var label = ""
  if a.kind == "terminal/create":
    label = "Run the command shown in *acp-approval*? [y/n]: "
  elif a.kind == "fs/write_text_file":
    label = "No text changes. Save/create " & a.path & "? [y/n]: "
  else:
    label = "ACP " & a.params{"toolCall", "kind"}.getStr & " " & a.params{"toolCall", "title"}.getStr & " "
    for i, option in a.params["options"].elems:
      label.add $"123456789abcdefghijklmnopqrstuvwxyz"[i] & ":" & option{"name"}.getStr & "  "
  beginMini("acp-choice", label)

proc nextAction() =
  if reviewOpen() or mode.len > 0: return
  if active == nil:
    if actions.len == 0: return
    active = actions[0]
    actions.delete(0)
  let a = active
  try:
    case a.kind
    of "session/request_permission":
      if a.preview < a.diffs.len:
        let diff = a.diffs[a.preview]
        inc a.preview
        a.target = newBuffer(diff{"oldText"}.getStr)
        reg.add(a.target, "*acp-permission:" & diff{"path"}.getStr & "*")
        switchTo(a.target)
        beginReview(diff{"newText"}.getStr, "ACP permission preview (does not write files)")
        if not reviewOpen(): a.target = nil
      else: a.showChoice()
    of "terminal/create":
      if interp.env.values.getOrDefault("acp-terminal-confirm", symbol("t")).kind != vNil: a.showChoice()
      else:
        a.createTerminal()
        active = nil
    of "fs/write_text_file":
      a.path = scopedPath(a.session.root, a.path)
      a.existed = fileExists(a.path)
      a.disk = if a.existed: readFile(a.path) else: ""
      a.target = a.session.openFileBuffer(a.path)
      if a.target == nil:
        a.target = if a.existed: loadBuffer(a.path) else: newBuffer()
        a.target.path = a.path
        reg.add(a.target, extractFilename(a.path))
      if a.target.isReadOnly: raise newException(ValueError, "Read-only buffer")
      a.before = a.target.text
      switchTo(a.target)
      beginReview(a.params["content"].getStr, "ACP write")
      if not reviewOpen():
        # No textual change is not permission to save an unsaved buffer.
        if a.existed and a.target.fileBytes == a.disk:
          a.reply(newJObject())
          active = nil
        else: a.showChoice()
    else: discard
  except CatchableError as e:
    a.reject(e.msg)
    active = nil

let previousGuard = reviewApplyGuard
reviewApplyGuard = proc(target: Buffer): bool =
  if previousGuard != nil and not previousGuard(target): return false
  let a = active
  if a == nil or a.kind != "fs/write_text_file" or a.target != target: return true
  try:
    result = target in reg and not target.isReadOnly and scopedPath(a.session.root, target.path) == a.path and target.text == reviewState.originalText() and
      scopedPath(a.session.root, a.path) == a.path and fileExists(a.path) == a.existed and
      (not a.existed or readFile(a.path) == a.disk)
  except CatchableError: result = false

proc saveApproved(a: AcpAction, target: Buffer) =
  if scopedPath(a.session.root, target.path) != a.path or target.isReadOnly or
      fileExists(a.path) != a.existed or (a.existed and readFile(a.path) != a.disk):
    raise newException(ValueError, "File changed during approval")
  if not dirExists(parentDir(a.path)): createDir(parentDir(a.path))
  switchTo(target)
  saveBuffer()
  if mode.len > 0 or target.modified: raise newException(IOError, "Reviewed write was not saved")
  a.reply(newJObject())

reviewFinishedHooks.add proc(target: Buffer, cancelled: bool, taken: int) =
  let a = active
  if a == nil or a.target != target: return
  a.target = nil
  if a.kind == "session/request_permission":
    if cancelled or taken == 0:
      a.reply(permissionResult())
      active = nil
    return
  active = nil
  if cancelled or (taken == 0 and target.text == a.before):
    a.reject("Write rejected by human review")
    return
  try:
    a.saveApproved(target)
  except CatchableError as e: a.reject(e.msg)

proc choose*(value: string): bool =
  let a = active
  if a == nil: return true
  if a.kind in ["terminal/create", "fs/write_text_file"]:
    if value notin ["y", "n"]: return false
    active = nil
    try:
      if value == "n": a.reject("Operation rejected by user")
      elif a.kind == "terminal/create": a.createTerminal()
      else:
        if a.target notin reg or a.target.text != a.before:
          raise newException(ValueError, "Buffer changed during approval")
        # A one-key prompt closes after this callback, while saving is synchronous.
        mode = ""
        a.saveApproved(a.target)
    except CatchableError as e: a.reject(e.msg)
  else:
    let i = "123456789abcdefghijklmnopqrstuvwxyz".find(value)
    if value.len != 1 or i < 0 or i >= a.params["options"].len: return false
    active = nil
    a.reply(permissionResult(a.params["options"][i]{"optionId"}.getStr))
  true

definePrompt(Prompt(kind: "acp-choice", onAccept: choose, onCancel: proc() =
  if active != nil:
    if active.kind == "session/request_permission": active.reply(permissionResult())
    else: active.reject("Cancelled by user")
    active = nil))
runeFilters.add proc(r: Rune): bool =
  if mode != "acp-choice": return false
  if choose($r):
    mode = ""
    prompt = ""
  true

proc pollAcp*(): bool =
  for s in acpSessions:
    if s.transport == nil: continue
    try:
      let alive = s.transport.poll()
      let messages = takeMessages(s.transport.input)
      for msg in messages: s.handle(msg)
      result = result or messages.len > 0
      for t in s.terminals.values: result = s.pollTerminal(t) or result
      if not alive and s.transport != nil:
        echoLine = "ACP exited: " & s.transport.errors
        s.closeSession()
    except CatchableError as e:
      s.closeSession()
      echoLine = "ACP: " & e.msg
  nextAction()
  if wantInput and active == nil and not reviewOpen() and mode.len == 0:
    wantInput = false
    beginMini("acp-input", "ACP " & inputSession.name & ": ")
    result = true
  result = result or active != nil

proc chatPrompt(s: AcpSession) =
  inputSession = s
  currentAcp = s
  beginMini("acp-input", "ACP " & s.name & ": ")
definePrompt(Prompt(kind: "acp-input", text: true, onAccept: proc(value: string): bool =
  inputSession.submit(value)
  true))
proc agentNames(): seq[string] =
  for entry in interp.env.values["acp-agents"].asList:
    if entry.kind == vList and entry.items.len == 3: result.add entry.items[0].asString
definePrompt(Prompt(kind: "acp-agent", candidates: agentNames,
  onAccept: proc(value: string): bool =
    inputSession = startAcp(value, choiceRoot, choiceNew)
    wantInput = true
    true))

proc openChat(fresh: bool) =
  let here = acpFor(b)
  if here != nil and not fresh:
    here.chatPrompt()
    return
  choiceRoot = if here != nil: here.root else: currentChatRoot()
  choiceNew = fresh
  beginMini("acp-agent", "ACP agent: ", lastAgent)

interp.defPrimitive("acp-chat", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  openChat(false)
  nilValue())
interp.defPrimitive("acp-chat-new", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  openChat(true)
  nilValue())
interp.defPrimitive("acp-cancel", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let s = acpFor(b)
  cancel(if s != nil: s else: currentAcp)
  nilValue())
interp.defPrimitive("acp-toggle-thoughts", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let s = acpFor(b)
  if s != nil:
    s.thoughts = not s.thoughts
    s.refresh()
  nilValue())

faceProviders.add proc(buf: Buffer): seq[seq[Face]] =
  let s = acpFor(buf)
  if s == nil: return
  result = detect("chat.md", "").highlight(buf.lines)
  for i, line in buf.lines:
    let color = if i < s.colors.len: s.colors[i] else: 0
    if color == 0: continue
    let face = case color
      of 1: fComment
      of 2: fAnsi1
      else: fAnsi2
    result[i] = newSeqWith(line.len, face)

langHints.add proc(buf: Buffer): string = (if acpFor(buf) != nil: "chat.md" else: "")
modeNameProviders.add proc(buf: Buffer): string =
  let s = acpFor(buf)
  if s != nil: "ACP " & $s.state.phase else: ""
killHooks.add proc(buf: Buffer) =
  let s = acpFor(buf)
  if s != nil: s.closeSession()
exitHooks.add proc() =
  for s in acpSessions: s.closeSession()
busyHooks.add proc(): bool = acpSessions.anyIt(it.transport != nil)
tickHooks.add pollAcp

defaults.add """
(setq acp-agents '(("claude" . "npx -y @agentclientprotocol/claude-agent-acp") ("codex" . "codex-acp") ("gemini" . "gemini --acp")))
(setq acp-terminal-confirm t)
(setq agent-backend 'cli)
"""

backendRoot = proc(buf: Buffer): string =
  let s = acpFor(buf)
  if s != nil: s.root else: ""
backendSession = proc(root: string): ChatSession =
  let s = selected(root)
  if s != nil: s.chat else: nil
backendSend = proc(root, message: string, planning: bool,
    callback: proc(session: ChatSession, text: string, ok: bool)) =
  let s = selected(root)
  if s == nil or s.transport == nil:
    raise newException(ValueError, "Open an ACP session for this project with M-x acp-chat first")
  s.submit(message, planning, callback)
  currentAcp = s
  switchTo(s.chat.buf)
