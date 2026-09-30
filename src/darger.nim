import std/[os, osproc, tempfiles, strutils, times, unicode, tables, sets, math, json]
import windy, vmath
import buffer, buffers, render, skk, lisp, review, manual, recent, syntax, complete, lsp

const
  bufferCommands = ["forward", "backward", "next-line", "previous-line", "bol", "eol",
    "bob", "eob", "indent", "forward-word", "backward-word", "newline", "tab", "open-line",
    "delete", "backspace", "kill-line", "kill-word", "backward-kill-word", "mark", "exchange",
    "whole", "kill-region", "copy-region", "yank", "yank-pop", "undo", "transpose",
    "upcase", "downcase", "capitalize", "quit"]
  helpNavigation = ["forward", "backward", "next-line", "previous-line", "bol", "eol", "bob", "eob"]
  helpMessage = "Help  q:close  F1:toggle"
  dashMessage = "Dashboard  Enter:open  q:scratch  F1:manual"
  blistMessage = "Buffers  Enter:switch  k:kill  q:close"
  overlays = ["review", "help", "dash", "blist"]
  textPrompts = ["find", "write", "search", "agent", "switch", "kill", "line", "diag", "refs"]  # SKK works in these
  candModes = ["find", "write", "execute", "switch", "kill", "line", "diag", "refs"]  # prompts with a candidate list
  consults = ["line", "diag", "refs"]  # candidate lists that preview a position
  compRows = 8    # the completion box's most rows
  hoverRows = 12  # the hover box's
  argCommands = ["global-set-key", "insert", "command", "agent", "find-file", "load-theme",
    "hydra", "lsp-server"]  # primitives M-x cannot call without arguments
  dashLabels = "123456789abc"
  dashFirst = 4  # line of the first recent-file entry
  defaultBindings = """
(global-set-key "C-f" 'forward)
(global-set-key "right" 'forward)
(global-set-key "C-b" 'backward)
(global-set-key "left" 'backward)
(global-set-key "C-n" 'next-line)
(global-set-key "down" 'next-line)
(global-set-key "C-p" 'previous-line)
(global-set-key "up" 'previous-line)
(global-set-key "C-a" 'bol)
(global-set-key "home" 'bol)
(global-set-key "C-e" 'eol)
(global-set-key "end" 'eol)
(global-set-key "M-f" 'forward-word)
(global-set-key "M-b" 'backward-word)
(global-set-key "M-<" 'bob)
(global-set-key "C-home" 'bob)
(global-set-key "M->" 'eob)
(global-set-key "C-end" 'eob)
(global-set-key "M-m" 'indent)
(global-set-key "enter" 'newline)
(global-set-key "C-m" 'newline)
(global-set-key "C-j" 'newline)
(global-set-key "tab" 'tab)
(global-set-key "C-i" 'tab)
(global-set-key "backspace" 'backspace)
(global-set-key "C-h" 'backspace)
(global-set-key "C-d" 'delete)
(global-set-key "delete" 'delete)
(global-set-key "C-k" 'kill-line)
(global-set-key "C-o" 'open-line)
(global-set-key "C-t" 'transpose)
(global-set-key "M-d" 'kill-word)
(global-set-key "M-backspace" 'backward-kill-word)
(global-set-key "M-u" 'upcase)
(global-set-key "M-l" 'downcase)
(global-set-key "M-c" 'capitalize)
(global-set-key "C-SPC" 'mark)
(global-set-key "C-@" 'mark)
(global-set-key "C-x C-x" 'exchange)
(global-set-key "C-w" 'kill-region)
(global-set-key "M-w" 'copy-region)
(global-set-key "C-y" 'yank)
(global-set-key "M-y" 'yank-pop)
(global-set-key "C-x h" 'whole)
(global-set-key "C-/" 'undo)
(global-set-key "C-_" 'undo)
(global-set-key "C-x u" 'undo)
(global-set-key "C-c a" 'agent-prompt)
(global-set-key "f1" 'help)
(global-set-key "C-x C-j" 'skk-mode)
(global-set-key "C-backslash" 'skk-mode)
(global-set-key "C-c ," (lambda () (find-file "~/.darger.el")))
(global-set-key "C-x b" 'switch-to-buffer)
(global-set-key "C-x k" 'kill-buffer)
(global-set-key "C-x C-b" 'list-buffers)
(global-set-key "C-x right" 'next-buffer)
(global-set-key "C-x left" 'previous-buffer)
(global-set-key "M-g l" 'consult-line)
(global-set-key "M-g f" 'consult-flymake)
(global-set-key "C-M-i" 'completion-at-point)
(global-set-key "C-c h" 'lsp-hover)
(global-set-key "M-." 'lsp-definition)
(global-set-key "M-," 'lsp-back)
(global-set-key "M-?" 'lsp-references)
(global-set-key "C-c =" 'lsp-format-buffer)
(global-set-key "f2 g" 'zoom-in)
(global-set-key "f2 l" 'zoom-out)
(global-set-key "f2 0" 'zoom-reset)
(hydra "f2" "zoom  g:in  l:out  0:reset")
(setq agent-command "claude -p --output-format text")
(setq lsp-auto-complete t)
"""

when defined(windows):
  import std/[winlean, streams]
  proc getKeyState(key: int32): int16 {.stdcall, importc: "GetKeyState", dynlib: "user32".}
  proc createJobObject(attributes: pointer, name: WideCString): Handle {.stdcall, importc: "CreateJobObjectW", dynlib: "kernel32".}
  proc assignProcessToJobObject(job, process: Handle): WINBOOL {.stdcall, importc: "AssignProcessToJobObject", dynlib: "kernel32".}
  proc terminateJobObject(job: Handle, code: uint32): WINBOOL {.stdcall, importc: "TerminateJobObject", dynlib: "kernel32".}
else:
  import std/posix
  when defined(linux):
    # windy's buttonToggle never reads the X lock state, so query it on a private connection.
    proc XOpenDisplay(name: cstring): pointer {.cdecl, importc, dynlib: "libX11.so(|.6)".}
    # XWayland can leave the Num Lock LED out of sync with the locked modifier that
    # X uses for keysym translation, so read the effective locked mods, not the LED.
    type XkbStateRec {.bycopy.} = object
      group, locked_group: uint8
      base_group, latched_group: uint16
      mods, base_mods, latched_mods, locked_mods: uint8
      compat_state: uint8
      grab_mods, compat_grab_mods, lookup_mods, compat_lookup_mods: uint8
      ptr_buttons: uint16
    proc XkbGetState(d: pointer, spec: cuint, state: ptr XkbStateRec): cint {.cdecl, importc, dynlib: "libX11.so(|.6)".}
    proc XkbKeysymToModifiers(d: pointer, ks: culong): cuint {.cdecl, importc, dynlib: "libX11.so(|.6)".}
    let lockDisplay = XOpenDisplay(nil)
    let numLockMask = if lockDisplay != nil: XkbKeysymToModifiers(lockDisplay, 0xff7f) else: 0  # XK_Num_Lock

var b = newBuffer()  # the current buffer; reg holds every open one
var reg: Registry
reg.add b
reg.touch b
var
  lang = detect("", "")  # b's language, re-detected whenever b or b.path changes
  shownBuf: Buffer       # the buffer and version that faces were computed for
  shownVersion: int
  faces: seq[seq[Face]]

proc detectLang() =
  lang = detect(b.path, if b.lines.len > 0: $b.lines[0] else: "")
  shownBuf = nil

var
  window = newWindow("darger", ivec2(1000, 720), style = Undecorated, vsync = true)
window.makeContextCurrent()
window.runeInputEnabled = true
var renderer: Renderer
try: renderer = newRenderer()
except CatchableError as e:
  stderr.writeLine(e.msg)
  window.close()
  quit(1)
let inputMethod = newSkk()
var
  echo, prefix, mode, prompt: string
  mini = newBuffer()
  running = true
  suppressRune = false
  recenterCycle = 0
  isearch: ISearch
  lastSearch: string
  matchStart = -1
  pendingPath: string
  highSurrogate = 0
  interp = newInterp()
  keymap: Table[string, Value]
  prefixKeys = toHashSet(["C-x", "M-g"])
  hydras: Table[string, string]  # sticky prefix -> hint
  agentProcess: Process
  agentDir: string
  agentCancelled = false
  reviewState: Review
  reviewBuf: Buffer
  reviewColors: seq[int8]
  currentHunk, savedTop, savedLeft: int
  helpBuf, dashBuf, blistBuf: Buffer
  overlayTop, overlayLeft: int
  dashFiles: seq[string]
  blistBufs: seq[Buffer]
  pendingKill: Buffer  # awaiting y/n: the "killy" prompt or k in the buffer list
  agentBuf: Buffer
  candAll, cands: seq[string]  # the prompt's candidates, and those matching mini.text
  candIndex = -1               # the selected one in cands, -1 = none
  candText: string             # the mini.text cands were computed for
  candDir: string              # file prompts: the listed directory (and whether dot-files are in)
  candSkip: int                # consult-line: bytes of the "  12  " line-number column
  lineOrigin: Point            # consult-line: where C-g returns to
  lineTop, lineLeft: int
