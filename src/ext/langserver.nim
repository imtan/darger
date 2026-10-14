## Language servers (lsp.nim speaks the protocol): diagnostics under the text and in the
## echo line, completion and hover popups, definitions, references and formatting.
import std/[os, strutils, unicode, times, tables, sets, json, math]
from windy import imeCompositionString
import ../[core, buffer, buffers, render, lisp, lsp, syntax, complete, skk]

const
  compRows* = 8    # the completion box's most rows
  hoverRows* = 12  # the hover box's

var
  clients*: Table[string, Client]  # by language name; nil = it has no server (reported once)
  lspReported*: HashSet[string]    # languages whose server failure was reported
  diagEcho*: string                # the diagnostic echoLine shows for the resting cursor, "" = none
  restBuf*: Buffer                 # where the cursor rests, since when, and whether it was shown
  restAt*: Point
  restSince*: float
  restShown*: bool
  marks*: seq[seq[int8]]           # b's diagnostic severity per rune, for marksKey
  marksKey*: (Buffer, string, int)
  compItems*: seq[CompItem]        # the completion popup: the server's items,
  compShown*: seq[int]             # those matching the prefix (indexes into compItems),
  compIndex*, compTop*: int         # the selected one and the first row shown,
  compStart*, compVersion*: int     # the prefix's start offset and b.version at the request
  compActive*, compPending*: bool
  compIncomplete*: bool            # the server cut the list short: typing asks again
  compBuf*: Buffer
  compSerial*: int                 # bumped by closeComp, so a late answer is dropped
  autoAt*: float                   # when an identifier char was typed (auto completion), 0 = none
  autoBuf*: Buffer
  autoVersion*: int
  hoverText*: seq[string]          # the hover box, wrapped, and its first row shown
  hoverTop*: int
  hoverActive*: bool
  hoverBuf*: Buffer

proc clientFor*(name: string): Client =
  ## The language's client, started the first time a buffer of it is shown; nil = none.
  if name in clients: return clients[name]
  let command = serverFor(name)
  if command.len == 0:
    clients[name] = nil
    let why = missingServer(name)
    if why.len > 0: echoLine = "No language server for " & name & " (" & why & ")"
    return nil
  result = newClient(command, if b.path.len > 0: rootOf(b.path) else: getCurrentDir(), name)
  clients[name] = result
  if result.state == lsStarting: result.initialize()

proc docClient*(buf: Buffer): Client =
  ## The client buf is open in, or nil.
  if buf notin reg or reg.slot(buf).docUri.len == 0: nil
  else: clients.getOrDefault(reg.slot(buf).docLang)

proc closeDoc*(buf: Buffer) =
  let c = docClient(buf)
  if c == nil: return
  if c.state == lsReady: c.didClose(reg.slot(buf).docUri)
  reg.slot(buf).docUri = ""

proc lspSync*(force = false) =
  ## Opens b in its language's server once that is ready, and sends its edits 150 ms
  ## after the last one (at once when force).
  if b notin reg: return
  let name = if b.path.len > 0 and hasServer(lang.name): lang.name else: ""
  if reg.slot(b).docUri.len > 0 and (reg.slot(b).docLang != name or reg.slot(b).docPath != b.path):
    closeDoc(b)  # renamed by C-x C-w, or its language changed
  if name.len == 0: return
  let c = clientFor(name)
  if c == nil or c.state != lsReady: return  # opened once initialize is answered
  if reg.slot(b).docUri.len == 0:
    let uri = uriOf(b.path)
    c.didOpen(uri, languageId(name, b.path), b.lines, b.version)
    reg.slot(b).docUri = uri
    reg.slot(b).docLang = name
    reg.slot(b).docPath = b.path
    reg.slot(b).docVersion = b.version
    return
  if b.version == reg.slot(b).docVersion: return
  let now = epochTime()
  if b.version != reg.slot(b).seen:
    reg.slot(b).seen = b.version
    reg.slot(b).seenAt = now
  if force or now - reg.slot(b).seenAt >= 0.15:
    c.didChange(reg.slot(b).docUri, b.lines, b.version)
    reg.slot(b).docVersion = b.version

proc lspPoll*(): bool =
  ## Reads every server; true when something visible changed.
  for name, c in clients:
    if c == nil: continue
    if c.poll(): result = true
    if c.state == lsFailed and name notin lspReported:
      lspReported.incl name
      echoLine = "LSP " & name & ": " & c.lastError & " (M-x lsp-log)"
      result = true
    if c.lastMessage.len > 0:
      echoLine = c.lastMessage
      c.lastMessage = ""
    for meth in c.expire():
      echoLine = "LSP: " & meth & " timed out"
      if meth == "textDocument/completion": compPending = false
      result = true

