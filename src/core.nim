## The editor: its state, buffers, prompts, overlays, key dispatch and drawing. The
## window and main loop are in darger.nim; features build on this module.
import std/[os, osproc, tempfiles, strutils, times, unicode, tables, sets, math, json, uri, browsers, hashes]
import windy, vmath
when defined(macosx): import macwin
import buffer, buffers, render, skk, lisp, recent, syntax, complete, lsp, panes
export panes

const
  bufferCommands* = ["forward", "backward", "next-line", "previous-line", "bol", "eol",
    "bob", "eob", "indent", "forward-word", "backward-word", "newline", "tab", "open-line",
    "delete", "backspace", "kill-line", "kill-word", "backward-kill-word", "mark", "exchange",
    "whole", "kill-region", "copy-region", "yank", "yank-pop", "undo", "transpose",
    "upcase", "downcase", "capitalize", "quit"]
  defaultBindings* = """
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
(global-set-key "C-x C-j" 'skk-mode)
(global-set-key "C-backslash" 'skk-mode)
(global-set-key "C-c ," (lambda () (find-file "~/.darger.el")))
(global-set-key "C-x b" 'switch-to-buffer)
(global-set-key "C-x k" 'kill-buffer)
(setq skk-egg-like-newline t)
(global-set-key "C-x 2" 'split-window-below)
(global-set-key "C-x 3" 'split-window-right)
(global-set-key "C-x 0" 'delete-window)
(global-set-key "C-x 1" 'delete-other-windows)
(global-set-key "C-x o" 'other-window)
(global-set-key "C-x right" 'next-buffer)
(global-set-key "C-x left" 'previous-buffer)
(global-set-key "M-g l" 'consult-line)
(global-set-key "M-," 'lsp-back)
(global-set-key "f2 g" 'zoom-in)
(global-set-key "f2 l" 'zoom-out)
(global-set-key "f2 0" 'zoom-reset)
(hydra "f2" "zoom  g:in  l:out  0:reset")
"""

var argCommands* = @["global-set-key", "insert", "command", "find-file", "load-theme",
  "hydra", "set-font", "set-fallback-fonts"]  # primitives M-x cannot call without arguments

when defined(windows):
  import std/[winlean, streams]
  proc getKeyState(key: int32): int16 {.stdcall, importc: "GetKeyState", dynlib: "user32".}
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




var b* = newBuffer()  # the current buffer; reg holds every open one
var reg*: Registry
reg.add b
reg.touch b
var
  lang* = detect("", "")  # b's language, re-detected whenever b or b.path changes
  shownBuf*: Buffer       # the buffer and version that faces were computed for
  shownVersion*: int
  faces*: seq[seq[Face]]

proc hash*(buf: Buffer): Hash = hash(cast[int](buf))  # buffers as table keys, by identity

# ---- Windows (panes): the frame split below / right, as C-x 2 / C-x 3 in Emacs
var
  layout* = newLayout(Pane(buf: b))  # the tree of panes
  pane* = layout.leaves[0]           # the selected one: it shows b at renderer.top / left
  bars: seq[Bar]                     # separator columns from the last layout
  paneFaces: Table[Buffer, tuple[version: int, faces: seq[seq[Face]]]]  # other panes' highlighting


var langHints*: seq[proc(buf: Buffer): string]  # a path to detect a buffer's language by; "" = its own

proc detectLang*() =
  var path = b.path
  for hint in langHints:  # an extension's buffers may read as a language of its choosing
    let p = hint(b)
    if p.len > 0: path = p
  lang = detect(path, if b.lines.len > 0: $b.lines[0] else: "")
  shownBuf = nil

var
  window* = newWindow("darger", ivec2(1000, 720), style = Undecorated, vsync = true)
window.makeContextCurrent()
window.runeInputEnabled = true
var renderer*: Renderer

proc layoutPanes*() =
  ## Gives every pane its cells in the frame; the editor's rows and columns are the selected pane's.
  bars = @[]
  layout.place(0, 0, renderer.frameCols, renderer.frameRows, bars)
  renderer.setPane(pane.x, pane.y, pane.w, pane.h)
try: renderer = newRenderer()
except CatchableError as e:
  stderr.writeLine(e.msg)
  window.close()
  quit(1)
let inputMethod* = newSkk()
var
  echoLine*, prefix*, mode*, prompt*: string
  mini* = newBuffer()
  running* = true
  suppressRune* = false
  recenterCycle* = 0
  isearch*: ISearch
  lastSearch*: string
  matchStart* = -1
  pendingPath*: string
  highSurrogate* = 0
  interp* = newInterp()
  keymap*: Table[string, Value]
  prefixKeys* = toHashSet(["C-x", "M-g"])
  hydras*: Table[string, string]  # sticky prefix -> hint
  overlayTop*, overlayLeft*: int
  startScreen*: proc()  # shown at start without files (the dashboard); nil = *scratch*
  pendingKill*: Buffer  # awaiting y/n: the "killy" prompt or k in the buffer list
  candAll*, cands*: seq[string]  # the prompt's candidates, and those matching mini.text
  candIndex* = -1               # the selected one in cands, -1 = none
  candText*: string             # the mini.text cands were computed for
  candDir*: string              # file prompts: the listed directory (and whether dot-files are in)
  candSkip*: int                # consult-line: bytes of the "  12  " line-number column
  lineOrigin*: Point            # consult-line: where C-g returns to
  lineTop*, lineLeft*: int
var
  xrefStack*: seq[(Buffer, Point, int, int)]  # M-. origins: buffer, cursor, top, left
  targets*: seq[Location]          # consult prompts: each candAll row's position, rune
                                  # columns; path "" = the origin buffer
  refRows*: seq[string]            # M-? rows, whose targets lspReferences sets
  refOrigin*: Buffer
  previewed*: seq[Buffer]          # buffers opened only to preview a reference
  candIdx*: seq[int]               # consult prompts: the candAll index of each of cands

