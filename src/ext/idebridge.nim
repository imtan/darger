## Claude Code IDE integration, using the same buffers and review as the user.
import std/[os, strutils, unicode, tables, json, times, sequtils, sets]
import ../[core, buffer, buffers, render, lisp, lsp, review, syntax, remote,
  ideprotocol, ideserver, dumbjump, grep, project, orgmode, compilation]
import agent, langserver, compile, org

type
  PendingDiff = ref object
    server: IdeServer
    peer: IdePeer
    id: JsonNode
    tab, path, proposal, before: string
    target: Buffer
  PendingQuery = ref object
    peer: IdePeer
    id: JsonNode
    started: float
    done: bool

var
  ideServers*: seq[IdeServer]
  waiting: seq[PendingDiff]
  active: PendingDiff
  queries: seq[PendingQuery]
  awaitingWrites: Table[Buffer, tuple[text: string, since: float]]
  lastWriteCheck: float
  latest: JsonNode
  lastSelection = ""
  lastSelectionAt: float
  lastTools = ""
  modeLineInstalled = false

proc ideEnabled*(): bool =
  interp.env.values.getOrDefault("claude-code-ide", symbol("t")).kind != vNil

proc allowedTools(): seq[string] =
  let setting = interp.env.values.getOrDefault("claude-code-ide-tools")
  if setting == nil: return @ideToolNames
  for v in setting.asList:
    if v.kind in {vSymbol, vString}: result.add v.str

proc selectionOf*(buf: Buffer): JsonNode =
  if buf == nil or buf.path.len == 0 or isRemote(buf.path):
    return %*{"success": false, "message": "No active file editor"}
  let (a, z) = if buf.regionActive: buf.region else: (buf.offset(buf.cursor), buf.offset(buf.cursor))
  let start = buf.point(a)
  let stop = buf.point(z)
  %*{"success": true, "text": $buf.text.toRunes[a..<z], "filePath": buf.path, "fileUrl": uriOf(buf.path),
    "selection": {"start": {"line": start.line, "character": utf16Col(buf.lines[start.line], start.col)},
      "end": {"line": stop.line, "character": utf16Col(buf.lines[stop.line], stop.col)}, "isEmpty": a == z}}

proc localPath(args: JsonNode, key, root: string): string =
  let path = args{key}.getStr
  if path.len == 0 or isRemote(path) or "://" in path:
    raise newException(ValueError, "Expected a local file path: " & key)
  normalizedPath(absolutePath(path, root))

proc selectedBuffer(args: JsonNode, root: string): Buffer =
  if args.hasKey("filePath"): result = reg.byPath(localPath(args, "filePath", root))
  elif args.hasKey("bufferName"): result = reg.byName(args["bufferName"].getStr)
  else: result = b
  if result == nil: raise newException(ValueError, "Buffer is not open")

proc reject(diff: PendingDiff) =
  diff.peer.send(rpcResult(diff.id, diffResult(false, "", diff.tab)))

proc closeDiffs(peer: IdePeer, tab = "", all = false): int =
  for i in countdown(waiting.high, 0):
    if waiting[i].peer == peer and (all or waiting[i].tab == tab):
      waiting[i].reject()
      waiting.delete(i)
      inc result
  if active != nil and active.peer == peer and (all or active.tab == tab):
    finishReview(true)
    inc result

proc startNextReview() =
  if active != nil or waiting.len == 0 or reviewOpen() or mode.len > 0: return
  let diff = waiting[0]
  waiting.delete(0)
  if diff.peer.closed: return
  try:
    pushXref(b, b.cursor, renderer.top, renderer.left)
    if dirExists(diff.path): raise newException(ValueError, "Diff target is a directory")
    visit(diff.path)
    diff.target = b
    diff.before = b.text
    active = diff
    beginReview(diff.proposal, "Claude Code")
    dirty = true
    if not reviewOpen():
      # Equal contents cannot cause a write or need a human decision.
      active = nil
      diff.peer.send(rpcResult(diff.id, diffResult(true, b.text, diff.tab)))
  except CatchableError as e:
    active = nil
    diff.peer.send(rpcError(diff.id, -32000, e.msg))