when defined(windows):
  var agentJob: Handle
else:
  var agentGroup: bool
var
  clients: Table[string, Client]  # by language name; nil = it has no server (reported once)
  lspReported: HashSet[string]    # languages whose server failure was reported
  diagEcho: string                # the diagnostic echo shows for the resting cursor, "" = none
  restBuf: Buffer                 # where the cursor rests, since when, and whether it was shown
  restAt: Point
  restSince: float
  restShown: bool
  marks: seq[seq[int8]]           # b's diagnostic severity per rune, for marksKey
  marksKey: (Buffer, string, int)
  compItems: seq[CompItem]        # the completion popup: the server's items,
  compShown: seq[int]             # those matching the prefix (indexes into compItems),
  compIndex, compTop: int         # the selected one and the first row shown,
  compStart, compVersion: int     # the prefix's start offset and b.version at the request
  compActive, compPending: bool
  compIncomplete: bool            # the server cut the list short: typing asks again
  compBuf: Buffer
  compSerial: int                 # bumped by closeComp, so a late answer is dropped
  autoAt: float                   # when an identifier char was typed (auto completion), 0 = none
  autoBuf: Buffer
  autoVersion: int
  hoverText: seq[string]          # the hover box, wrapped, and its first row shown
  hoverTop: int
  hoverActive: bool
  hoverBuf: Buffer
  xrefStack: seq[(Buffer, Point, int, int)]  # M-. origins: buffer, cursor, top, left
  targets: seq[Location]          # consult prompts: each candAll row's position, rune
                                  # columns; path "" = the origin buffer
  refRows: seq[string]            # M-? rows, whose targets lspReferences sets
  refOrigin: Buffer
  previewed: seq[Buffer]          # buffers opened only to preview a reference
  candIdx: seq[int]               # consult prompts: the candAll index of each of cands

proc clientFor(name: string): Client =
  ## The language's client, started the first time a buffer of it is shown; nil = none.
  if name in clients: return clients[name]
  let command = serverFor(name)
  if command.len == 0:
    clients[name] = nil
    let why = missingServer(name)
    if why.len > 0: echo = "No language server for " & name & " (" & why & ")"
    return nil
  result = newClient(command, if b.path.len > 0: rootOf(b.path) else: getCurrentDir(), name)
  clients[name] = result
  if result.state == lsStarting: result.initialize()

proc docClient(buf: Buffer): Client =
  ## The client buf is open in, or nil.
  if buf notin reg or reg.slot(buf).docUri.len == 0: nil
  else: clients.getOrDefault(reg.slot(buf).docLang)

proc closeDoc(buf: Buffer) =
  let c = docClient(buf)
  if c == nil: return
  if c.state == lsReady: c.didClose(reg.slot(buf).docUri)
  reg.slot(buf).docUri = ""

proc lspSync(force = false) =
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

proc lspPoll(): bool =
  ## Reads every server; true when something visible changed.
  for name, c in clients:
    if c == nil: continue
    if c.poll(): result = true
    if c.state == lsFailed and name notin lspReported:
      lspReported.incl name
      echo = "LSP " & name & ": " & c.lastError & " (M-x lsp-log)"
      result = true
    if c.lastMessage.len > 0:
      echo = c.lastMessage
      c.lastMessage = ""
    for meth in c.expire():
      echo = "LSP: " & meth & " timed out"
      if meth == "textDocument/completion": compPending = false
      result = true

proc diagnostics(): seq[Diagnostic] =
  ## b's diagnostics, in rune columns of the text last sent.
  let c = docClient(b)
  if c != nil: result = c.diagnostics.getOrDefault(reg.slot(b).docUri)

proc updateMarks() =
  ## marks: b's diagMarks, recomputed when b, its document or its diagnostics change.
  let c = docClient(b)
  if c == nil:
    (marks = @[]; marksKey = (nil, "", 0))
    return
  let key = (b, reg.slot(b).docUri, c.generation)
  if key == marksKey: return
  marksKey = key
  marks = diagMarks(b.lines, c.diagnostics.getOrDefault(key[1]))

proc diagCounts(): string =
  var errors, warnings = 0
  for d in diagnostics():
    if d.severity == 1: inc errors
    elif d.severity == 2: inc warnings
  if errors + warnings > 0: " E:" & $errors & " W:" & $warnings else: ""

proc firstLine(s: string): string =
  let i = s.find('\n')
  if i >= 0: s[0..<i] else: s

proc restEcho(): bool =
  ## After the cursor rests 500 ms on a diagnostic, echo shows it until the cursor moves.
  if mode.len > 0 or b notin reg: return
  if restBuf != b or restAt != b.cursor:
    restBuf = b
    restAt = b.cursor
    restSince = epochTime()
    restShown = false
    if diagEcho.len > 0 and echo == diagEcho:
      echo = ""
      result = true
    diagEcho = ""
    return
  if echo != diagEcho: diagEcho = ""  # replaced or cleared by something else
  if restShown or echo.len > 0 or epochTime() - restSince < 0.5: return
  let p = b.cursor
  for d in diagnostics():
    let endCol = if d.endLine == d.line: max(d.endCol, d.col + 1) else: d.endCol
    if (p.line, p.col) >= (d.line, d.col) and (p.line, p.col) < (d.endLine, endCol):
      echo = ["error", "warning", "info", "hint"][d.severity - 1] & ": " & firstLine(d.message)
      diagEcho = echo
      restShown = true
      return true


proc switchTo(buf: Buffer) =
  ## Makes buf current: parks b's scroll and language in its slot and restores buf's.
  let overlay = mode in ["help", "dash", "blist"]  # b's scroll is parked in overlayTop/Left
  if buf notin reg: reg.add buf
  if buf == b:  # its slot holds the scroll from when it was last left
    reg.touch b
    return
  if b in reg:
    reg.slot(b).top = if overlay: overlayTop else: renderer.top
    reg.slot(b).left = if overlay: overlayLeft else: renderer.left
    reg.slot(b).lang = lang
    reg.slot(b).langPath = b.path
  b.finish()
  # ponytail: each buffer has its own kill ring, synced on switch so C-y works across buffers.
  buf.kills = b.kills
  buf.yankIndex = b.yankIndex
  b = buf
  let slot = reg.slot(b)
  if overlay: (overlayTop = slot.top; overlayLeft = slot.left)
  else: (renderer.top = slot.top; renderer.left = slot.left)
  if slot.lang.name.len == 0 or slot.langPath != b.path: detectLang()
  else: lang = slot.lang
  shownBuf = nil
  reg.touch b

proc visit(path: string) =
  ## Like Emacs, visiting a file that is already open switches to it with its edits.
  var buf = reg.byPath(path)
  if buf == nil:
    buf = loadBuffer(path)
    reg.add buf
  switchTo(buf)
  if fileExists(b.path): recordRecent(b.path)  # a new file is recorded on its first save

proc anyModified(): bool =
  for s in reg.slots:
    if s.buf.modified: return true

proc killBuffer(buf: Buffer) =
  ## Killing the current buffer shows the previous one; the last one leaves a fresh *scratch*.
  closeDoc(buf)
  reg.remove buf
  if reg.len == 0: reg.add newBuffer()
  if buf == b: switchTo(reg.current)

if paramCount() >= 1:
  var opened: seq[Buffer]
  for i in 1..paramCount():
    try:
      visit(paramStr(i))
      opened.add b
    except CatchableError as e: echo = e.msg
  for i in countdown(opened.high, 1): reg.touch opened[i]
  if opened.len > 0: switchTo(opened[0])

proc ctrl(): bool = window.buttonDown[KeyLeftControl] or window.buttonDown[KeyRightControl]
proc alt(): bool = window.buttonDown[KeyLeftAlt] or window.buttonDown[KeyRightAlt]
proc shift(): bool = window.buttonDown[KeyLeftShift] or window.buttonDown[KeyRightShift]

proc keypadNavigation(): bool =
  when defined(windows): (getKeyState(0x90) and 1) == 0
  elif defined(linux):
    var state: XkbStateRec  # 0x100 = XkbUseCoreKbd
    if lockDisplay != nil and numLockMask != 0 and XkbGetState(lockDisplay, 0x100, state.addr) == 0:
      (state.locked_mods.cuint and numLockMask) == 0
    else: not window.buttonToggle[KeyNumLock]
  else: not window.buttonToggle[KeyNumLock]