# ---- The extension API: views, prompts and hooks that features plug into
type
  Mode* = ref object
    ## An overlay: a view (the manual, a directory, a web page, a review) shown in place
    ## of the edited buffer, taking every key. Prompts can float over it (Prompt.over).
    name*: string
    tag*, modeName*: string          # the mode line's "[Dired]" and "(Dired)"; "" = as usual
    editing*: bool                   # it edits b: the mode line shows b's name
    buffer*: proc(): Buffer          # what it shows
    faces*: proc(): seq[seq[Face]]   # its colours; nil = plain
    colors*: proc(): seq[int8]       # line backgrounds (review); nil = none
    message*: proc(): string         # the echo line while it takes keys; nil = the echo line
    onKey*: proc(c: string)
    onClose*: proc()                 # closeOverlay(): a review or quitting replaces it
    beforeDraw*: proc()              # lays the view out again for the window's width
  Prompt* = ref object
    ## A minibuffer prompt: what Enter does with the input and how candidates behave.
    kind*: string
    candidates*: proc(): seq[string] # the list when the prompt opens; nil = no list
    consult*: bool                   # candidates stand for positions in `targets`, previewed
    paths*: bool                     # file name completion in the typed directory
    descend*: bool                   # Enter on a directory lists it instead of accepting it
    rawEnter*: proc(): bool          # Enter takes the typed text rather than the candidate
    text*: bool                      # SKK applies (not for y/n and numbers)
    over*: string                    # the overlay it floats over and returns to
    onAccept*: proc(value: string): bool  # false keeps the prompt open
    onCancel*: proc()
var
  modes*: Table[string, Mode]
  prompts*: Table[string, Prompt]
  tickHooks*: seq[proc(): bool]      # run every loop; true asks for a redraw
  messageHooks*: seq[proc(): string] # the first non-empty one replaces the echo line
  exitHooks*: seq[proc()]            # at exit, after the window closes
  cancelHooks*: seq[proc()]          # C-g outside a view: stop what runs in the background
  killHooks*: seq[proc(buf: Buffer)] # before a buffer is killed
  saveHooks*: seq[proc()]            # after b is saved
  saveGuards*: seq[proc(): bool]     # before C-x C-s writes: true = the guard took over (asked)
  modifiedIgnore*: seq[proc(buf: Buffer): bool]  # buffers whose edits never block quitting
  keyFilters*: seq[proc(c: string): bool]  # before dispatch; true consumes the key (popups)
  runeHooks*: seq[proc()]            # before a typed rune is inserted
  runeFilters*: seq[proc(r: Rune): bool]  # before that: true takes the rune (a terminal)
  insertHooks*: seq[proc(r: Rune)]   # after a self-inserted rune
  imeHooks*: seq[proc()]             # when a native IME composition starts
  escapeHooks*: seq[proc(): bool]    # true: Escape has a popup to close
  busyHooks*: seq[proc(): bool]      # true: C-g has something to cancel even over a popup
  dirVisitor*: proc(path: string)    # visit() on a directory; nil = refused
  marksHook*: proc(): seq[seq[int8]] # per-rune marks under b's text (diagnostics)
  boxHook*: proc(): CursorBox        # a box hanging from the cursor (completion, hover)
  modeLineHook*: proc(): string      # appended to the language name in the mode line
  faceProviders*: seq[proc(buf: Buffer): seq[seq[Face]]]  # a non-empty result replaces the
                                                             # language highlighting (a terminal's colours)
  backProviders*: seq[proc(buf: Buffer): seq[seq[int8]]]   # per-rune background colours (1-8), any pane
  markProviders*: seq[proc(buf: Buffer): seq[seq[int8]]]   # per-rune underlines (5) when the buffer has
                                                             # no diagnostics
  foldHook*: proc(buf: Buffer): seq[int8]  # per line: 0 shown, 1 hidden, 2 a headline hiding
                                           # the lines after it (drawn with "..."); empty = none
  revealHook*: proc(buf: Buffer, line: int)  # show a hidden line: open the folds over it
  visitHooks*: seq[proc()]           # after visit() loads a file into a new buffer
  defaults*: seq[string]             # Lisp evaluated after the default bindings, before ~/.darger.el

proc defineMode*(m: Mode) = modes[m.name] = m
proc definePrompt*(p: Prompt) = prompts[p.kind] = p
proc overlayOf*(m: string): string =
  ## The overlay m is, or the one its prompt floats over; "" for the editor and its prompts.
  if m in modes: m elif m in prompts: prompts[m].over else: ""
proc hasCandidates*(m: string): bool = m in prompts and prompts[m].candidates != nil
proc isConsult*(m: string): bool = m in prompts and prompts[m].consult
proc isPathPrompt*(m: string): bool = m in prompts and prompts[m].paths
proc isTextPrompt*(m: string): bool = m in prompts and prompts[m].text

proc runTicks*(): bool =
  ## Every tick hook; true when one asks for a redraw. An error goes to the echo line.
  for hook in tickHooks:
    try:
      if hook(): result = true
    except CatchableError as e:
      echoLine = e.msg
      result = true
proc runExit*() =
  for hook in exitHooks: hook()
proc filterKey*(c: string): bool =
  ## A popup or the like takes the key before dispatch.
  for hook in keyFilters:
    if hook(c): return true
var moveDirection* = 0  # the last buffer command's direction over hidden lines: 1, -1 or 0

proc filterRune*(r: Rune): bool =
  for filter in runeFilters:
    if filter(r): return true
proc beforeRune*() =
  moveDirection = 0
  for hook in runeHooks: hook()
proc inserted*(r: Rune) =
  for hook in insertHooks: hook(r)
proc imeStarted*() =
  for hook in imeHooks: hook()

# ---- Folds: lines an extension hides (Org subtrees); the cursor and scrolling skip them
proc folds*(buf: Buffer): seq[int8] = (if foldHook != nil: foldHook(buf) else: @[])
proc hiddenLine*(fold: seq[int8], n: int): bool = n < fold.len and fold[n] == 1
proc shownLine*(fold: seq[int8], count, n, direction: int): int =
  ## The nearest shown line from n (n itself when shown) in direction; -1 when none.
  result = n
  while result in 0..<count and hiddenLine(fold, result): result += direction
  if result notin 0..<count: result = -1
proc stepShown*(fold: seq[int8], count, n, delta: int): int =
  ## The line delta shown lines away from n, stopping at the first or last shown line.
  result = max(0, min(n, count - 1))
  let direction = if delta < 0: -1 else: 1
  for i in 1..abs(delta):
    let next = shownLine(fold, count, result + direction, direction)
    if next < 0: break
    result = next
proc shownBetween*(fold: seq[int8], a, z: int): int =
  ## The shown lines among a..<z.
  for n in a..<z:
    if not hiddenLine(fold, n): inc result

proc settleFolds*() =
  ## The cursor never rests on a hidden line: after a movement it skips the fold in the
  ## movement's direction, after anything else (search, goto, an edit) the fold opens.
  let fold = folds(b)
  if not hiddenLine(fold, b.cursor.line): return
  if moveDirection != 0:
    let n = shownLine(fold, b.lines.len, b.cursor.line, moveDirection)
    if n >= 0:
      b.cursor.line = n
      b.cursor.col = if b.last == "move" and b.goal >= 0: runeCol(b.lines[n], b.goal)
        elif moveDirection > 0: 0 else: b.lines[n].len
      return
  if revealHook != nil: revealHook(b, b.cursor.line)