let previousReviewGuard = reviewApplyGuard
reviewApplyGuard = proc(target: Buffer): bool =
  (previousReviewGuard == nil or previousReviewGuard(target)) and
    (active == nil or active.target != target or target.text == reviewState.originalText())

reviewFinishedHooks.add proc(target: Buffer, cancelled: bool, taken: int) =
  if active == nil or active.target != target: return
  let diff = active
  active = nil
  dirty = true
  let accepted = not cancelled and (taken > 0 or target.text != diff.before)
  if accepted: awaitingWrites[target] = (target.text, epochTime())
  diff.peer.send(rpcResult(diff.id, diffResult(accepted, target.text, diff.tab)))

proc locationsJson(locations: seq[Location]): JsonNode =
  result = newJArray()
  for loc in locations: result.add %*{"filePath": loc.path, "line": loc.line, "character": loc.col}

proc fallbackDefinitions(buf: Buffer, at: Point, root: string): JsonNode =
  let language = reg.slot(buf).lang
  let name = symbolAt(buf.lines[at.line], at.col, language.name)
  var hits = definitions(buf.lines, language, name, buf.path)
  if hits.len == 0 and name.len > 0:
    let found = runGrep(root, name, literal = true)
    if found.error.len > 0: raise newException(IOError, found.error)
    var seen: HashSet[string]
    for hit in found.hits:
      let path = normalizedPath(absolutePath(hit.path))
      if path == buf.path or path in seen: continue
      seen.incl path
      if seen.len > 200: break
      let open = reg.byPath(path)
      let source = if open != nil: open else: loadBuffer(path)
      hits.add definitions(source.lines, detect(path, $source.lines[0]), name, path)
  hits = rankDefinitions(hits, buf.path, at.line, at.col, name)
  result = newJArray()
  for hit in hits: result.add %*{"filePath": hit.path, "line": hit.line, "character": hit.col, "text": hit.text}

proc ideDiagnostics(args: JsonNode): JsonNode =
  var groups = initTable[string, JsonNode]()
  let only = args{"uri"}.getStr
  proc add(uri: string, diagnostic: JsonNode) =
    if only.len > 0 and only != uri: return
    if uri notin groups: groups[uri] = newJArray()
    groups[uri].add diagnostic
  for client in clients.values:
    if client == nil: continue
    for uri, diagnostics in client.diagnostics:
      let buf = reg.byPath(pathOf(uri))
      for d in diagnostics:
        let col = if buf != nil and d.line < buf.lines.len: utf16Col(buf.lines[d.line], d.col) else: d.col
        let endCol = if buf != nil and d.endLine < buf.lines.len: utf16Col(buf.lines[d.endLine], d.endCol) else: d.endCol
        add(uri, %*{"message": d.message, "severity": ["Error", "Warning", "Information", "Hint"][clamp(d.severity-1, 0, 3)],
          "source": "lsp", "range": {"start": {"line": d.line, "character": col}, "end": {"line": d.endLine, "character": endCol}}})
  for entry in compilationDiagnostics():
    let d = entry.location
    add(uriOf(d.path), %*{"message": entry.message, "severity": ["Error", "Warning", "Hint"][ord(d.severity)],
      "source": "compilation", "range": {"start": {"line": d.line, "character": d.col}, "end": {"line": d.line, "character": d.col}}})
  result = newJArray()
  for uri, diagnostics in groups: result.add %*{"uri": uri, "diagnostics": diagnostics}