proc chord(key: Button): string =
  var name = case key
    of KeySpace: "SPC"
    of NumpadEnter: "enter"
    of Numpad0..Numpad9:
      if keypadNavigation(): ["insert", "end", "down", "pagedown", "left", "", "right", "home", "up", "pageup"][ord(key)-ord(Numpad0)]
      else: $char(ord('0')+ord(key)-ord(Numpad0))
    of NumpadDecimal: (if keypadNavigation(): "delete" else: ".")
    of KeySemicolon: (if shift(): ":" else: ";")
    of KeySlash: (if shift(): "?" else: "/")
    of KeyEqual: (if shift(): "+" else: "=")
    of KeyMinus: (if shift(): "_" else: "-")
    of KeyComma: (if shift(): "<" else: ",")
    of KeyPeriod: (if shift(): ">" else: ".")
    of Key2: (if shift(): "@" else: "2")
    else: ($key).replace("Key", "").toLowerAscii
  if alt(): name = "M-" & name
  if ctrl(): name = "C-" & name
  name

proc setMini(text: string) =
  mini = newBuffer(text)
  mini.cursor = (0, mini.lines[0].len)

proc commandNames(): seq[string] =
  for name in interp.names:
    if name notin argCommands: result.add name

proc lineCandidates(): seq[string] =
  let width = len($b.lines.len)
  candSkip = width + 2
  for i, line in b.lines:
    if i == b.lines.high and line.len == 0: break  # the empty line after a final newline
    result.add align($(i + 1), width) & "  " & $line[0..<min(line.len, 200)]

proc dropPreviews(keep: Buffer = nil) =
  ## Kills the buffers opened only to preview a reference, except keep.
  for buf in previewed:
    if buf != keep and buf != b and buf in reg and not buf.modified: killBuffer(buf)
  previewed = @[]

proc pushXref(buf: Buffer, at: Point, top, left: int) =
  xrefStack.add (buf, at, top, left)
  if xrefStack.len > 50: xrefStack.delete(0)

proc restoreOrigin() =
  ## Back to where the consult prompt started, in the buffer it started in.
  if refOrigin in reg and b != refOrigin: switchTo(refOrigin)
  b.cursor = lineOrigin
  renderer.top = lineTop
  renderer.left = lineLeft
  dropPreviews()

proc abandonLine() =
  ## A consult prompt replaced by another mode leaves the preview like C-g does.
  if mode in consults:
    restoreOrigin()
    mode = ""

proc preview() =
  ## consult-line / consult-flymake / M-? show the selected target centred, opening its
  ## file for a reference elsewhere, or the origin when nothing matches.
  if candIndex < 0:
    restoreOrigin()
    return
  let t = targets[candIdx[candIndex]]
  if t.path.len > 0 and reg.byPath(t.path) != b:
    var buf = reg.byPath(t.path)
    if buf == nil:
      buf = loadBuffer(t.path)
      reg.add buf
      previewed.add buf
    switchTo(buf)
  let line = clamp(t.line, 0, b.lines.high)
  b.cursor = (line, clamp(t.col, 0, b.lines[line].len))
  # Centred in the rows above the bottom-anchored list, known from r.rows alone.
  let space = renderer.popupRows(cands.len, atBottom).top
  renderer.top = max(0, line - (if space >= 1: space div 2 else: renderer.rows div 2))
  renderer.left = 0

proc refreshCandidates(force = false) =
  ## Refilters after mini.text changed; like vertico, the first match is preselected.
  if mode notin candModes:
    candAll = @[]
    cands = @[]
    candIndex = -1
    return
  if not force and mini.text == candText: return
  candText = mini.text
  var query = mini.text
  if mode in ["find", "write"]:
    let (dir, tail) = splitInput(mini.text)
    let key = dir & (if tail.startsWith("."): "\0." else: "")
    if force or key != candDir:
      candDir = key
      candAll = listDir(dir, tail.startsWith("."))
    query = tail
  if mode in consults:  # kept in position order; consult-line does not match its line numbers
    cands = @[]
    candIdx = @[]
    for i, c in candAll:
      if matches(query, c[(if mode == "line": candSkip else: 0)..^1]):
        cands.add c
        candIdx.add i
  else: cands = filter(query, candAll)
  candIndex = if cands.len > 0: 0 else: -1
  if mode in consults: preview()

proc beginMini(kind, label: string, initial = "") =
  b.finish()
  mode = kind
  prompt = label
  setMini(initial)
  echo = ""
  prefix = ""
  if kind in consults:
    (lineOrigin = b.cursor; lineTop = renderer.top; lineLeft = renderer.left; refOrigin = b)
    previewed = @[]
  let names = reg.names  # most recently used first: b, then the default of C-x b
  candAll = case kind
    of "execute": commandNames()
    of "switch": names[1..^1] & names[0..0]
    of "kill": names
    of "line": lineCandidates()
    of "diag": diagRows(diagnostics())
    of "refs": refRows
    else: @[]
  case kind  # refs: set by lspReferences
  of "line":
    targets = @[]
    for i in 0..<candAll.len: targets.add Location(line: i)
  of "diag":
    targets = @[]
    for d in diagnostics(): targets.add Location(line: d.line, col: d.col)
  else: discard
  refreshCandidates(true)

proc inMini(): bool =
  ## A minibuffer prompt (search, find, y/n, ...) is active; see overlays for the rest.
  mode.len > 0 and mode notin overlays

proc beginOverlay(kind: string) =
  b.finish()
  overlayTop = renderer.top
  overlayLeft = renderer.left
  mode = kind
  prefix = ""
  matchStart = -1
  window.closeIme()
  renderer.top = 0
  renderer.left = 0

proc finishOverlay() =
  renderer.top = overlayTop
  renderer.left = overlayLeft
  mode = ""
  echo = ""

proc beginHelp() =
  beginOverlay("help")
  helpBuf = newBuffer(manualText)
  helpBuf.path = "*Help*"

proc finishHelp() =
  finishOverlay()
  helpBuf = nil

proc shortPath(path: string, limit = 64): string =
  ## ~ for HOME, then cut from the left to fit `limit` cells.
  let home = strutils.strip(getHomeDir(), leading = false, chars = {DirSep, AltSep})
  var s = path
  if home.len > 0 and s.startsWith(home) and (s.len == home.len or s[home.len] in {DirSep, AltSep}):
    s = "~" & s[home.len..^1]
  var runes = s.toRunes
  var width = 0
  for r in runes: width += runeWidth(r)
  if width <= limit: return s
  while width > limit - 3:
    width -= runeWidth(runes[0])
    runes.delete(0)
  "..." & $runes

proc beginDash() =
  beginOverlay("dash")
  dashFiles = loadRecent()
  if dashFiles.len > dashLabels.len: dashFiles.setLen(dashLabels.len)
  var lines = @["darger", "I'm talking about the present.", "", "Recent files"]
  let limit = max(30, (if renderer.cols > 0: renderer.cols else: 80) - 5)  # "  1  " prefix
  for i, f in dashFiles: lines.add "  " & dashLabels[i] & "  " & shortPath(f, limit)
  if dashFiles.len == 0: lines.add "  (none yet)"
  lines.add ""
  lines.add "F1 manual   C-x C-f open   q scratch"
  dashBuf = newBuffer(lines.join("\n"))
  dashBuf.path = "*dashboard*"
  dashBuf.cursor = if dashFiles.len > 0: (dashFirst, 2) else: (0, 0)

proc finishDash() =
  finishOverlay()
  dashBuf = nil
  dashFiles = @[]

proc cells(s: string): int =
  for r in s.runes: result += runeWidth(r)

proc buildBlist(row = 0) =
  blistBufs = reg.buffers
  let names = reg.names
  var width = 4
  for n in names: width = max(width, cells(n))
  var lines = @[" CRM " & "Name" & spaces(width - 4) & "  Path"]
  for i, buf in blistBufs:
    lines.add " " & (if buf == b: "." else: " ") & " " & (if buf.modified: "*" else: " ") & " " &
      names[i] & spaces(width - cells(names[i])) & "  " & (if buf.path.len > 0: shortPath(buf.path) else: "")
  blistBuf = newBuffer(lines.join("\n"))
  blistBuf.path = "*Buffer List*"
  blistBuf.cursor = (clamp(row, 1, max(1, blistBufs.len)), 0)

proc beginBlist() =
  let row = if reg.other != nil: 2 else: 1  # on the previous buffer, like C-x b's default
  beginOverlay("blist")
  pendingKill = nil
  buildBlist(row)

proc finishBlist() =
  finishOverlay()
  blistBuf = nil
  blistBufs = @[]
  pendingKill = nil

proc closeOverlay() =
  if mode == "help": finishHelp()
  elif mode == "dash": finishDash()
  elif mode == "blist": finishBlist()

proc reviewMessage(): string =
  "Review hunk " & $(currentHunk + 1) & "/" & $reviewState.hunks.len &
    "  y:accept k:skip a:all q:done"

proc rebuildReview() =
  let display = reviewState.view(currentHunk)
  reviewBuf = newBuffer(display.text)
  reviewBuf.path = b.path
  reviewColors = display.colors
  reviewBuf.cursor = (min(display.starts[currentHunk], reviewBuf.lines.high), 0)
  renderer.top = reviewBuf.cursor.line
  renderer.left = 0
  echo = reviewMessage()