proc wantsEscape*(): bool =
  for hook in escapeHooks:
    if hook(): return true
proc busy*(): bool =
  for hook in busyHooks:
    if hook(): return true
proc modifiedIgnored*(buf: Buffer): bool =
  for hook in modifiedIgnore:
    if hook(buf): return true









proc firstLine*(s: string): string =
  let i = s.find('\n')
  if i >= 0: s[0..<i] else: s



proc switchTo*(buf: Buffer) =
  ## Makes buf current: parks b's scroll and language in its slot and restores buf's.
  let overlay = overlayOf(mode).len > 0  # b's scroll is parked in overlayTop/Left
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
  pane.buf = b
  let slot = reg.slot(b)
  if overlay: (overlayTop = slot.top; overlayLeft = slot.left)
  else: (renderer.top = slot.top; renderer.left = slot.left)
  if slot.lang.name.len == 0 or slot.langPath != b.path: detectLang()
  else: lang = slot.lang
  shownBuf = nil
  reg.touch b


proc visit*(path: string) =
  ## Like Emacs, visiting a file that is already open switches to it with its edits.
  if dirExists(path):
    if dirVisitor == nil: raise newException(IOError, "Is a directory: " & path)
    dirVisitor(path)
    return
  var buf = reg.byPath(path)
  let fresh = buf == nil
  if fresh:
    buf = loadBuffer(path)
    reg.add buf
  switchTo(buf)
  if fileExists(b.path): recordRecent(b.path)  # a new file is recorded on its first save
  if fresh:
    for hook in visitHooks: hook()

proc anyModified*(): bool =
  for s in reg.slots:
    if s.buf.modified and not modifiedIgnored(s.buf): return true

proc killBuffer*(buf: Buffer) =
  ## Killing the current buffer shows the previous one; the last one leaves a fresh *scratch*.
  for hook in killHooks: hook(buf)
  reg.remove buf
  paneFaces.del buf
  if reg.len == 0: reg.add newBuffer()
  for p in layout.leaves:  # other panes showing it get the most recent remaining buffer
    if p != pane and p.buf == buf:
      p.buf = reg.current
      p.cursor = (0, 0)
      (p.top, p.left) = (0, 0)
  if buf == b: switchTo(reg.current)

proc selectPane*(p: Pane) =
  ## Makes p the selected pane: the pane left keeps its point and scroll, p's buffer
  ## becomes current at p's point and scroll (a buffer in two panes has a point in each).
  if p == pane: return
  pane.cursor = b.cursor
  pane.top = renderer.top
  pane.left = renderer.left
  let target = p.buf
  pane = p
  if target != b: switchTo(target)
  else: pane.buf = b
  renderer.top = p.top
  renderer.left = p.left
  let line = min(p.cursor.line, b.lines.high)
  b.cursor = (line, min(p.cursor.col, b.lines[line].len))
  b.goal = -1

proc splitPane*(below: bool) =
  ## C-x 2 / C-x 3: the selected pane shares its space with a new pane on the same buffer.
  if renderer.frameCols == 0: renderer.resize(window, b)  # from ~/.darger.el, before the first frame
  layoutPanes()
  if not pane.canSplit(below):
    echoLine = "Window too small to split"
    return
  layout.split(pane, below, Pane(buf: b, top: renderer.top, left: renderer.left, cursor: b.cursor))
  layoutPanes()

proc deletePane*() =
  ## C-x 0: the selected pane goes, its neighbour takes the space and the selection.
  let next = layout.remove(pane)
  if next == nil:
    echoLine = "Attempt to delete the sole window"
    return
  layoutPanes()
  selectPane(next)

proc deleteOtherPanes*() =
  layout.keepOnly(pane)
  layoutPanes()

proc clickAt*(cx, cy: int) =
  ## Mouse-1 on a text cell: that pane is selected and its point goes there (the mark
  ## is deactivated, as in Emacs). A click on a mode line only selects the pane.
  let p = layout.paneAt(cx, cy)
  if p == nil: return
  if p != pane: selectPane(p)
  if cy - p.y >= p.h - 1: return
  b.cursor = pointAt(b.lines, folds(b), renderer.top, renderer.left, gutterWidth(b.lines.len), cx - p.x, cy - p.y)
  b.regionActive = false
  b.goal = -1
  moveDirection = 0

proc wheelAt*(cx, cy, delta: int) =
  ## The wheel scrolls the pane under the pointer by delta lines (positive = down); its
  ## point follows to stay in view, as mwheel-scroll does, without selecting the pane.
  let p = layout.paneAt(cx, cy)
  if p == nil or delta == 0: return
  let buf = if p == pane: b else: p.buf
  let fold = folds(buf)
  let count = buf.lines.len
  let rows = max(1, p.h - 1)
  var top = if p == pane: renderer.top else: p.top
  var cursor = if p == pane: b.cursor else: p.cursor
  let last = shownLine(fold, count, buf.lines.high, -1)
  let maxTop = max(0, stepShown(fold, count, last, -(rows - 1)))
  top = clamp(stepShown(fold, count, top, delta), 0, maxTop)
  let bottom = stepShown(fold, count, top, rows - 1)
  if cursor.line < top: cursor.line = max(0, shownLine(fold, count, top, 1))
  elif cursor.line > bottom: cursor.line = bottom
  cursor.col = min(cursor.col, buf.lines[cursor.line].len)
  if p == pane:
    renderer.top = top
    b.cursor = cursor
    b.goal = -1
    moveDirection = 0
  else:
    p.top = top
    p.cursor = cursor

proc ctrl*(): bool = window.buttonDown[KeyLeftControl] or window.buttonDown[KeyRightControl]
proc alt*(): bool =
  # meta-modifier: "alt" or "cmd" (the macOS default), like Emacs' mac-command-modifier.
  let meta = interp.env.values.getOrDefault("meta-modifier")
  if meta != nil and meta.kind == vString and meta.str == "cmd":
    window.buttonDown[KeyLeftSuper] or window.buttonDown[KeyRightSuper]
  else: window.buttonDown[KeyLeftAlt] or window.buttonDown[KeyRightAlt]
proc shift*(): bool = window.buttonDown[KeyLeftShift] or window.buttonDown[KeyRightShift]