proc callTool(server: IdeServer, peer: IdePeer, name: string, args, id: JsonNode): JsonNode =
  case name
  of "openDiff":
    if waiting.len >= 32: raise newException(ValueError, "Review queue is full")
    discard localPath(args, "old_file_path", server.root)
    let path = localPath(args, "new_file_path", server.root)
    let tab = args["tab_name"].getStr
    if tab.len == 0: raise newException(ValueError, "Empty diff tab name")
    discard closeDiffs(peer, tab)
    waiting.add PendingDiff(server: server, peer: peer, id: id, tab: tab, path: path,
      proposal: args["new_file_contents"].getStr)
    startNextReview()
  of "close_tab":
    discard closeDiffs(peer, args["tab_name"].getStr)
    result = toolText("TAB_CLOSED")
  of "closeAllDiffTabs": result = toolText("CLOSED_" & $closeDiffs(peer, all = true) & "_DIFF_TABS")
  of "getCurrentSelection": result = toolJson(selectionOf(b))
  of "getLatestSelection": result = toolJson(if latest != nil: latest else: %*{"success": false, "message": "No selection available"})
  of "getWorkspaceFolders":
    result = toolJson(%*{"success": true, "rootPath": server.root,
      "folders": [{"name": extractFilename(server.root), "uri": uriOf(server.root), "path": server.root}]})
  of "getOpenEditors", "darger_list_buffers":
    var rows = newJArray()
    for slot in reg.slots:
      let buf = slot.buf
      if name == "getOpenEditors" and (buf.path.len == 0 or isRemote(buf.path)): continue
      rows.add %*{"uri": (if buf.path.len > 0 and not isRemote(buf.path): uriOf(buf.path) else: ""),
        "filePath": buf.path, "label": reg.displayName(buf), "isActive": b == buf,
        "languageId": slot.lang.name, "isDirty": buf.modified}
    result = toolJson(if name == "getOpenEditors": %*{"tabs": rows} else: rows)
  of "getDiagnostics": result = toolJson(ideDiagnostics(args))
  of "checkDocumentDirty", "saveDocument":
    let path = localPath(args, "filePath", server.root)
    let buf = reg.byPath(path)
    if buf == nil: return toolJson(%*{"success": false, "message": "Document not open: " & path})
    if name == "checkDocumentDirty": return toolJson(%*{"success": true, "filePath": path, "isDirty": buf.modified, "isUntitled": false})
    if reviewOpen() and reviewTarget == buf: raise newException(ValueError, "Document is under review")
    if mode.len > 0: raise newException(ValueError, "Editor is awaiting user input")
    let origin = b
    switchTo(buf)
    try:
      saveBuffer() # includes supersede/read-only guards and save hooks
      let saved = mode.len == 0 and not buf.modified
      result = toolJson(%*{"success": saved, "filePath": path, "saved": saved})
    finally:
      if mode.len == 0 and origin in reg: switchTo(origin)
  of "openFile":
    let path = localPath(args, "filePath", server.root)
    let origin = b
    let front = args{"makeFrontmost"}.getBool(true)
    if front and mode.len > 0: raise newException(ValueError, "Editor is awaiting user input")
    if dirExists(path): raise newException(ValueError, "Expected a file, not a directory")
    if front: pushXref(b, b.cursor, renderer.top, renderer.left)
    visit(path)
    let buf = b
    let startText = args{"startText"}.getStr
    if startText.len > 0:
      let text = buf.text
      let startByte = text.find(startText)
      if startByte >= 0:
        var endByte = startByte + startText.len
        let endText = args{"endText"}.getStr
        if endText.len > 0:
          let found = text.find(endText, endByte)
          if found >= 0: endByte = found + endText.len
        if args{"selectToEndOfLine"}.getBool:
          let newline = text.find('\n', endByte)
          endByte = if newline < 0: text.len else: newline
        buf.mark = buf.point(text[0..<startByte].runeLen)
        buf.cursor = buf.point(text[0..<endByte].runeLen)
        buf.markSet = true
        buf.regionActive = true
    if not front and origin in reg: switchTo(origin)
    dirty = true
    result = if front: toolText("Opened file: " & path) else:
      toolJson(%*{"success": true, "filePath": path, "languageId": reg.slot(buf).lang.name, "lineCount": buf.lines.len})
  of "darger_buffer_text":
    let buf = selectedBuffer(args, server.root)
    result = toolJson(%*{"filePath": buf.path, "bufferName": reg.displayName(buf), "text": buf.text})
  of "darger_project_files": result = toolJson(%projectFiles(server.root))
  of "darger_org_agenda":
    var rows = newJArray()
    for item in agendaSnapshot(): rows.add %*{"filePath": item.path, "line": item.line, "text": agendaRow(item)}
    result = toolJson(rows)
  of "darger_imenu":
    let buf = selectedBuffer(args, server.root)
    var rows = newJArray()
    if reg.slot(buf).lang.name == "Org":
      for item in outline(buf.lines): rows.add %*{"line": item.line, "text": item.text}
    else:
      for hit in definitions(buf.lines, reg.slot(buf).lang, "", buf.path, all = true):
        rows.add %*{"line": hit.line, "character": hit.col, "text": hit.text}
    result = toolJson(rows)
  of "darger_xref_definition", "darger_references":
    let buf = selectedBuffer(args, server.root)
    let line = clamp(args{"line"}.getInt(buf.cursor.line), 0, buf.lines.high)
    let col = args{"character"}.getInt(utf16Col(buf.lines[line], buf.cursor.col))
    let at: Point = (line, runeCol(buf.lines[line], max(0, col)))
    let origin = b
    try:
      if buf != b: switchTo(buf)
      lspSync(true)
    finally:
      if origin != b and origin in reg: switchTo(origin)
    let client = docClient(buf)
    if client == nil or client.state != lsReady:
      if name == "darger_references": raise newException(ValueError, "No language server for references")
      return toolJson(fallbackDefinitions(buf, at, server.root))
    var params = %*{"textDocument": {"uri": reg.slot(buf).docUri}, "position": {"line": line, "character": utf16Col(buf.lines[line], at.col)}}
    if name == "darger_references": params["context"] = %*{"includeDeclaration": true}
    let query = PendingQuery(peer: peer, id: id, started: epochTime())
    queries.add query
    client.request((if name == "darger_references": "textDocument/references" else: "textDocument/definition"), params,
      proc(answer, error: JsonNode) =
        if query.done or peer.closed: return
        query.done = true
        if error != nil and error.kind != JNull: peer.send(rpcError(id, -32000, error{"message"}.getStr))
        else:
          let locations = parseLocations(answer)
          try:
            let data = if locations.len == 0 and name == "darger_xref_definition" and buf in reg:
              fallbackDefinitions(buf, at, server.root) else: locationsJson(locations)
            peer.send(rpcResult(id, toolJson(data)))
          except CatchableError as e: peer.send(rpcError(id, -32000, e.msg)))
  else: raise newException(ValueError, "Unknown tool")