proc beginReview(proposed: string) =
  reviewState = newReview(b.text, proposed)
  if reviewState.hunks.len == 0:
    echo = "Agent: no changes"
    return
  closeOverlay()  # the agent finished while the manual or dashboard was open
  b.finish()
  savedTop = renderer.top
  savedLeft = renderer.left
  currentHunk = 0
  mode = "review"
  prefix = ""
  matchStart = -1
  window.closeIme()
  rebuildReview()

proc finishReview(cancel = false) =
  if cancel: echo = "Review cancelled"
  else:
    let text = reviewState.appliedText()
    var count = 0
    for decision in reviewState.decisions:
      if decision == accepted: inc count
    if text != b.text:
      let point = b.offset(b.cursor)
      b.snapshot()
      b.splice(0, b.text.runeLen, text)
      b.cursor = b.point(point)
      b.finish()
    echo = "Applied " & $count & " of " & $reviewState.hunks.len & " hunks"
  mode = ""
  reviewBuf = nil
  reviewColors = @[]
  reviewState = Review()
  renderer.top = savedTop
  renderer.left = savedLeft

proc cleanAgentFiles() =
  if agentDir.len == 0: return
  try:
    for name in ["prompt.txt", "out.txt", "err.txt"]:
      let path = agentDir / name
      if fileExists(path): removeFile(path)
    removeDir(agentDir)
  except OSError as e: echo = "Agent cleanup: " & e.msg
  agentDir = ""

proc startAgent(instruction: string) =
  if agentProcess != nil: raise newException(ValueError, "Agent already running")
  let command = interp.env.values["agent-command"].asString
  if strutils.strip(command).len == 0: raise newException(ValueError, "agent-command is empty")
  agentDir = createTempDir("darger-agent-", "")
  try:
    when defined(windows):
      agentJob = createJobObject(nil, nil)
      if agentJob == 0: raiseOSError(osLastError())
    # ponytail: full-file round trips are unsuitable for huge files; add region-only input if needed.
    writeFile(agentDir / "prompt.txt",
      "You are editing a text file. Apply the instruction to the file and output ONLY the complete new file content. No explanations, no code fences.\n" &
      "File path: " & (if b.path.len > 0: b.path else: "(unnamed)") & "\n" &
      "Instruction: " & instruction & "\n--- FILE START ---\n" & b.text & "\n--- FILE END ---\n")
    when defined(windows):
      let redirected = command & " < \"" & agentDir / "prompt.txt" & "\" > \"" &
        agentDir / "out.txt" & "\" 2> \"" & agentDir / "err.txt" & "\""
      # Gate the CLI until cmd.exe belongs to the job, so no child escapes cancellation.
      agentProcess = startProcess("cmd /d /s /c \"set /p dargerAgentReady= >nul & " & redirected & "\"",
        options = {poEvalCommand, poUsePath, poDaemon})
      let handle = openProcess(PROCESS_SET_QUOTA or PROCESS_TERMINATE, 0, DWORD(agentProcess.processID))
      if handle == 0: raiseOSError(osLastError())
      let assigned = assignProcessToJobObject(agentJob, handle)
      let error = osLastError()
      discard closeHandle(handle)
      if assigned == 0: raiseOSError(error)
      agentProcess.inputStream.writeLine("ready")
      agentProcess.inputStream.flush()
    else:
      let redirected = command & " < " & quoteShell(agentDir / "prompt.txt") &
        " > " & quoteShell(agentDir / "out.txt") & " 2> " & quoteShell(agentDir / "err.txt")
      let setsid = findExe("setsid")
      agentGroup = setsid.len > 0
      let shell = if agentGroup: "exec " & quoteShell(setsid) & " /bin/sh -c " & quoteShell(redirected)
                  else: redirected
      # ponytail: without setsid (e.g. macOS), cancellation only stops the shell; install setsid for group cleanup.
      agentProcess = startProcess("/bin/sh", args = ["-c", shell], options = {poUsePath})
    agentCancelled = false
    agentBuf = b
    echo = "Agent running..."
  except CatchableError:
    if agentProcess != nil:
      agentProcess.kill()
      agentProcess.close()
      agentProcess = nil
    when defined(windows):
      if agentJob != 0:
        discard terminateJobObject(agentJob, 1)
        discard closeHandle(agentJob)
        agentJob = 0
    cleanAgentFiles()
    raise

proc cancelAgent() =
  if agentProcess == nil or agentCancelled: return
  when defined(windows):
    # Killing only cmd.exe leaves the CLI running; stop its job's descendants too.
    if terminateJobObject(agentJob, 1) == 0: raiseOSError(osLastError())
  else:
    if agentProcess.peekExitCode() == -1:
      let pid = Pid(agentProcess.processID)
      if posix.kill(if agentGroup: -pid else: pid, SIGTERM) != 0:
        let error = osLastError()
        if error != OSErrorCode(ESRCH): raiseOSError(error)
        # Cancellation may arrive before setsid has established the group.
        if agentGroup and posix.kill(pid, SIGTERM) != 0 and osLastError() != OSErrorCode(ESRCH):
          raiseOSError(osLastError())
  agentCancelled = true
  echo = "Agent cancelling..."

proc cleanAgentOutput(text: string): string =
  result = text.replace("\r\n", "\n")
  let tail = strutils.strip(result, leading = false)
  if tail.endsWith("```") and (tail.len == 3 or tail[^4] == '\n'):
    result = tail[0..<tail.len - 3]
    if result.startsWith("```"):
      let newline = result.find('\n')
      if newline >= 0: result = result[newline + 1..^1]

proc pollAgent(): bool =
  if agentProcess == nil: return false
  let code = agentProcess.peekExitCode()
  if code == -1: return false
  result = true
  agentProcess.close()
  agentProcess = nil
  when defined(windows):
    discard closeHandle(agentJob)
    agentJob = 0
  try:
    if agentCancelled: echo = "Agent cancelled"
    elif code != 0:
      let errors = readFile(agentDir / "err.txt").splitLines()
      echo = if errors.len > 0 and errors[0].len > 0: errors[0] else: "Agent exited with code " & $code
    else:
      let text = cleanAgentOutput(readFile(agentDir / "out.txt"))
      if validateUtf8(text) != -1: raise newException(ValueError, "Agent output is not valid UTF-8")
      if agentBuf notin reg: raise newException(ValueError, "Agent: its buffer was killed")
      abandonLine()
      switchTo(agentBuf)  # review the buffer the instruction was about
      beginReview(text)
  except CatchableError as e: echo = e.msg
  finally: cleanAgentFiles()

proc quitEditor() =
  abandonLine()
  if mode == "review": finishReview(true)
  closeOverlay()
  if anyModified(): beginMini("exit", "Modified buffers exist; exit anyway? (y or n) ")
  else: running = false

proc syncSearch() =
  let state = isearch.state
  mini = newBuffer(state.query)
  mini.cursor.col = mini.lines[0].len
  matchStart = if state.failing: -1 else: state.matchStart
  prompt = (if state.failing: "Failing " elif state.wrapped: "Wrapped " else: "") &
    (if state.direction > 0: "I-search: " else: "I-search backward: ")

proc search(next = false, direction = 0) =
  let query = if next and mini.text.len == 0: lastSearch else: mini.text
  b.searchStep(isearch, query, next, direction)
  syncSearch()

proc runCommand(name: string): Value =
  if name notin bufferCommands: raise newException(LispError, "Unknown buffer command: " & name)
  echo = b.command(name, if name == "yank" and b.kills.len == 0: getClipboardString() else: "")
  if b.last in ["kill", "copy"] and b.kills.len > 0: setClipboardString(b.kills[0])
  nilValue()

proc registerCommand(name: string) =
  interp.defPrimitive(name, proc(args: seq[Value]): Value =
    args.arity(0, 0)
    runCommand(name))

for name in bufferCommands: registerCommand(name)
interp.defPrimitive("global-set-key", proc(args: seq[Value]): Value =
  args.arity(2, 2)
  let key = args[0].asString
  if key.len == 0 or args[1].kind notin {vSymbol, vLambda, vPrimitive}:
    raise newException(LispError, "Expected key and symbol or function")
  keymap[key] = args[1]
  let tokens = strutils.splitWhitespace(key)
  if tokens.len > 1: prefixKeys.incl tokens[0]
  args[1])
interp.defPrimitive("insert", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  b.insert(args[0].asString)
  nilValue())
interp.defPrimitive("message", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  echo = args[0].asString
  args[0])
interp.defPrimitive("command", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  runCommand(args[0].asString))
interp.defPrimitive("agent", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  startAgent(args[0].asString)
  nilValue())
interp.defPrimitive("agent-prompt", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  beginMini("agent", "Agent: ")
  nilValue())
interp.defPrimitive("help", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if mode == "help": finishHelp()
  elif mode in ["", "eval", "execute"]: beginHelp()  # M-x help / M-: (help) reach here from their prompt
  else: echo = "help is unavailable here"
  nilValue())
proc wrote() =
  echo = "Wrote " & b.path
  detectLang()
  recordRecent(b.path)
  lspSync(true)
  let c = docClient(b)
  if c != nil and c.state == lsReady: c.didSave(reg.slot(b).docUri)