proc keypadNavigation*(): bool =
  when defined(windows): (getKeyState(0x90) and 1) == 0
  elif defined(linux):
    var state: XkbStateRec  # 0x100 = XkbUseCoreKbd
    if lockDisplay != nil and numLockMask != 0 and XkbGetState(lockDisplay, 0x100, state.addr) == 0:
      (state.locked_mods.cuint and numLockMask) == 0
    else: not window.buttonToggle[KeyNumLock]
  else: not window.buttonToggle[KeyNumLock]

proc chord*(key: Button): string =
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

proc setMini*(text: string) =
  mini = newBuffer(text)
  mini.cursor = (0, mini.lines[0].len)

proc commandNames*(): seq[string] =
  for name in interp.names:
    if name notin argCommands: result.add name

proc lineCandidates*(): seq[string] =
  let width = len($b.lines.len)
  candSkip = width + 2
  for i, line in b.lines:
    if i == b.lines.high and line.len == 0: break  # the empty line after a final newline
    result.add align($(i + 1), width) & "  " & $line[0..<min(line.len, 200)]

proc dropPreviews*(keep: Buffer = nil) =
  ## Kills the buffers opened only to preview a reference, except keep.
  for buf in previewed:
    if buf != keep and buf != b and buf in reg and not buf.modified: killBuffer(buf)
  previewed = @[]

proc pushXref*(buf: Buffer, at: Point, top, left: int) =
  xrefStack.add (buf, at, top, left)
  if xrefStack.len > 50: xrefStack.delete(0)

proc restoreOrigin*() =
  ## Back to where the consult prompt started, in the buffer it started in.
  if refOrigin in reg and b != refOrigin: switchTo(refOrigin)
  b.cursor = lineOrigin
  renderer.top = lineTop
  renderer.left = lineLeft
  dropPreviews()

proc abandonLine*() =
  ## A consult prompt replaced by another mode leaves the preview like C-g does.
  if isConsult(mode):
    restoreOrigin()
    mode = ""

proc preview*() =
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

proc refreshCandidates*(force = false) =
  ## Refilters after mini.text changed; like vertico, the first match is preselected.
  if not hasCandidates(mode):
    candAll = @[]
    cands = @[]
    candIndex = -1
    return
  if not force and mini.text == candText: return
  candText = mini.text
  var query = mini.text
  if isPathPrompt(mode):
    let (dir, tail) = splitInput(mini.text)
    let key = dir & (if tail.startsWith("."): "\0." else: "")
    if force or key != candDir:
      candDir = key
      candAll = listDir(dir, tail.startsWith("."))
    query = tail
  if isConsult(mode):  # kept in position order; consult-line does not match its line numbers
    cands = @[]
    candIdx = @[]
    for i, c in candAll:
      if matches(query, c[(if mode == "line": candSkip else: 0)..^1]):
        cands.add c
        candIdx.add i
  else: cands = filter(query, candAll)
  candIndex = if cands.len > 0: 0 else: -1
  if isConsult(mode): preview()

proc beginMini*(kind, label: string, initial = "") =
  ## Opens the prompt registered as kind (definePrompt), with its candidate list.
  let p = prompts[kind]
  b.finish()
  mode = kind
  prompt = label
  setMini(initial)
  echoLine = ""
  prefix = ""
  if p.consult:
    (lineOrigin = b.cursor; lineTop = renderer.top; lineLeft = renderer.left; refOrigin = b)
    previewed = @[]
  candAll = if p.candidates != nil: p.candidates() else: @[]
  refreshCandidates(true)

proc inMini*(): bool =
  ## A minibuffer prompt (search, find, y/n, ...) is active; see modes for the views.
  mode in prompts

proc beginOverlay*(kind: string) =
  b.finish()
  overlayTop = renderer.top
  overlayLeft = renderer.left
  mode = kind
  prefix = ""
  matchStart = -1
  window.closeIme()
  renderer.top = 0
  renderer.left = 0

proc finishOverlay*() =
  renderer.top = overlayTop
  renderer.left = overlayLeft
  mode = ""
  echoLine = ""



proc shortPath*(path: string, limit = 64): string =
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



proc cells*(s: string): int =
  for r in s.runes: result += runeWidth(r)








proc cutCells*(s: string, width: int): string =
  var used = 0
  for r in s.runes:
    let w = runeWidth(r)
    if used + w > width: break
    result.add r
    used += w

proc padCells*(s: string, width: int): string =
  result = cutCells(s, width)
  result.add spaces(width - cells(result))























proc closeOverlay*() =
  ## Leaves the view shown, or the one a prompt floats over, for a review or quitting.
  let over = overlayOf(mode)
  if over.len > 0 and modes[over].onClose != nil: modes[over].onClose()















proc quitEditor*() =
  abandonLine()
  closeOverlay()
  if anyModified(): beginMini("exit", "Modified buffers exist; exit anyway? (y or n) ")
  else: running = false

proc syncSearch*() =
  let state = isearch.state
  mini = newBuffer(state.query)
  mini.cursor.col = mini.lines[0].len
  matchStart = if state.failing: -1 else: state.matchStart
  prompt = (if state.failing: "Failing " elif state.wrapped: "Wrapped " else: "") &
    (if state.direction > 0: "I-search: " else: "I-search backward: ")

proc search*(next = false, direction = 0) =
  let query = if next and mini.text.len == 0: lastSearch else: mini.text
  b.searchStep(isearch, query, next, direction)
  syncSearch()

proc runCommand*(name: string): Value =
  if name notin bufferCommands: raise newException(LispError, "Unknown buffer command: " & name)
  moveDirection = case name
    of "next-line", "forward", "forward-word": 1
    of "previous-line", "backward", "backward-word": -1
    else: 0
  echoLine = b.command(name, if name == "yank" and b.kills.len == 0: getClipboardString() else: "")
  if b.last in ["kill", "copy"] and b.kills.len > 0: setClipboardString(b.kills[0])
  nilValue()

proc registerCommand*(name: string) =
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
  for i in 1..<tokens.len: prefixKeys.incl tokens[0..<i].join(" ")  # "C-c n f": C-c, then C-c n
  args[1])
interp.defPrimitive("insert", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  b.insert(args[0].asString)
  nilValue())
interp.defPrimitive("message", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  echoLine = args[0].asString
  args[0])
interp.defPrimitive("command", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  runCommand(args[0].asString))
proc wrote*() =
  echoLine = "Wrote " & b.path
  detectLang()
  recordRecent(b.path)
  for hook in saveHooks: hook()

proc saveBuffer*() =
  ## C-x C-s: saves the buffer, asking for a name when it has none.
  if b.path.len == 0: beginMini("write", "Write file: ", getCurrentDir() & DirSep)
  else:
    for guard in saveGuards:
      if guard(): return
    b.save()
    wrote()