proc diagnostics*(): seq[Diagnostic] =
  ## b's diagnostics, in rune columns of the text last sent.
  let c = docClient(b)
  if c != nil: result = c.diagnostics.getOrDefault(reg.slot(b).docUri)

proc updateMarks*() =
  ## marks: b's diagMarks, recomputed when b, its document or its diagnostics change.
  let c = docClient(b)
  if c == nil:
    (marks = @[]; marksKey = (nil, "", 0))
    return
  let key = (b, reg.slot(b).docUri, c.generation)
  if key == marksKey: return
  marksKey = key
  marks = diagMarks(b.lines, c.diagnostics.getOrDefault(key[1]))

proc diagCounts*(): string =
  var errors, warnings = 0
  for d in diagnostics():
    if d.severity == 1: inc errors
    elif d.severity == 2: inc warnings
  if errors + warnings > 0: " E:" & $errors & " W:" & $warnings else: ""

proc restEcho*(): bool =
  ## After the cursor rests 500 ms on a diagnostic, echoLine shows it until the cursor moves.
  if mode.len > 0 or b notin reg: return
  if restBuf != b or restAt != b.cursor:
    restBuf = b
    restAt = b.cursor
    restSince = epochTime()
    restShown = false
    if diagEcho.len > 0 and echoLine == diagEcho:
      echoLine = ""
      result = true
    diagEcho = ""
    return
  if echoLine != diagEcho: diagEcho = ""  # replaced or cleared by something else
  if restShown or echoLine.len > 0 or epochTime() - restSince < 0.5: return
  let p = b.cursor
  for d in diagnostics():
    let endCol = if d.endLine == d.line: max(d.endCol, d.col + 1) else: d.endCol
    if (p.line, p.col) >= (d.line, d.col) and (p.line, p.col) < (d.endLine, endCol):
      echoLine = ["error", "warning", "info", "hint"][d.severity - 1] & ": " & firstLine(d.message)
      diagEcho = echoLine
      restShown = true
      return true

proc identRune*(r: Rune): bool = r.isAlpha or r == Rune('_') or int(r) in ord('0')..ord('9')

proc identStart*(): int =
  ## The offset where the identifier ending at the cursor starts.
  let line = b.lines[b.cursor.line]
  var col = b.cursor.col
  while col > 0 and identRune(line[col - 1]): dec col
  b.offset((b.cursor.line, col))

proc lspTarget*(): Client =
  ## b's server, ready and sent b's latest text; nil with the reason echoed.
  lspSync(true)
  let c = docClient(b)
  if c != nil and c.state == lsReady: return c
  let s = clients.getOrDefault(lang.name)
  echoLine = if s != nil and s.state == lsStarting: "LSP: " & lang.name & " server is starting"
         else: "No language server for " & (if b.path.len > 0: lang.name else: "this buffer")

proc position*(at: Point): JsonNode =
  %*{"textDocument": {"uri": reg.slot(b).docUri},
    "position": {"line": at.line, "character": utf16Col(b.lines[at.line], at.col)}}

proc lspCall*(c: Client, meth: string, params: JsonNode, onResult: proc(res: JsonNode)) =
  ## Sends a request without waiting; its answer runs onResult later, an error is echoed.
  c.request(meth, params, proc(res, error: JsonNode) =
    try:
      if error != nil and error.kind != JNull: echoLine = "LSP: " & error{"message"}.getStr
      else: onResult(res)
    except CatchableError as e: echoLine = e.msg)

proc closeComp*() =
  compActive = false
  compPending = false
  compItems = @[]
  compShown = @[]
  compIncomplete = false
  autoAt = 0
  inc compSerial

proc composing*(): bool =
  ## An OS IME or SKK composition is under way; completion stays out of its way.
  window.imeCompositionString.len > 0 or inputMethod.preedit().len > 0

proc refilter*(): bool =
  ## compShown for what was typed since compStart; closes (false) when nothing matches
  ## or the cursor left the identifier.
  let p = b.point(compStart)
  if b != compBuf or p.line != b.cursor.line or p.col > b.cursor.col:
    closeComp()
    return false
  let typed = b.lines[p.line][p.col ..< b.cursor.col]
  for r in typed:
    if not identRune(r):
      closeComp()
      return false
  var keys: seq[string]
  var byKey: Table[string, seq[int]]
  for i, it in compItems:
    let key = if it.filterText.len > 0: it.filterText else: it.label
    if key notin byKey: keys.add key
    byKey.mgetOrPut(key, @[]).add i
  compShown = @[]
  for key in filter($typed, keys): compShown.add byKey[key]
  if compShown.len == 0:
    closeComp()
    return false
  compIndex = 0
  compTop = 0
  compActive = true
  true