proc findPrompt() =
  beginMini("find", "Find file: ", (if b.path.len > 0: parentDir(b.path) else: getCurrentDir()) & DirSep)

proc switchPrompt() =
  let other = reg.other
  beginMini("switch", "Switch to buffer" &
    (if other != nil: " (default " & reg.displayName(other) & ")" else: "") & ": ")

proc killPrompt() =
  beginMini("kill", "Kill buffer (default " & reg.displayName(b) & "): ")

proc killQuestion(buf: Buffer): string =
  "Buffer " & reg.displayName(buf) & " modified; kill anyway? (y or n) "

proc otherVisitor(path: string): Buffer =
  ## The other buffer visiting path, which C-x C-w there replaces; a modified one refuses.
  result = reg.byPath(path)
  if result == b: return nil
  if result != nil and result.modified:
    raise newException(ValueError, "Buffer " & reg.displayName(result) & " visits that file and is modified")

proc writeTo(path: string) =
  let other = otherVisitor(path)
  b.save(path)
  if other != nil: killBuffer(other)
  wrote()

proc confirmMini() =
  let kind = mode
  let value = when defined(windows): mini.text
              else: (if kind in ["find", "write"]: expandTilde(mini.text) else: mini.text)
  if kind == "search" and value.len > 0: lastSearch = value
  case kind
  of "agent": startAgent(value)
  of "eval", "execute":
    try:
      if kind == "eval":
        let r = $interp.evalString(value, "<minibuffer>")
        if mode == kind: echo = r  # (help) / (agent-prompt) switched mode; keep their message
      else: discard interp.call(symbol(value), @[])
    except LispError as e:
      echo = if e.line == 0: "<minibuffer>:1: " & e.msg else: e.msg
  of "find":
    if value.len == 0: return
    visit(value)
  of "switch":
    let target = if value.len == 0: reg.other else: reg.byName(value)
    if target != nil: switchTo(target)
    elif value.len > 0:
      let fresh = newBuffer()
      reg.add(fresh, value)
      switchTo(fresh)
  of "kill":
    let target = if value.len == 0: b else: reg.byName(value)
    if target == nil: echo = "No such buffer: " & value
    elif target.modified:
      pendingKill = target
      beginMini("killy", killQuestion(target))
    else: killBuffer(target)
  of "killy":
    if value.toLowerAscii == "y": killBuffer(pendingKill)
    elif value.toLowerAscii != "n":
      echo = "Please answer y or n"
      return
    pendingKill = nil
  of "write":
    if value.len == 0: return
    discard otherVisitor(value)
    if fileExists(value) and absolutePath(value) != b.path:
      pendingPath = value
      beginMini("overwrite", "File exists; overwrite? (y or n) ")
      return
    writeTo(value)
  of "overwrite":
    if value.toLowerAscii == "y": writeTo(pendingPath)
    elif value.toLowerAscii != "n":
      echo = "Please answer y or n"
      return
  of "goto":
    let line = parseInt(value)
    if line < 1: raise newException(ValueError, "Line number must be positive")
    b.cursor = (min(line-1, b.lines.high), 0)
  of "line", "diag": discard  # the preview already moved there
  of "refs":
    if candIndex >= 0:
      pushXref(refOrigin, lineOrigin, lineTop, lineLeft)
      dropPreviews(b)
      if fileExists(b.path): recordRecent(b.path)
  of "exit":
    if value.toLowerAscii == "y": running = false
    elif value.toLowerAscii != "n":
      echo = "Please answer y or n"
      return
  else: discard
  if mode != kind: return  # the command opened help or another prompt
  mode = ""
  matchStart = -1
  b.finish()

proc editMini(c: string): bool =
  let cmd = case c
    of "backspace", "C-h": "backspace"
    of "tab", "C-i": "tab"
    of "C-a", "home": "bol"
    of "C-e", "end": "eol"
    of "C-f", "right": "forward"
    of "C-b", "left": "backward"
    of "C-k": "kill-line"
    of "C-y": "yank"
    else: ""
  if cmd.len == 0: return false
  if cmd == "tab" and mode in candModes:
    echo = "No match"  # TAB completes here; it never inserts a tab
    return true
  if cmd == "yank":
    let s = if b.kills.len > 0: b.kills[0] else: getClipboardString()
    mini.insert(s.replace("\r", "").replace("\n", " "))
  else:
    discard mini.command(cmd)
    if cmd == "kill-line" and mini.last == "kill":
      b.kills.insert(mini.kills[0], 0)
      b.yankIndex = 0
      if b.kills.len > 60: b.kills.setLen(60)
      setClipboardString(b.kills[0])
  if mode == "search": search() else: refreshCandidates()
  true

proc candidateValue(): string =
  ## The input the selected candidate stands for: file names keep the typed directory.
  if mode notin ["find", "write"]: return cands[candIndex]
  mini.text[0 ..< mini.text.len - splitInput(mini.text).tail.len] & cands[candIndex]

proc moveCandidate(delta: int, wrap: bool) =
  if cands.len == 0: return
  candIndex = if wrap: floorMod(candIndex + delta, cands.len) else: clamp(candIndex + delta, 0, cands.high)
  if mode in consults: preview()

proc candidateKey(c: string): bool =
  ## Vertico's keys in a prompt with a candidate list; false leaves c to editMini.
  result = true
  case c
  of "C-n", "down": moveCandidate(1, true)
  of "C-p", "up": moveCandidate(-1, true)
  of "C-v", "pagedown": moveCandidate(10, false)
  of "M-v", "pageup": moveCandidate(-10, false)
  of "tab", "C-i":
    if mode in consults: return  # nothing to complete; TAB does nothing
    if candIndex < 0: return false
    setMini(candidateValue())  # a directory is listed next, like vertico-insert
    refreshCandidates()
  of "enter", "C-m", "C-j":
    if candIndex >= 0 and mode notin consults:
      let value = candidateValue()
      setMini(value)
      if mode in ["find", "write"] and value.endsWith("/"):
        refreshCandidates()  # vertico-directory-enter: descend instead of opening
        return
    confirmMini()
  else: result = false

proc target(): Buffer = (if inMini(): mini else: b)

proc skkOn(): bool =
  # ponytail: one SKK state serves the buffer and the text minibuffers; y/n and goto prompts bypass it.
  inputMethod.enabled and (mode == "" or mode in textPrompts) and
    window.imeCompositionString.len == 0

proc following(): Rune =
  ## The character after the cursor, so SKK's ")" can step over a "）".
  let t = target()
  if t.cursor.col < t.lines[t.cursor.line].len: t.lines[t.cursor.line][t.cursor.col] else: Rune(0)

proc applySkk(res: SkkResult, t = target()): bool =
  ## Inserts the engine's text like typed input; true when SKK consumed the key.
  t.insert(res.text, true)
  if res.move != 0: t.cursor = t.point(t.offset(t.cursor) + res.move)
  if mode == "search" and res.text.len > 0: search()
  elif inMini(): refreshCandidates()
  if res.consumed: echo = res.echo
  recenterCycle = 0
  res.consumed

proc toggleSkk(t = target()) =
  let message = if inputMethod.loaded: "" else: inputMethod.loadDefaults()
  discard applySkk(inputMethod.toggle(), t)
  if message.len > 0: echo = message

proc page(buf: Buffer, full: string) =
  let direction = if full in ["C-v", "pagedown"]: 1 else: -1
  if direction > 0 and renderer.top + renderer.rows > buf.lines.high:
    echo = "End of buffer"
    return
  if direction < 0 and renderer.top == 0:
    echo = "Beginning of buffer"
    return
  let delta = direction * max(1, renderer.rows-2)
  buf.vertical(delta)
  renderer.top = clamp(renderer.top + delta, 0, max(0, buf.lines.len-renderer.rows))

proc recenter(buf: Buffer) =
  let row = case recenterCycle
    of 0: renderer.rows div 2
    of 1: 0
    else: renderer.rows - 1
  renderer.top = max(0, buf.cursor.line - row)
  recenterCycle = (recenterCycle + 1) mod 3


# --- LSP commands: completion, hover, navigation, format

proc identRune(r: Rune): bool = r.isAlpha or r == Rune('_') or int(r) in ord('0')..ord('9')

proc identStart(): int =
  ## The offset where the identifier ending at the cursor starts.
  let line = b.lines[b.cursor.line]
  var col = b.cursor.col
  while col > 0 and identRune(line[col - 1]): dec col
  b.offset((b.cursor.line, col))

proc lspTarget(): Client =
  ## b's server, ready and sent b's latest text; nil with the reason echoed.
  lspSync(true)
  let c = docClient(b)
  if c != nil and c.state == lsReady: return c
  let s = clients.getOrDefault(lang.name)
  echo = if s != nil and s.state == lsStarting: "LSP: " & lang.name & " server is starting"
         else: "No language server for " & (if b.path.len > 0: lang.name else: "this buffer")