proc findPrompt*() =
  beginMini("find", "Find file: ", (if b.path.len > 0: parentDir(b.path) else: getCurrentDir()) & DirSep)


proc switchPrompt*() =
  let other = reg.other
  beginMini("switch", "Switch to buffer" &
    (if other != nil: " (default " & reg.displayName(other) & ")" else: "") & ": ")

proc killPrompt*() =
  beginMini("kill", "Kill buffer (default " & reg.displayName(b) & "): ")

proc killQuestion*(buf: Buffer): string =
  "Buffer " & reg.displayName(buf) & " modified; kill anyway? (y or n) "

proc otherVisitor*(path: string): Buffer =
  ## The other buffer visiting path, which C-x C-w there replaces; a modified one refuses.
  result = reg.byPath(path)
  if result == b: return nil
  if result != nil and result.modified:
    raise newException(ValueError, "Buffer " & reg.displayName(result) & " visits that file and is modified")

proc writeTo*(path: string) =
  let other = otherVisitor(path)
  b.save(path)
  if other != nil: killBuffer(other)
  wrote()


proc confirmMini*() =
  ## Enter: the prompt's onAccept decides; the prompt closes unless it asked to stay.
  let kind = mode
  let p = prompts[kind]
  let value = when defined(windows): mini.text
              else: (if p.paths: expandTilde(mini.text) else: mini.text)
  if not p.onAccept(value): return
  if mode != kind: return  # the command opened another prompt or view
  mode = p.over
  matchStart = -1
  b.finish()

proc editMini*(c: string): bool =
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
  if cmd == "tab" and hasCandidates(mode):
    echoLine = "No match"  # TAB completes here; it never inserts a tab
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

proc candidateValue*(): string =
  ## The input the selected candidate stands for: file names keep the typed directory.
  if not isPathPrompt(mode): return cands[candIndex]
  mini.text[0 ..< mini.text.len - splitInput(mini.text).tail.len] & cands[candIndex]

proc moveCandidate*(delta: int, wrap: bool) =
  if cands.len == 0: return
  candIndex = if wrap: floorMod(candIndex + delta, cands.len) else: clamp(candIndex + delta, 0, cands.high)
  if isConsult(mode): preview()

proc candidateKey*(c: string): bool =
  ## Vertico's keys in a prompt with a candidate list; false leaves c to editMini.
  result = true
  case c
  of "C-n", "down": moveCandidate(1, true)
  of "C-p", "up": moveCandidate(-1, true)
  of "C-v", "pagedown": moveCandidate(10, false)
  of "M-v", "pageup": moveCandidate(-10, false)
  of "tab", "C-i":
    if isConsult(mode): return  # nothing to complete; TAB does nothing
    if candIndex < 0: return false
    setMini(candidateValue())  # a directory is listed next, like vertico-insert
    refreshCandidates()
  of "enter", "C-m", "C-j":
    # Dired takes the typed directory itself, and a new name is never a candidate.
    let p = prompts[mode]
    if p.rawEnter != nil and p.rawEnter():
      confirmMini()
      return
    if candIndex >= 0 and not p.consult:
      let value = candidateValue()
      setMini(value)
      if p.descend and value.endsWith("/"):
        refreshCandidates()  # vertico-directory-enter: descend instead of opening
        return
    confirmMini()
  else: result = false

proc target*(): Buffer = (if inMini(): mini else: b)

proc skkOn*(): bool =
  # ponytail: one SKK state serves the buffer and the text minibuffers; y/n and goto prompts bypass it.
  if "skk-egg-like-newline" in interp.env.values:
    inputMethod.eggLikeNewline = interp.env.values["skk-egg-like-newline"].kind != vNil
  inputMethod.enabled and (mode == "" or isTextPrompt(mode)) and
    window.imeCompositionString.len == 0

proc following*(): Rune =
  ## The character after the cursor, so SKK's ")" can step over a "）".
  let t = target()
  if t.cursor.col < t.lines[t.cursor.line].len: t.lines[t.cursor.line][t.cursor.col] else: Rune(0)

proc applySkk*(res: SkkResult, t = target()): bool =
  ## Inserts the engine's text like typed input; true when SKK consumed the key.
  t.insert(res.text, true)
  if res.move != 0: t.cursor = t.point(t.offset(t.cursor) + res.move)
  if mode == "search" and res.text.len > 0: search()
  elif inMini(): refreshCandidates()
  if res.consumed: echoLine = res.echo
  recenterCycle = 0
  if res.register.len > 0:
    # A reading without candidates: DDSKK's 辞書登録 prompt, where SKK works too.
    # Prompts do not nest, so inside one the reading just comes back as ▽.
    if inMini() or mode.len > 0:
      inputMethod.cancelRegister()
      echoLine = "No candidates for " & res.register
    else: beginMini("skk-register", "辞書登録 「" & res.register & "」: ")
  res.consumed

proc toggleSkk*(t = target()) =
  let message = if inputMethod.loaded: "" else: inputMethod.loadDefaults()
  discard applySkk(inputMethod.toggle(), t)
  if message.len > 0: echoLine = message

proc page*(buf: Buffer, full: string) =
  ## A page is a screen of shown lines: hidden (folded) lines do not count.
  let direction = if full in ["C-v", "pagedown"]: 1 else: -1
  let fold = folds(buf)
  let count = buf.lines.len
  let last = shownLine(fold, count, buf.lines.high, -1)
  if direction > 0 and shownBetween(fold, renderer.top, last + 1) <= renderer.rows:
    echoLine = "End of buffer"
    return
  if direction < 0 and renderer.top == 0:
    echoLine = "Beginning of buffer"
    return
  let delta = direction * max(1, renderer.rows-2)
  if buf.goal < 0: buf.goal = buf.cellCol(buf.cursor)
  buf.cursor.line = stepShown(fold, count, buf.cursor.line, delta)
  buf.cursor.col = runeCol(buf.lines[buf.cursor.line], buf.goal)
  buf.last = "move"
  let maxTop = stepShown(fold, count, last, -(renderer.rows - 1))
  renderer.top = clamp(stepShown(fold, count, renderer.top, delta), 0, max(0, maxTop))

proc recenter*(buf: Buffer) =
  let row = case recenterCycle
    of 0: renderer.rows div 2
    of 1: 0
    else: renderer.rows - 1
  renderer.top = stepShown(folds(buf), buf.lines.len, buf.cursor.line, -row)
  recenterCycle = (recenterCycle + 1) mod 3






