proc requestCompletion*(manual: bool, trigger = "", refresh = false) =
  ## Asks for completions at the cursor; the popup opens when they arrive, filtered by
  ## whatever was typed meanwhile. trigger: the trigger character just typed; refresh:
  ## re-asks for an incomplete list, which stays open until the answer replaces it.
  var c: Client
  if manual: c = lspTarget()
  else:
    lspSync(true)
    c = docClient(b)
    if c != nil and c.state != lsReady: c = nil
  if c == nil: return
  if refresh: inc compSerial  # drops an older answer
  else: closeComp()
  let serial = compSerial
  compBuf = b
  compStart = identStart()
  compVersion = b.version
  compPending = true
  var params = position(b.cursor)
  # Without the context clangd takes "public:" or "a >" as an explicit request.
  params["context"] = if trigger.len > 0: %*{"triggerKind": 2, "triggerCharacter": trigger}
                      else: %*{"triggerKind": (if refresh: 3 else: 1)}
  c.request("textDocument/completion", params, proc(res, error: JsonNode) =
    if serial != compSerial: return  # closed or superseded meanwhile
    compPending = false
    if error != nil and error.kind != JNull:
      if manual: echoLine = "LSP: " & error{"message"}.getStr
      return
    if composing():
      closeComp()
      return
    try:
      let chosen = if refresh and compActive: compItems[compShown[compIndex]].label else: ""
      compItems = parseCompletion(res)
      compIncomplete = incompleteList(res)
      if refilter():
        for i, n in compShown:
          if chosen.len > 0 and compItems[n].label == chosen: compIndex = i
      elif manual: echoLine = "No completions"
    except CatchableError as e: echoLine = e.msg)

proc acceptComp*() =
  ## Inserts the selected item, with its additionalTextEdits (an #include, '.' -> '->').
  let it = compItems[compShown[compIndex]]
  var start = b.point(compStart)
  if it.edit and it.line == b.cursor.line: start = (it.line, lsp.runeCol(b.lines[it.line], it.col))
  let stop = b.cursor
  if start.col > stop.col: start = stop
  closeComp()
  let line = b.lines[stop.line]
  let main = TextEdit(line: stop.line, col: utf16Col(line, start.col), endLine: stop.line,
    endCol: utf16Col(line, stop.col), newText: it.text)
  discard applyEdits(b, @[main] & it.extra)
  b.finish()

proc autoComplete*(): bool =
  let v = interp.env.values.getOrDefault("lsp-auto-complete")
  v != nil and v.kind != vNil

proc scheduleAuto*() =
  autoAt = epochTime()
  autoBuf = b
  autoVersion = b.version

proc afterInsert*(r: Rune) =
  ## After a self-insert: refilter the popup (asking again later when the server's list
  ## was incomplete), or schedule / trigger completion.
  if compActive and identRune(r):
    let incomplete = compIncomplete
    if refilter() and not incomplete: return
    if incomplete:
      scheduleAuto()
      return
  if compActive: closeComp()
  if not autoComplete(): return
  let c = docClient(b)
  if c != nil and c.state == lsReady and $r in c.triggerCharacters:
    requestCompletion(false, $r)
  elif identRune(r): scheduleAuto()

proc autoTick*() =
  ## Completion once the buffer has been idle 300 ms after typing an identifier: a new
  ## one (auto completion), or a narrower one for an open incomplete list.
  if autoAt == 0 or epochTime() - autoAt < 0.3: return
  autoAt = 0
  if mode.len > 0 or b != autoBuf or b.version != autoVersion or compPending or composing(): return
  if compActive: requestCompletion(false, refresh = true)
  elif b.offset(b.cursor) - identStart() >= 2: requestCompletion(false)

proc wrapCells*(s: string, width: int): seq[string] =
  ## s in pieces of at most width cells.
  var piece = ""
  var cells = 0
  for r in s.runes:
    let w = runeWidth(r)
    if cells + w > width and piece.len > 0:
      result.add piece
      (piece = ""; cells = 0)
    piece.add r
    cells += w
  if piece.len > 0 or result.len == 0: result.add piece