proc position(at: Point): JsonNode =
  %*{"textDocument": {"uri": reg.slot(b).docUri},
    "position": {"line": at.line, "character": utf16Col(b.lines[at.line], at.col)}}

proc lspCall(c: Client, meth: string, params: JsonNode, onResult: proc(res: JsonNode)) =
  ## Sends a request without waiting; its answer runs onResult later, an error is echoed.
  c.request(meth, params, proc(res, error: JsonNode) =
    try:
      if error != nil and error.kind != JNull: echo = "LSP: " & error{"message"}.getStr
      else: onResult(res)
    except CatchableError as e: echo = e.msg)

proc closeComp() =
  compActive = false
  compPending = false
  compItems = @[]
  compShown = @[]
  compIncomplete = false
  autoAt = 0
  inc compSerial

proc composing(): bool =
  ## An OS IME or SKK composition is under way; completion stays out of its way.
  window.imeCompositionString.len > 0 or inputMethod.preedit().len > 0

proc refilter(): bool =
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

proc requestCompletion(manual: bool, trigger = "", refresh = false) =
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
      if manual: echo = "LSP: " & error{"message"}.getStr
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
      elif manual: echo = "No completions"
    except CatchableError as e: echo = e.msg)

proc acceptComp() =
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

proc autoComplete(): bool =
  let v = interp.env.values.getOrDefault("lsp-auto-complete")
  v != nil and v.kind != vNil

proc scheduleAuto() =
  autoAt = epochTime()
  autoBuf = b
  autoVersion = b.version

proc afterInsert(r: Rune) =
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

proc autoTick() =
  ## Completion once the buffer has been idle 300 ms after typing an identifier: a new
  ## one (auto completion), or a narrower one for an open incomplete list.
  if autoAt == 0 or epochTime() - autoAt < 0.3: return
  autoAt = 0
  if mode.len > 0 or b != autoBuf or b.version != autoVersion or compPending or composing(): return
  if compActive: requestCompletion(false, refresh = true)
  elif b.offset(b.cursor) - identStart() >= 2: requestCompletion(false)

proc wrapCells(s: string, width: int): seq[string] =
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

proc popupKey(c: string): bool =
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

proc cursorPopup(): CursorBox =
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

proc lspHover() =
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
      echo = "No hover"
      return
    hoverTop = 0
    hoverActive = true
    hoverBuf = b

proc gotoLocation(meth, what: string) =
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
      echo = "No " & what
      return
    if reg.byPath(locs[0].path) != b: visit(locs[0].path)
    let line = clamp(locs[0].line, 0, b.lines.high)
    b.cursor = (line, lsp.runeCol(b.lines[line], locs[0].col))
    b.finish()
    pushXref(buf, at, top, left)
    recenterCycle = 0
    recenter(b)
    renderer.left = 0

proc xrefBack() =
  while xrefStack.len > 0:
    let (buf, at, top, left) = xrefStack.pop()
    if buf notin reg: continue  # killed since
    switchTo(buf)
    let line = clamp(at.line, 0, b.lines.high)
    b.cursor = (line, min(at.col, b.lines[line].len))
    renderer.top = top
    renderer.left = left
    return
  echo = "At start of xref history"

proc lspReferences() =
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
      echo = "No references"
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

proc lspFormat() =
  let c = lspTarget()
  if c == nil: return
  let buf = b
  let version = b.version
  c.lspCall("textDocument/formatting", %*{"textDocument": {"uri": reg.slot(b).docUri},
      "options": {"tabSize": 4, "insertSpaces": true}}) do (res: JsonNode):
    if buf notin reg or buf.version != version:
      echo = "Buffer changed; not formatted"
      return
    if applyEdits(buf, parseEdits(res)): buf.finish()
    echo = "Formatted"


const
  zoomCommands = ["zoom-in", "zoom-out", "zoom-reset"]
  builtinChords = ["C-x C-s", "C-x C-f", "C-x C-w", "C-x C-c", "M-g g", "M-g M-g"]

proc symName(fn: Value): string = (if fn != nil and fn.kind == vSymbol: fn.str else: "")

proc sticky(full: string): string =
  ## The hydra prefix full belongs to, or "".
  for key in hydras.keys:
    if full.startsWith(key & " "): return key

proc rearm(full: string) =
  let key = sticky(full)
  if key.len == 0: return
  prefix = key
  echo = hydras[key] & (if echo.len > 0: "  " & echo else: "")

proc leavesHydra(full: string): bool =
  ## An unbound key after a hydra prefix leaves it; built-in chords stay chords.
  full notin keymap and full notin builtinChords and sticky(full).len > 0

proc overlayKey(c: string): string =
  ## Prefix, hydra and zoom keys shared by the overlays; "" when c was consumed.
  if c == "C-g" and prefix.len > 0:
    prefix = ""  # quit the prefix or hydra, keep the overlay
    return
  result = if prefix.len > 0: prefix & " " & c else: c
  prefix = ""
  if leavesHydra(result): result = c  # the key's rune stays suppressed
  if result in prefixKeys:
    prefix = result
    echo = hydras.getOrDefault(result, result & "-")
    return ""
  let fn = keymap.getOrDefault(result)
  if fn.symName in zoomCommands:
    discard interp.call(fn, @[])
    rearm(result)
    return ""

proc dispatchHelp(c: string) =
  ## Help mode only moves helpBuf; the edited buffer b is never touched.
  let full = overlayKey(c)
  if full.len == 0: return
  if full in ["q", "C-g", "enter", "C-m", "C-j", "f1", "escape"]:
    finishHelp()
    return
  if full == "C-x C-c":
    quitEditor()
    return
  if full != "C-l": recenterCycle = 0
  let name = keymap.getOrDefault(full).symName
  if name == "help":
    finishHelp()
  elif name in helpNavigation:
    let message = helpBuf.command(name)
    if message.len > 0: echo = message
  elif full in ["C-v", "pagedown", "M-v", "pageup"]: page(helpBuf, full)
  elif full == "C-l": recenter(helpBuf)
  else: echo = "q: close help"

proc openEntry(i: int) =
  if i notin 0..dashFiles.high: return
  let path = dashFiles[i]
  if not fileExists(path):
    echo = "No such file: " & shortPath(path)
    return
  finishDash()
  try: visit(path)
  except CatchableError as e:
    beginDash()
    echo = e.msg

proc dispatchDash(c: string) =
  ## Like dispatchHelp: the dashboard only moves between entries or opens one.
  let full = overlayKey(c)
  if full.len == 0: return
  let name = keymap.getOrDefault(full).symName
  if full in ["q", "C-g", "escape"] or name == "dashboard": finishDash()
  elif full == "f1" or name == "help":
    finishDash()
    beginHelp()
  elif full == "C-x C-c": quitEditor()
  elif full == "C-x C-f":
    finishDash()
    findPrompt()
  elif full in ["enter", "C-m", "C-j"]: openEntry(dashBuf.cursor.line - dashFirst)
  elif name in ["next-line", "previous-line"] or full in ["C-n", "C-p", "down", "up"]:
    let delta = if name == "previous-line" or full in ["C-p", "up"]: -1 else: 1
    if dashFiles.len > 0:
      dashBuf.cursor = (clamp(dashBuf.cursor.line + delta, dashFirst, dashFirst + dashFiles.high), 2)
  elif full.len == 1 and dashLabels.find(full[0]) in 0..dashFiles.high:
    openEntry(dashLabels.find(full[0]))
  else: echo = full & " is undefined"

proc blistKill(buf: Buffer) =
  let row = blistBuf.cursor.line
  killBuffer(buf)
  buildBlist(row)
  echo = "Killed buffer"

proc dispatchBlist(c: string) =
  ## Like dispatchDash: the list moves between buffers, switches to one or kills one.
  if pendingKill != nil:
    let buf = pendingKill
    if c notin ["y", "n", "C-g"]:
      echo = "Please answer y or n"
      return
    pendingKill = nil
    if c == "y": blistKill(buf)
    return
  let full = overlayKey(c)
  if full.len == 0: return
  let name = keymap.getOrDefault(full).symName
  let row = blistBuf.cursor.line
  let buf = if row - 1 in 0..blistBufs.high: blistBufs[row - 1] else: nil
  if full in ["q", "C-g", "escape"] or name == "list-buffers": finishBlist()
  elif full == "f1" or name == "help":
    finishBlist()
    beginHelp()
  elif full == "C-x C-c": quitEditor()
  elif full in ["enter", "C-m", "C-j"] and buf != nil:
    finishBlist()
    switchTo(buf)
  elif full == "k" and buf != nil:
    if buf.modified: pendingKill = buf
    else: blistKill(buf)
  elif name in ["next-line", "previous-line"] or full in ["C-n", "C-p", "down", "up", "n", "p"]:
    let delta = if name == "previous-line" or full in ["C-p", "up", "p"]: -1 else: 1
    blistBuf.cursor = (clamp(row + delta, 1, max(1, blistBufs.len)), 0)
  else: echo = full & " is undefined"