proc xrefBack*() =
  while xrefStack.len > 0:
    let (buf, at, top, left) = xrefStack.pop()
    if buf notin reg: continue  # killed since
    switchTo(buf)
    let line = clamp(at.line, 0, b.lines.high)
    b.cursor = (line, min(at.col, b.lines[line].len))
    renderer.top = top
    renderer.left = left
    return
  echoLine = "At start of xref history"




const
  zoomCommands* = ["zoom-in", "zoom-out", "zoom-reset"]
  builtinChords* = ["C-x C-s", "C-x C-f", "C-x C-w", "C-x C-c", "M-g g", "M-g M-g"]

proc symName*(fn: Value): string = (if fn != nil and fn.kind == vSymbol: fn.str else: "")

proc sticky*(full: string): string =
  ## The hydra prefix full belongs to, or "".
  for key in hydras.keys:
    if full.startsWith(key & " "): return key

proc rearm*(full: string) =
  let key = sticky(full)
  if key.len == 0: return
  prefix = key
  echoLine = hydras[key] & (if echoLine.len > 0: "  " & echoLine else: "")

proc leavesHydra*(full: string): bool =
  ## An unbound key after a hydra prefix leaves it; built-in chords stay chords.
  full notin keymap and full notin builtinChords and sticky(full).len > 0

proc overlayKey*(c: string): string =
  ## Prefix, hydra and zoom keys shared by the overlays; "" when c was consumed.
  if c == "C-g" and prefix.len > 0:
    prefix = ""  # quit the prefix or hydra, keep the overlay
    return
  result = if prefix.len > 0: prefix & " " & c else: c
  prefix = ""
  if leavesHydra(result): result = c  # the key's rune stays suppressed
  if result in prefixKeys:
    prefix = result
    echoLine = hydras.getOrDefault(result, result & "-")
    return ""
  let fn = keymap.getOrDefault(result)
  if fn.symName in zoomCommands:
    discard interp.call(fn, @[])
    rearm(result)
    return ""







proc copyText*(s: string) =
  ## Like M-w: onto the kill ring and the clipboard.
  b.kills.insert(s, 0)
  b.yankIndex = 0
  if b.kills.len > 60: b.kills.setLen(60)
  setClipboardString(s)
  echoLine = "Copied " & s







proc dispatch*(c: string) =
  moveDirection = 0
  if mode in prompts and prompts[mode].over.len > 0 and c in ["C-g", "escape"]:
    mode = prompts[mode].over  # back to the view the prompt floated over
    prefix = ""
    echoLine = ""
    return
  if mode in modes:
    modes[mode].onKey(c)
    return
  if c == "C-g":
    if mode in prompts and prompts[mode].onCancel != nil: prompts[mode].onCancel()
    if mode == "search": b.cursor = isearch.origin
    if isConsult(mode): restoreOrigin()
    mode = ""
    prefix = ""
    matchStart = -1
    echoLine = ""
    for hook in cancelHooks: hook()
    discard b.command("quit")
    return
  if isTextPrompt(mode):
    # Text prompts take keys bound to skk-mode (C-\, C-x C-j); C-j alone still confirms.
    if prefix.len == 0 and keymap.getOrDefault(c).symName == "skk-mode":
      toggleSkk()
      return
    if prefix.len == 0 and c == "C-x":
      prefix = c
      echoLine = "C-x-"
      return
    if prefix == "C-x":
      prefix = ""
      if keymap.getOrDefault("C-x " & c).symName == "skk-mode":
        toggleSkk()
        return
      if mode != "search":
        echoLine = "C-x " & c & " is undefined"
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
    if hasCandidates(mode) and candidateKey(c): return
    if c in ["enter", "C-m", "C-j", "M-enter"]: confirmMini()  # M-enter: the input as typed
    elif not editMini(c): echoLine = c & " is undefined"
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
    echoLine = hydras.getOrDefault(full, full & "-")
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
  of "C-x C-s": saveBuffer()
  of "C-x C-f": findPrompt()
  of "C-x C-w": beginMini("write", "Write file: ", b.path)
  of "C-x C-c": quitEditor()
  of "C-s", "C-r":
    isearch = b.startSearch(if full == "C-s": 1 else: -1)
    matchStart = -1
    beginMini("search", if isearch.state.direction > 0: "I-search: " else: "I-search backward: ")
  else: echoLine = full & " is undefined"

proc zoom*(factor: float32) =
  renderer.zoom = if factor == 0: 1'f32 else: clamp(renderer.zoom * factor, 0.5'f32, 4'f32)
  echoLine = "Zoom " & $int(round(renderer.zoom * 100)) & "%"