proc popupKey*(c: string): bool =
  ## The completion and hover popups' keys; any other key closes them and runs as usual.
  if mode.len == 0 and prefix.len == 0 and compActive and b == compBuf:
    result = true
    case c
    of "C-n", "down": compIndex = floorMod(compIndex + 1, compShown.len)
    of "C-p", "up": compIndex = floorMod(compIndex - 1, compShown.len)
    of "enter", "C-m", "tab", "C-i": acceptComp()
    of "C-g", "escape": closeComp()
    else: result = false
    if result: return
  if mode.len == 0 and prefix.len == 0 and hoverActive and b == hoverBuf:
    if c in ["C-g", "escape"]:
      hoverActive = false
      return true
    # The box may be cut to fewer rows near the window's edges.
    let shown = max(1, renderer.boxRows(hoverText.len, hoverRows, b.cursor.line - renderer.top))
    let bottom = max(0, hoverText.len - shown)
    let page = max(1, shown - 1)
    if bottom > 0:  # longer than the box: these scroll it
      result = true
      case c
      of "C-n", "down": hoverTop = min(hoverTop + 1, bottom)
      of "C-p", "up": hoverTop = max(hoverTop - 1, 0)
      of "C-v", "pagedown": hoverTop = min(hoverTop + page, bottom)
      of "M-v", "pageup": hoverTop = max(hoverTop - page, 0)
      else: result = false
      if result: return
  hoverActive = false
  closeComp()

proc cursorPopup*(): CursorBox =
  ## The completion or hover box for redraw; both close once a prompt opens or b changes.
  result = CursorBox(selected: -1)
  if mode.len > 0 or b != compBuf: (if compActive or compPending: closeComp())
  if mode.len > 0 or b != hoverBuf: hoverActive = false
  if compActive:
    let p = b.point(compStart)
    let rows = max(1, renderer.boxRows(compShown.len, compRows, p.line - renderer.top))
    compTop = clamp(compTop, compIndex - rows + 1, compIndex)  # the selection stays shown
    for i in compShown:
      result.lines.add compItems[i].label
      result.tags.add kindTag(compItems[i].kind)
      result.details.add compItems[i].detail
    (result.selected, result.top, result.maxRows) = (compIndex, compTop, compRows)
    (result.line, result.cell) = (p.line, b.cellCol(p))
  elif hoverActive:
    (result.lines, result.top, result.maxRows) = (hoverText, hoverTop, hoverRows)
    (result.line, result.cell) = (b.cursor.line, b.cellCol(b.cursor))

proc lspHover*() =
  let c = lspTarget()
  if c == nil: return
  let buf = b
  let at = b.cursor
  let version = b.version
  c.lspCall("textDocument/hover", position(at)) do (res: JsonNode):
    if b != buf or b.cursor != at or b.version != version or mode.len > 0: return
    hoverText = @[]
    for line in hoverLines(res): hoverText.add wrapCells(line, clamp(renderer.cols - 2, 10, 60))
    if hoverText.len == 0:
      echoLine = "No hover"
      return
    hoverTop = 0
    hoverActive = true
    hoverBuf = b

proc gotoLocation*(meth, what: string) =
  ## M-. and friends: jumps to the first location the server gives.
  let c = lspTarget()
  if c == nil: return
  let buf = b
  let at = b.cursor
  let (top, left) = (renderer.top, renderer.left)
  c.lspCall(meth, position(at)) do (res: JsonNode):
    if b != buf or b.cursor != at or mode.len > 0: return  # the user moved on
    let locs = parseLocations(res)
    if locs.len == 0:
      echoLine = "No " & what
      return
    if reg.byPath(locs[0].path) != b: visit(locs[0].path)
    let line = clamp(locs[0].line, 0, b.lines.high)
    b.cursor = (line, lsp.runeCol(b.lines[line], locs[0].col))
    b.finish()
    pushXref(buf, at, top, left)
    recenterCycle = 0
    recenter(b)
    renderer.left = 0

proc lspReferences*() =
  let c = lspTarget()
  if c == nil: return
  let buf = b
  let at = b.cursor
  let root = c.root
  var params = position(at)
  params["context"] = %*{"includeDeclaration": true}
  c.lspCall("textDocument/references", params) do (res: JsonNode):
    if b != buf or b.cursor != at or mode.len > 0: return
    let locs = parseLocations(res)
    if locs.len == 0:
      echoLine = "No references"
      return
    proc linesOf(f: string): seq[seq[Rune]] =
      let open = reg.byPath(f)
      if open != nil: return open.lines
      try:
        for s in readFile(f).replace("\r\n", "\n").split('\n'): result.add s.toRunes
      except IOError: discard
    proc nameOf(f: string): string =
      result = relativePath(f, root)
      if result.startsWith(".."): result = shortPath(f)
    (targets, refRows) = referenceRows(locs, linesOf, nameOf)
    beginMini("refs", "References: ")