proc dispatch(c: string) =
  if mode == "blist":
    dispatchBlist(c)
    return
  if mode == "help":
    dispatchHelp(c)  # C-g only closes the manual; a running agent keeps running
    return
  if mode == "dash":
    dispatchDash(c)
    return
  if c == "C-g":
    if agentProcess != nil: cancelAgent()
    if mode == "review":
      finishReview(true)
      return
    if mode == "search": b.cursor = isearch.origin
    if mode in consults: restoreOrigin()
    mode = ""
    pendingKill = nil
    prefix = ""
    matchStart = -1
    echo = if agentCancelled and agentProcess != nil: "Agent cancelling..." else: ""
    discard b.command("quit")
    return
  if mode == "review":
    case c
    of "n": currentHunk = min(currentHunk + 1, reviewState.hunks.high)
    of "p": currentHunk = max(currentHunk - 1, 0)
    of "y", "k":
      reviewState.decisions[currentHunk] = if c == "y": accepted else: rejected
      currentHunk = min(currentHunk + 1, reviewState.hunks.high)
    of "a":
      for decision in reviewState.decisions.mitems:
        if decision == pending: decision = accepted
      finishReview()
      return
    of "enter", "C-m", "C-j", "q":
      finishReview()
      return
    else:
      echo = c & " is undefined"
      return
    rebuildReview()
    return
  if mode in textPrompts:
    # Text prompts take keys bound to skk-mode (C-\, C-x C-j); C-j alone still confirms.
    if prefix.len == 0 and keymap.getOrDefault(c).symName == "skk-mode":
      toggleSkk()
      return
    if prefix.len == 0 and c == "C-x":
      prefix = c
      echo = "C-x-"
      return
    if prefix == "C-x":
      prefix = ""
      if keymap.getOrDefault("C-x " & c).symName == "skk-mode":
        toggleSkk()
        return
      if mode != "search":
        echo = "C-x " & c & " is undefined"
        return
      confirmMini()  # any other C-x chord ends the search at the match and runs as usual
      prefix = "C-x"
  if mode == "search":
    if c in ["C-s", "C-r"]:
      search(true, if c == "C-s": 1 else: -1)
      return
    if c in ["backspace", "C-h"]:
      b.searchBackspace(isearch)
      syncSearch()
      return
    if c == "C-y":
      discard editMini(c)
      return
    confirmMini()
    if c in ["enter", "C-m", "C-j"]: return
  if inMini():
    if mode in candModes and candidateKey(c): return
    if c in ["enter", "C-m", "C-j", "M-enter"]: confirmMini()  # M-enter: the input as typed
    elif not editMini(c): echo = c & " is undefined"
    return
  let full = if prefix.len > 0: prefix & " " & c else: c
  prefix = ""
  if leavesHydra(full):
    # Like hydra: an unbound key leaves it and runs as usual; text comes back via onRune.
    if suppressRune: suppressRune = false
    else: dispatch(c)
    return
  if full in prefixKeys:
    prefix = full
    echo = hydras.getOrDefault(full, full & "-")
    b.finish()
    return
  if full != "C-l": recenterCycle = 0
  if full in keymap:
    let fn = keymap[full]
    if fn.kind == vSymbol and fn.str in bufferCommands:
      discard runCommand(fn.str)
    else:
      discard interp.call(fn, @[])
    if mode == "": rearm(full)
    return
  b.finish()
  case full
  of "M-:": beginMini("eval", "Eval: ")
  of "M-x": beginMini("execute", "M-x ")
  of "C-v", "pagedown", "M-v", "pageup": page(b, full)
  of "C-l": recenter(b)
  of "M-g g", "M-g M-g": beginMini("goto", "Goto line: ")
  of "C-x C-s":
    if b.path.len == 0: beginMini("write", "Write file: ", getCurrentDir() & DirSep)
    else:
      b.save()
      wrote()
  of "C-x C-f": findPrompt()
  of "C-x C-w": beginMini("write", "Write file: ", b.path)
  of "C-x C-c": quitEditor()
  of "C-s", "C-r":
    isearch = b.startSearch(if full == "C-s": 1 else: -1)
    matchStart = -1
    beginMini("search", if isearch.state.direction > 0: "I-search: " else: "I-search backward: ")
  else: echo = full & " is undefined"

proc zoom(factor: float32) =
  renderer.zoom = if factor == 0: 1'f32 else: clamp(renderer.zoom * factor, 0.5'f32, 4'f32)
  echo = "Zoom " & $int(round(renderer.zoom * 100)) & "%"