proc handleIdeMessage*(server: IdeServer, peer: IdePeer, wire: string): JsonNode =
  # MCP cancellation belongs to the requesting connection, just like close_tab.
  try:
    let req = parseJson(wire)
    if req.kind == JObject and not req.hasKey("id") and req{"method"}.getStr == "notifications/cancelled":
      let id = req{"params", "requestId"}
      for i in countdown(waiting.high, 0):
        if waiting[i].peer == peer and waiting[i].id == id:
          waiting[i].reject()
          waiting.delete(i)
      if active != nil and active.peer == peer and active.id == id: finishReview(true)
      for query in queries:
        if query.peer == peer and query.id == id: query.done = true
      return nil
  except ValueError: discard
  dispatchRpc(wire, toolSpecs(allowedTools()), proc(name: string, args, id: JsonNode): JsonNode =
    callTool(server, peer, name, args, id))

proc ensureIde*(root: string): IdeServer =
  if not ideEnabled() or isRemote(root): return
  for server in ideServers:
    if server.root == root: return server
  result = startIdeServer(root)
  let server = result
  server.onMessage = proc(peer: IdePeer, text: string) =
    peer.send(handleIdeMessage(server, peer, text))
    try:
      if parseJson(text){"method"}.getStr == "initialize":
        if latest != nil: peer.send(notification("selection_changed", latest))
        peer.send(notification("notifications/tools/list_changed", newJObject()))
    except ValueError: discard
  server.onClose = proc(peer: IdePeer) = discard closeDiffs(peer, all = true)
  ideServers.add result