proc lspFormat*() =
  let c = lspTarget()
  if c == nil: return
  let buf = b
  let version = b.version
  c.lspCall("textDocument/formatting", %*{"textDocument": {"uri": reg.slot(b).docUri},
      "options": {"tabSize": 4, "insertSpaces": true}}) do (res: JsonNode):
    if buf notin reg or buf.version != version:
      echoLine = "Buffer changed; not formatted"
      return
    if applyEdits(buf, parseEdits(res)): buf.finish()
    echoLine = "Formatted"

for (name, run) in [("completion-at-point", proc() = requestCompletion(true)),
    ("lsp-hover", lspHover),
    ("lsp-definition", proc() = gotoLocation("textDocument/definition", "definition")),
    ("lsp-type-definition", proc() = gotoLocation("textDocument/typeDefinition", "type definition")),
    ("lsp-implementation", proc() = gotoLocation("textDocument/implementation", "implementation")),
    ("lsp-references", lspReferences), ("lsp-format-buffer", lspFormat)]:
  closureScope:
    let f = run
    interp.defPrimitive(name, proc(args: seq[Value]): Value =
      args.arity(0, 0)
      f()
      nilValue())

interp.defPrimitive("consult-flymake", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  lspSync(true)
  if diagnostics().len == 0: echoLine = "No diagnostics"
  else: beginMini("diag", "Diagnostic: ")
  nilValue())

interp.defPrimitive("lsp-server", proc(args: seq[Value]): Value =
  args.arity(2, 2)
  let name = args[0].asString
  setServer(name, args[1].asString)
  if clients.getOrDefault(name) == nil: clients.del name  # retried when next shown
  args[1])

interp.defPrimitive("lsp-restart", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let name = lang.name
  if not hasServer(name):
    echoLine = "No language server for " & name
    return nilValue()
  shutdown(clients.getOrDefault(name))
  clients.del name
  lspReported.excl name
  for s in reg.slots.mitems:
    if s.docLang == name: s.docUri = ""
  echoLine = ""
  lspSync(true)
  let c = clients.getOrDefault(name)
  if echoLine.len == 0 and c != nil: echoLine = "Restarted " & c.command
  nilValue())

interp.defPrimitive("lsp-log", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let c = clients.getOrDefault(lang.name)
  echoLine = if c != nil: c.logPath else: "No language server for " & lang.name
  nilValue())

proc diagRowsNow*(): seq[string] =
  targets = @[]
  for d in diagnostics(): targets.add Location(line: d.line, col: d.col)
  diagRows(diagnostics())
definePrompt(Prompt(kind: "diag", text: true, consult: true, candidates: diagRowsNow, onAccept: acceptNothing))
definePrompt(Prompt(kind: "refs", text: true, consult: true, candidates: refRowsNow, onAccept: acceptReference))

tickHooks.add proc(): bool =
  lspSync()
  if lspPoll(): result = true
  if restEcho(): result = true
  autoTick()
exitHooks.add proc() =
  var servers: seq[Client]
  for c in clients.values: servers.add c
  shutdown(servers)
keyFilters.add popupKey
escapeHooks.add proc(): bool = compActive or hoverActive
runeHooks.add proc() =
  hoverActive = false
  if skkOn(): closeComp()  # ponytail: SKK input never drives the completion popup
insertHooks.add afterInsert
imeHooks.add proc() =
  closeComp()  # its keys go to the IME, so the popups could not be closed
  hoverActive = false
killHooks.add closeDoc
saveHooks.add proc() =
  lspSync(true)
  let c = docClient(b)
  if c != nil and c.state == lsReady: c.didSave(reg.slot(b).docUri)
marksHook = proc(): seq[seq[int8]] =
  updateMarks()
  marks
boxHook = cursorPopup
modeLineHook = diagCounts
argCommands.add "lsp-server"
defaults.add """
(global-set-key "M-g f" 'consult-flymake)
(global-set-key "C-M-i" 'completion-at-point)
(global-set-key "C-c h" 'lsp-hover)
(global-set-key "M-." 'lsp-definition)
(global-set-key "M-?" 'lsp-references)
(global-set-key "C-c =" 'lsp-format-buffer)
(setq lsp-auto-complete t)
"""