for (name, factor) in [("zoom-in", 1.1'f32), ("zoom-out", 1 / 1.1'f32), ("zoom-reset", 0'f32)]:
  closureScope:
    let f = factor
    interp.defPrimitive(name, proc(args: seq[Value]): Value =
      args.arity(0, 0)
      zoom(f)
      nilValue())
interp.defPrimitive("dashboard", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if mode == "dash": finishDash()
  elif mode in ["", "eval", "execute"]: beginDash()
  else: echo = "dashboard is unavailable here"
  nilValue())
interp.defPrimitive("skk-mode", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  # From M-x / M-: the committed reading belongs to the buffer, not the discarded prompt.
  toggleSkk(if mode in ["eval", "execute"]: b else: target())
  nilValue())
interp.defPrimitive("find-file", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  let path = expandTilde(args[0].asString)
  if path.len == 0: raise newException(LispError, "Expected a file name")
  try: visit(path)
  except IOError, ValueError: raise newException(LispError, getCurrentExceptionMsg())
  nilValue())
interp.defPrimitive("switch-to-buffer", proc(args: seq[Value]): Value =
  args.arity(0, 1)
  if args.len == 0:
    switchPrompt()
    return nilValue()
  let name = args[0].asString
  var buf = reg.byName(name)
  if buf == nil:
    buf = newBuffer()
    reg.add(buf, name)
  switchTo(buf)
  nilValue())
interp.defPrimitive("kill-buffer", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  killPrompt()
  nilValue())
interp.defPrimitive("list-buffers", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if mode == "blist": finishBlist()
  elif mode in ["", "eval", "execute"]: beginBlist()
  else: echo = "list-buffers is unavailable here"
  nilValue())
for (name, delta) in [("next-buffer", 1), ("previous-buffer", -1)]:
  closureScope:
    let d = delta
    interp.defPrimitive(name, proc(args: seq[Value]): Value =
      args.arity(0, 0)
      switchTo(reg.cycle(b, d))
      nilValue())
interp.defPrimitive("consult-line", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  beginMini("line", "Go to line: ")
  nilValue())
interp.defPrimitive("consult-flymake", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  lspSync(true)
  if diagnostics().len == 0: echo = "No diagnostics"
  else: beginMini("diag", "Diagnostic: ")
  nilValue())
for (name, run) in [("completion-at-point", proc() = requestCompletion(true)),
    ("lsp-hover", lspHover),
    ("lsp-definition", proc() = gotoLocation("textDocument/definition", "definition")),
    ("lsp-type-definition", proc() = gotoLocation("textDocument/typeDefinition", "type definition")),
    ("lsp-implementation", proc() = gotoLocation("textDocument/implementation", "implementation")),
    ("lsp-back", xrefBack), ("lsp-references", lspReferences), ("lsp-format-buffer", lspFormat)]:
  closureScope:
    let f = run
    interp.defPrimitive(name, proc(args: seq[Value]): Value =
      args.arity(0, 0)
      f()
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
    echo = "No language server for " & name
    return nilValue()
  shutdown(clients.getOrDefault(name))
  clients.del name
  lspReported.excl name
  for s in reg.slots.mitems:
    if s.docLang == name: s.docUri = ""
  echo = ""
  lspSync(true)
  let c = clients.getOrDefault(name)
  if echo.len == 0 and c != nil: echo = "Restarted " & c.command
  nilValue())
interp.defPrimitive("lsp-log", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let c = clients.getOrDefault(lang.name)
  echo = if c != nil: c.logPath else: "No language server for " & lang.name
  nilValue())
interp.defPrimitive("load-theme", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  let name = args[0].asString
  if not setTheme(name): raise newException(LispError, "No such theme: " & name)
  args[0])
interp.defPrimitive("hydra", proc(args: seq[Value]): Value =
  args.arity(2, 2)
  let key = args[0].asString
  if key.len == 0 or ' ' in key: raise newException(LispError, "Expected a single-key prefix")
  hydras[key] = args[1].asString
  prefixKeys.incl key
  args[0])
discard interp.evalString(defaultBindings, "<default-bindings>")
let initPath = getHomeDir() / ".darger.el"
if fileExists(initPath):
  try: discard interp.evalFile(initPath)
  except CatchableError as e: echo = e.msg

var dirty = true  # set by every input callback; the loop only redraws when it is set

var
  grab = ivec2(-1, -1)  # where in the window the left button went down; x < 0: nothing to drag
  grabSize: IVec2       # the window size then
  grabCorner: bool      # it went down in the bottom right corner: the drag resizes

window.onMouseMove = proc() =
  # No title bar or frame, so dragging moves the window and its corner resizes it.
  # ponytail: the mouse does nothing else, so the whole window is the handle; keep
  # only the border once clicks place the cursor
  if grab.x < 0 or not window.buttonDown[MouseLeft] or window.maximized: return
  let delta = window.mousePos - grab
  if grabCorner:
    window.size = ivec2(max(200'i32, grabSize.x + delta.x), max(120'i32, grabSize.y + delta.y))
  else: window.pos = window.pos + delta

window.onButtonPress = proc(key: Button) =
  dirty = true
  if key == MouseLeft:
    grab = window.mousePos
    grabSize = window.size
    grabCorner = grab.x > grabSize.x - 32 and grab.y > grabSize.y - 32
  elif key == DoubleClick:
    window.maximized = not window.maximized
    grab.x = -1  # the window jumped under the mouse; this click must not drag it
  if key in {KeyLeftControl, KeyRightControl, KeyLeftAlt, KeyRightAlt,
             KeyLeftShift, KeyRightShift, KeyLeftSuper, KeyRightSuper,
             KeyCapsLock, KeyNumLock, KeyScrollLock, KeyPause, KeyMenu, KeyPrintScreen,
             KeyInsert} or key < Key0: return
  # Escape only closes an overlay or a popup
  if key == KeyEscape and mode notin ["help", "dash", "blist"] and not compActive and not hoverActive: return
  if window.imeCompositionString.len > 0:
    if key == KeyG and ctrl():
      window.closeIme()
      dispatch("C-g")
    return
  echo = ""
  let printable = key in {Key0..KeyZ, KeyBacktick, KeyMinus, KeyEqual,
    KeyLeftBracket, KeyRightBracket, KeyBackslash, KeySemicolon,
    KeyApostrophe, KeyComma, KeyPeriod, KeySlash, KeySpace, NumpadAdd..NumpadEqual} or
    (key in {Numpad0..Numpad9, NumpadDecimal} and not keypadNavigation())
  suppressRune = prefix.len > 0 and printable and not ctrl() and not alt()
  if not ctrl() and not alt() and prefix.len == 0 and printable: return
  try:
    let c = chord(key)
    if c.len == 0 or c == "insert": return
    if c == "C-g" and agentProcess != nil:
      discard popupKey(c)
      dispatch(c)
      return
    if popupKey(c): return
    if prefix.len == 0 and c in ["enter", "backspace", "tab", "C-j", "C-g"] and skkOn():
      let key = case c
        of "enter": skEnter
        of "backspace": skBackspace
        of "tab": skTab
        of "C-j": skCtrlJ
        else: skCtrlG
      if applySkk(inputMethod.feed(key)): return
    dispatch(c)
  except CatchableError as e: echo = e.msg

window.onRune = proc(rune: Rune) =
  dirty = true
  if ctrl() or alt() or int(rune) < 32 or int(rune) == 127: return
  if suppressRune:
    suppressRune = false
    return
  # Windy's Windows WM_CHAR callback exposes UTF-16 surrogate code units.
  var scalar = int(rune)
  if scalar in 0xD800..0xDBFF:
    highSurrogate = scalar
    return
  if scalar in 0xDC00..0xDFFF:
    if highSurrogate == 0: return
    scalar = 0x10000 + (highSurrogate - 0xD800) * 1024 + scalar - 0xDC00
  highSurrogate = 0
  if scalar > 0x10FFFF: return
  echo = ""
  try:
    if mode in overlays:
      dispatch($Rune(scalar))
      return
    if prefix.len > 0:
      dispatch($Rune(scalar))
      return
    hoverActive = false
    if skkOn():
      closeComp()  # ponytail: SKK input never drives the completion popup
      if applySkk(if scalar == 32: inputMethod.feed(skSpace)
                  else: inputMethod.feed(Rune(scalar), following())): return
    if inMini():
      mini.insert($Rune(scalar), true)
      if mode == "search": search() else: refreshCandidates()
    else:
      recenterCycle = 0
      b.insert($Rune(scalar), true)
      afterInsert(Rune(scalar))
  except CatchableError as e: echo = e.msg

window.onImeChange = proc() =
  dirty = true
  if mode in overlays:
    if window.imeCompositionString.len > 0: window.closeIme()
    return
  if window.imeCompositionString.len > 0:
    prefix = ""
    suppressRune = false
    highSurrogate = 0
    b.finish()
    closeComp()  # its keys go to the IME, so the popups could not be closed
    hoverActive = false

window.onCloseRequest = proc() = quitEditor()

proc overlayMessage(base: string): string =
  ## A hydra hint replaces the overlay's own hint so the echo line does not overflow.
  if prefix in hydras: echo
  elif echo.len > 0 and echo != base: base & "  " & echo
  else: base

proc redraw() =
  if not running or window.closed or window.minimized or window.size.x == 0 or window.size.y == 0: return
  let displayed = if mode == "review": reviewBuf elif mode == "help": helpBuf
    elif mode == "dash": dashBuf elif mode == "blist": blistBuf else: b
  renderer.resize(window, displayed)
  let skkShown = skkOn()
  # The candidate page lives in echo; a command that cleared echo brings it back.
  let message = if agentProcess != nil:
      (if agentCancelled: "Agent cancelling..." else: "Agent running...")
    elif mode == "review": reviewMessage() & (if echo != reviewMessage(): "  " & echo else: "")
    elif mode == "help": overlayMessage(helpMessage)
    elif mode == "dash": overlayMessage(dashMessage)
    elif mode == "blist":
      if pendingKill != nil: killQuestion(pendingKill) else: overlayMessage(blistMessage)
    elif echo.len == 0 and skkShown: inputMethod.page() else: echo
  # Prompts float in a popup; isearch stays on the bottom line so its match is visible.
  let popup = inMini() and mode != "search"
  if shownBuf != b or shownVersion != b.version:
    faces = lang.highlight(b.lines)
    shownBuf = b
    shownVersion = b.version
  # Overlays (help, dashboard, review) are drawn plain.
  let shown = if displayed == b: faces.len else: 0
  let listed = inMini() and mode in candModes
  updateMarks()
  let box = cursorPopup()
  # isearch marks its match; consult-line marks the previewed line.
  let highlight = if mode == "search": (start: matchStart, len: mini.text.runeLen)
    elif mode in consults and candIndex >= 0:
      (start: b.offset((b.cursor.line, 0)), len: max(1, b.lines[b.cursor.line].len))
    else: (start: -1, len: 0)
  renderer.draw(window, displayed, message, mini.text,
    if inMini(): mini.cursor.col else: -1,
    highlight.start, highlight.len,
    if skkShown: inputMethod.preedit() else: "",
    if mode == "review": "[Review]" elif mode == "help": "[Help]" elif mode == "dash": "[Dash]"
    elif mode == "blist": "[Buffers]" else: inputMethod.tag(), reviewColors,
    prompt, popup, faces.toOpenArray(0, shown - 1),
    if displayed == b: lang.name & diagCounts() else: "Text",
    if displayed == b or mode == "review": reg.displayName(b) else: displayed.path,
    cands.toOpenArray(0, if listed: cands.high else: -1), candIndex, listed,
    if mode in consults: atBottom else: atTop, marks.toOpenArray(0, if displayed == b: marks.high else: -1),
    if displayed == b: box else: CursorBox(), lineNumbers = displayed == b)

window.onResize = redraw
if paramCount() == 0: beginDash()  # first screen: recent files over an empty *scratch*
var lastDraw = 0.0
while running and not window.closed:
  pollEvents()
  try:
    if pollAgent(): dirty = true
  except CatchableError as e:
    echo = e.msg
  try:
    lspSync()
    if lspPoll(): dirty = true
    if restEcho(): dirty = true
    autoTick()
  except CatchableError as e:
    echo = e.msg
    dirty = true
  # ponytail: redraw after input or every 250 ms; an unconditional per-frame redraw kept ~2 cores busy while idle
  if dirty or epochTime() - lastDraw > 0.25:
    redraw()
    dirty = false
    lastDraw = epochTime()
  else:
    sleep(8)
window.close()
if agentProcess != nil:
  cancelAgent()
  when not defined(windows):
    # A CLI that ignores TERM would block waitForExit forever; hard-kill like TerminateJobObject.
    let deadline = epochTime() + 1.5  # total exit (grace + SIGKILL + reap) stays under 2 s
    while agentProcess.peekExitCode() == -1 and epochTime() < deadline: sleep(20)
    let pid = Pid(agentProcess.processID)
    if agentGroup: discard posix.kill(-pid, SIGKILL)  # the sh leader may be gone while the CLI ignored TERM; ESRCH is fine
    elif agentProcess.peekExitCode() == -1: discard posix.kill(pid, SIGKILL)
  discard agentProcess.waitForExit()
  agentProcess.close()
  when defined(windows): discard closeHandle(agentJob)
  cleanAgentFiles()
var servers: seq[Client]
for c in clients.values: servers.add c
shutdown(servers)