proc ideEnvironment*(root: string): seq[(string, string)] =
  let server = ensureIde(root)
  if server != nil: @[("CLAUDE_CODE_SSE_PORT", $server.port), ("ENABLE_IDE_INTEGRATION", "true")]
  else: @[("CLAUDE_CODE_SSE_PORT", ""), ("ENABLE_IDE_INTEGRATION", "false")]

proc stopIde*() =
  for server in ideServers: server.stop()
  for diff in waiting: diff.reject()
  waiting = @[]
  for query in queries: query.done = true
  queries = @[]
  if active != nil: finishReview(true)
  for server in ideServers: server.pollIdeServer()
  ideServers = @[]

proc pollIde*(): bool =
  if not ideEnabled():
    if ideServers.len > 0:
      stopIde()
      return true
    return
  if not modeLineInstalled:
    modeLineInstalled = true
    let previous = modeLineHook
    modeLineHook = proc(): string =
      result = if previous != nil: previous() else: ""
      for server in ideServers:
        if server.connected():
          result.add "  Claude ⇄"
          break
  for server in ideServers:
    let before = server.connected()
    server.pollIdeServer()
    if before != server.connected(): result = true
  if active != nil and active.target == reviewTarget and reviewOpen():
    if active.target.text != reviewState.originalText(): finishReview(true)
    elif reviewCurrent() and reviewState.decisions.len > 0 and reviewState.decisions.allIt(it == accepted): finishReview()
  startNextReview()
  for i in countdown(queries.high, 0):
    let query = queries[i]
    if not query.done and not query.peer.closed and epochTime() - query.started > 10:
      query.peer.send(rpcError(query.id, -32000, "Language server timed out"))
      query.done = true
    if query.done or query.peer.closed: queries.delete(i)
  if epochTime() - lastWriteCheck >= 0.5:
    lastWriteCheck = epochTime()
    var finished: seq[Buffer]
    for buf, approved in awaitingWrites:
      if buf notin reg or buf.text != approved.text or epochTime() - approved.since > 30:
        finished.add buf
      elif fileExists(buf.path):
        try:
          if buf.acknowledgeSave(loadBuffer(buf.path)):
            finished.add buf
            result = true
        except CatchableError: discard
    for buf in finished: awaitingWrites.del(buf)
  let specs = $toolSpecs(allowedTools())
  if specs != lastTools:
    lastTools = specs
    for server in ideServers: server.broadcast(notification("notifications/tools/list_changed", newJObject()))
  if epochTime() - lastSelectionAt >= 0.15:
    lastSelectionAt = epochTime()
    let selection = selectionOf(b)
    if selection{"success"}.getBool:
      latest = selection
      let wire = $selection
      if wire != lastSelection:
        lastSelection = wire
        for server in ideServers: server.broadcast(notification("selection_changed", selection))

interp.defPrimitive("claude-code-mention", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let selection = selectionOf(b)
  if not selection{"success"}.getBool:
    echoLine = "Buffer has no local file"
    return nilValue()
  var ending = selection["selection"]["end"]["line"].getInt
  let start = selection["selection"]["start"]["line"].getInt
  if ending > start and selection["selection"]["end"]["character"].getInt == 0: dec ending
  var sent = false
  for server in ideServers:
    if server.connected():
      server.broadcast(notification("at_mentioned", %*{"filePath": b.path, "lineStart": start, "lineEnd": ending}))
      sent = true
  echoLine = if sent: "Mentioned in Claude Code" else: "No Claude Code IDE connection"
  nilValue())

tickHooks.add pollIde
exitHooks.add stopIde
defaults.add "(setq claude-code-ide t)\n(setq claude-code-ide-tools '(" & ideToolNames.join(" ") & "))\n"