for (name, factor) in [("zoom-in", 1.1'f32), ("zoom-out", 1 / 1.1'f32), ("zoom-reset", 0'f32)]:
  closureScope:
    let f = factor
    interp.defPrimitive(name, proc(args: seq[Value]): Value =
      args.arity(0, 0)
      zoom(f)
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
interp.defPrimitive("lsp-back", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  xrefBack()
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
interp.defPrimitive("load-theme", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  let name = args[0].asString
  if not setTheme(name): raise newException(LispError, "No such theme: " & name)
  args[0])
interp.defPrimitive("set-font", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  let path = expandTilde(args[0].asString)
  if path.len == 0: raise newException(LispError, "Expected a font file path")
  try: renderer.setFont(path)
  except CatchableError as e:
    raise newException(LispError, "Cannot load font " & path & ": " & e.msg)
  args[0])
interp.defPrimitive("set-fallback-fonts", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  var paths: seq[string]
  for entry in args[0].asString.split(';'):
    if entry.strip.len > 0: paths.add expandTilde(entry.strip)
  if paths.len == 0: raise newException(LispError, "Expected font file paths separated by ';'")
  try: renderer.setFallbackFonts(paths.join(";"))
  except CatchableError as e:
    raise newException(LispError, "Cannot load fallback fonts: " & e.msg)
  args[0])
interp.defPrimitive("hydra", proc(args: seq[Value]): Value =
  args.arity(2, 2)
  let key = args[0].asString
  if key.len == 0 or ' ' in key: raise newException(LispError, "Expected a single-key prefix")
  hydras[key] = args[1].asString
  prefixKeys.incl key
  args[0])
let initPath* = getHomeDir() / ".darger.el"
var
  initStamp*: times.Time  # the init file's modification time when it was last loaded
  initChecked* = 0.0  # when the loop last looked at it

proc loadInit*(report = false) =
  ## Evaluates ~/.darger.el over the default bindings again, so a binding, hydra or
  ## setq dropped from the file goes back to its default. Feeds, LSP servers and
  ## defuns already added stay until restart.
  keymap.clear()
  hydras.clear()
  prefixKeys = toHashSet(["C-x", "M-g"])
  discard interp.evalString(defaultBindings, "<default-bindings>")
  # Option types special characters on macOS, so the command key is Meta there.
  const meta = when defined(macosx): "cmd" else: "alt"
  discard interp.evalString("(setq meta-modifier \"" & meta & "\")", "<default-bindings>")
  for i, src in defaults: discard interp.evalString(src, "<defaults " & $i & ">")
  initStamp = if fileExists(initPath): getLastModificationTime(initPath) else: times.Time()
  if not fileExists(initPath):
    echoLine = "No " & initPath & " (C-c , creates it)"  # at every start too: a misplaced init file is otherwise silent
    return
  try:
    discard interp.evalFile(initPath)
    if report: echoLine = "Loaded " & initPath
  except CatchableError as e: echoLine = e.msg

proc pollInit*(): bool =
  ## Reloads the init file when it changes on disk, checked twice a second, so a
  ## save from C-c , (or any editor) applies at once.
  if epochTime() - initChecked < 0.5: return
  initChecked = epochTime()
  let stamp = if fileExists(initPath): getLastModificationTime(initPath) else: times.Time()
  if stamp == initStamp: return
  loadInit(report = true)
  true

interp.defPrimitive("split-window-below", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  splitPane(true)
  nilValue())
interp.defPrimitive("split-window-right", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  splitPane(false)
  nilValue())
interp.defPrimitive("delete-window", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  deletePane()
  nilValue())
interp.defPrimitive("delete-other-windows", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  deleteOtherPanes()
  nilValue())
interp.defPrimitive("other-window", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  selectPane(layout.next(pane, 1))
  nilValue())
interp.defPrimitive("save-buffer", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  saveBuffer()
  nilValue())
for name in ["kill-emacs", "save-buffers-kill-terminal"]:
  interp.defPrimitive(name, proc(args: seq[Value]): Value =
    args.arity(0, 0)
    quitEditor()
    nilValue())
interp.defPrimitive("load-init", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  loadInit(report = true)
  nilValue())
var dirty* = true  # set by every input callback; the loop only redraws when it is set


proc overlayMessage*(base: string): string =
  ## A hydra hint replaces the overlay's own hint so the echo line does not overflow.
  if prefix in hydras: echoLine
  elif echoLine.len > 0 and echoLine != base: base & "  " & echoLine
  else: base

# ---- The built-in views, prompts and hooks, registered the way extensions do

proc noRows*(): seq[string] = @[]
proc lineRows*(): seq[string] =
  result = lineCandidates()
  targets = @[]
  for i in 0..<result.len: targets.add Location(line: i)
proc refRowsNow*(): seq[string] = refRows
proc switchRows*(): seq[string] =
  let names = reg.names  # most recently used first: b, then the default of C-x b
  names[1..^1] & names[0..0]
proc killRows*(): seq[string] = reg.names
proc acceptNothing*(value: string): bool = true  # the preview already moved there
proc acceptReference*(value: string): bool =
  if candIndex >= 0:
    pushXref(refOrigin, lineOrigin, lineTop, lineLeft)
    dropPreviews(b)
    if fileExists(b.path): recordRecent(b.path)
  true
proc yesNo*(value: string, yes: proc()): bool =
  if value.toLowerAscii == "y": yes()
  elif value.toLowerAscii != "n":
    echoLine = "Please answer y or n"
    return false
  true
proc lispError*(e: ref LispError) =
  echoLine = if e.line == 0: "<minibuffer>:1: " & e.msg else: e.msg

definePrompt(Prompt(kind: "search", text: true, onAccept: proc(value: string): bool =
  if value.len > 0: lastSearch = value
  true))
definePrompt(Prompt(kind: "eval", onAccept: proc(value: string): bool =
  try:
    let r = $interp.evalString(value, "<minibuffer>")
    if mode == "eval": echoLine = r  # (help) / (agent-prompt) switched mode; keep their message
  except LispError as e: lispError(e)
  true))
definePrompt(Prompt(kind: "execute", candidates: commandNames, onAccept: proc(value: string): bool =
  try: discard interp.call(symbol(value), @[])
  except LispError as e: lispError(e)
  true))
definePrompt(Prompt(kind: "find", text: true, paths: true, descend: true, candidates: noRows,
  onAccept: proc(value: string): bool =
    if value.len == 0: return false
    visit(value)
    true))
definePrompt(Prompt(kind: "write", text: true, paths: true, descend: true, candidates: noRows,
  onAccept: proc(value: string): bool =
    if value.len == 0: return false
    discard otherVisitor(value)
    if fileExists(value) and absolutePath(value) != b.path:
      pendingPath = value
      beginMini("overwrite", "File exists; overwrite? (y or n) ")
      return true
    writeTo(value)
    true))
definePrompt(Prompt(kind: "overwrite", onAccept: proc(value: string): bool =
  yesNo(value, proc() = writeTo(pendingPath))))
definePrompt(Prompt(kind: "switch", text: true, candidates: switchRows,
  onAccept: proc(value: string): bool =
    let target = if value.len == 0: reg.other else: reg.byName(value)
    if target != nil: switchTo(target)
    elif value.len > 0:
      let fresh = newBuffer()
      reg.add(fresh, value)
      switchTo(fresh)
    true))
definePrompt(Prompt(kind: "kill", text: true, candidates: killRows,
  onAccept: proc(value: string): bool =
    let target = if value.len == 0: b else: reg.byName(value)
    if target == nil: echoLine = "No such buffer: " & value
    elif target.modified and not modifiedIgnored(target):
      pendingKill = target
      beginMini("killy", killQuestion(target))
    else: killBuffer(target)
    true))
definePrompt(Prompt(kind: "killy", onCancel: proc() = (pendingKill = nil),
  onAccept: proc(value: string): bool =
    result = yesNo(value, proc() = killBuffer(pendingKill))
    if result: pendingKill = nil))
definePrompt(Prompt(kind: "skk-register", text: true, onAccept: proc(value: string): bool =
  if value.len == 0: inputMethod.cancelRegister()  # Enter alone: back to ▽, as in DDSKK
  else:
    b.insert(inputMethod.registerWord(value), true)
    echoLine = "Registered " & value
  true,
  onCancel: proc() = inputMethod.cancelRegister()))
definePrompt(Prompt(kind: "goto", onAccept: proc(value: string): bool =
  let line = parseInt(value)
  if line < 1: raise newException(ValueError, "Line number must be positive")
  b.cursor = (min(line-1, b.lines.high), 0)
  true))
definePrompt(Prompt(kind: "exit", onAccept: proc(value: string): bool =
  yesNo(value, proc() = (running = false))))
definePrompt(Prompt(kind: "line", text: true, consult: true, candidates: lineRows, onAccept: acceptNothing))

tickHooks.add pollInit

proc langOf(buf: Buffer): Lang =
  ## A non-selected pane's buffer language: from its slot, else detected now.
  if buf == b: return lang
  if buf in reg:
    let slot = reg.slot(buf)
    if slot.lang.name.len > 0 and slot.langPath == buf.path: return slot.lang
  detect(buf.path, if buf.lines.len > 0: $buf.lines[0] else: "")

proc facesOf(buf: Buffer): seq[seq[Face]] =
  ## Highlighting for a non-selected pane, cached per buffer version.
  if buf in paneFaces and paneFaces[buf].version == buf.version: return paneFaces[buf].faces
  for provider in faceProviders:
    result = provider(buf)
    if result.len > 0: break
  if result.len == 0: result = langOf(buf).highlight(buf.lines)
  paneFaces[buf] = (buf.version, result)

proc modeLineText(buf: Buffer, name: string, cursor: Point, modeName, tag: string): string =
  " -" & (if buf.modified: "**" else: "--") & "- " & name & "   L" & $(cursor.line+1) &
    " C" & $buf.cellCol(cursor) & "  (" & modeName & ") " & tag

proc redraw*(hover = thNone, maximized = false) =
  ## hover and maximized: the title bar's state, which the window code in darger.nim owns.
  if not running or window.closed or window.minimized or window.size.x == 0 or window.size.y == 0: return
  let over = overlayOf(mode)
  let view = if over.len > 0: modes[over] else: nil   # the view shown, under a prompt or not
  let active = if mode in modes: modes[mode] else: nil  # the view taking the keys
  var displayed = if view != nil: view.buffer() else: b
  renderer.resize(window, displayed)
  layoutPanes()
  if view != nil and view.beforeDraw != nil:
    view.beforeDraw()  # a resized or zoomed window lays the view out again
    displayed = view.buffer()
  let skkShown = skkOn()
  var message = ""
  for hook in messageHooks:
    message = hook()
    if message.len > 0: break
  if message.len == 0:
    message = if active != nil and active.message != nil: active.message()
      elif echoLine.len == 0 and skkShown and inMini(): inputMethod.page() else: echoLine
  # Prompts float in a popup; isearch stays on the bottom line so its match is visible.
  let popup = inMini() and mode != "search"
  if shownBuf != b or shownVersion != b.version:
    faces = @[]
    for provider in faceProviders:
      faces = provider(b)
      if faces.len > 0: break
    if faces.len == 0: faces = lang.highlight(b.lines)
    shownBuf = b
    shownVersion = b.version
  let displayFaces = if view == nil: faces elif view.faces != nil: view.faces() else: @[]
  let listed = inMini() and hasCandidates(mode)
  settleFolds()
  var shownMarks = if marksHook != nil: marksHook() else: @[]
  proc provided(providers: seq[proc(buf: Buffer): seq[seq[int8]]], buf: Buffer): seq[seq[int8]] =
    for provider in providers:
      result = provider(buf)
      if result.len > 0: return
  if shownMarks.len == 0: shownMarks = provided(markProviders, b)
  # From the 5th candidate SKK's page hangs from the cursor like a completion popup
  # (in a prompt, where no box fits, it is the echo line above).
  let skkPage = if skkShown and not inMini(): inputMethod.pageItems else: (keys: @[], words: @[], selected: 0)
  let box = if skkPage.words.len > 0:
      CursorBox(lines: skkPage.words, tags: skkPage.keys, selected: skkPage.selected,
        line: b.cursor.line, cell: b.cellCol(b.cursor), maxRows: 7)
    elif boxHook != nil: boxHook() else: CursorBox()
  # isearch marks its match; consult-line marks the previewed line.
  let highlight = if mode == "search": (start: matchStart, len: mini.text.runeLen)
    elif isConsult(mode) and candIndex >= 0:
      (start: b.offset((b.cursor.line, 0)), len: max(1, b.lines[b.cursor.line].len))
    else: (start: -1, len: 0)
  let editing = view == nil or view.editing
  let name = if editing: reg.displayName(b)
    elif displayed.path.len == 0: "*scratch*" else: displayed.path
  let modeName = if displayed == b: lang.name & (if modeLineHook != nil: modeLineHook() else: "")
    elif view.modeName.len > 0: view.modeName else: "Text"
  let tag = if view != nil and view.tag.len > 0: view.tag else: inputMethod.tag()
  # The selected pane shows the view or b with everything; the others their buffer plainly.
  let leaves = layout.leaves
  var views: seq[PaneView]
  for p in leaves:
    if p == pane:
      views.add PaneView(b: displayed, x: p.x, y: p.y, w: p.w, h: p.h,
        top: renderer.top, left: renderer.left, cursor: displayed.cursor, active: true,
        faces: displayFaces, marks: if displayed == b: shownMarks else: @[],
        bgs: if displayed == b: provided(backProviders, b) else: @[],
        fold: if displayed == b: folds(b) else: @[],
        lineColors: if view != nil and view.colors != nil: view.colors() else: @[],
        lineNumbers: displayed == b,
        modeLine: modeLineText(displayed, name, displayed.cursor, modeName, tag),
        box: if displayed == b: box else: CursorBox(),
        matchStart: highlight.start, matchLen: highlight.len)
    else:
      let buf = p.buf
      let line = min(p.cursor.line, buf.lines.high)
      p.cursor = (line, min(p.cursor.col, buf.lines[line].len))
      views.add PaneView(b: buf, x: p.x, y: p.y, w: p.w, h: p.h, top: p.top, left: p.left,
        cursor: p.cursor, active: false, faces: facesOf(buf), fold: folds(buf), lineNumbers: true,
        bgs: provided(backProviders, buf), marks: provided(markProviders, buf),
        modeLine: modeLineText(buf, reg.displayName(buf), p.cursor, langOf(buf).name, ""),
        matchStart: -1)
  renderer.draw(window, views, bars, message, mini.text,
    if inMini(): mini.cursor.col else: -1,
    if skkShown: inputMethod.preedit() else: "",
    prompt, popup,
    cands.toOpenArray(0, if listed: cands.high else: -1), candIndex, listed,
    if isConsult(mode): atBottom else: atTop,
    "darger — " & name, hover, maximized)
  for i, p in leaves:  # the scroll each pane settled on, so its cursor stays in view
    if p == pane: (renderer.top = views[i].top; renderer.left = views[i].left)
    else: (p.top = views[i].top; p.left = views[i].left)
