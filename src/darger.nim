import std/[os, strutils, unicode]
import windy, vmath
import buffer, render, skk

when defined(windows):
  proc getKeyState(key: int32): int16 {.stdcall, importc: "GetKeyState", dynlib: "user32".}

var b = newBuffer()
var startupMessage: string
if paramCount() > 0:
  try: b = loadBuffer(paramStr(1))
  except CatchableError as e: startupMessage = e.msg

var
  window = newWindow("darger", ivec2(1000, 720), vsync = true)
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
echo = startupMessage

proc ctrl(): bool = window.buttonDown[KeyLeftControl] or window.buttonDown[KeyRightControl]
proc alt(): bool = window.buttonDown[KeyLeftAlt] or window.buttonDown[KeyRightAlt]
proc shift(): bool = window.buttonDown[KeyLeftShift] or window.buttonDown[KeyRightShift]

proc keypadNavigation(): bool =
  when defined(windows): (getKeyState(0x90) and 1) == 0
  else: not window.buttonToggle[KeyNumLock]

proc chord(key: Button): string =
  var name = case key
    of KeySpace: "SPC"
    of NumpadEnter: "enter"
    of Numpad0..Numpad9:
      if keypadNavigation(): ["insert", "end", "down", "pagedown", "left", "", "right", "home", "up", "pageup"][ord(key)-ord(Numpad0)]
      else: $char(ord('0')+ord(key)-ord(Numpad0))
    of NumpadDecimal: (if keypadNavigation(): "delete" else: ".")
    of KeySlash: "/"
    of KeyMinus: (if shift(): "_" else: "-")
    of KeyComma: (if shift(): "<" else: ",")
    of KeyPeriod: (if shift(): ">" else: ".")
    of Key2: (if shift(): "@" else: "2")
    else: ($key).replace("Key", "").toLowerAscii
  if alt(): name = "M-" & name
  if ctrl(): name = "C-" & name
  name

proc beginMini(kind, label: string, initial = "") =
  b.finish()
  mode = kind
  prompt = label
  mini = newBuffer(initial)
  mini.cursor = (0, mini.lines[0].len)
  echo = ""
  prefix = ""

proc quitEditor() =
  if b.modified: beginMini("exit", "Modified buffers exist; exit anyway? (y or n) ")
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

proc confirmMini() =
  let value = mini.text
  let kind = mode
  if kind == "search" and value.len > 0: lastSearch = value
  case kind
  of "find":
    if value.len == 0: return
    if b.modified:
      pendingPath = value
      beginMini("replace", "Buffer modified; discard changes? (y or n) ")
      return
    let loaded = loadBuffer(value)
    loaded.kills = b.kills
    b = loaded
    renderer.top = 0
    renderer.left = 0
  of "replace":
    if value.toLowerAscii == "y":
      let loaded = loadBuffer(pendingPath)
      loaded.kills = b.kills
      b = loaded
      renderer.top = 0
      renderer.left = 0
    elif value.toLowerAscii != "n":
      echo = "Please answer y or n"
      return
  of "write":
    if value.len == 0: return
    if fileExists(value) and absolutePath(value) != b.path:
      pendingPath = value
      beginMini("overwrite", "File exists; overwrite? (y or n) ")
      return
    b.save(value)
    echo = "Wrote " & b.path
  of "overwrite":
    if value.toLowerAscii == "y":
      b.save(pendingPath)
      echo = "Wrote " & b.path
    elif value.toLowerAscii != "n":
      echo = "Please answer y or n"
      return
  of "goto":
    let line = parseInt(value)
    if line < 1: raise newException(ValueError, "Line number must be positive")
    b.cursor = (min(line-1, b.lines.high), 0)
  of "exit":
    if value.toLowerAscii == "y": running = false
    elif value.toLowerAscii != "n":
      echo = "Please answer y or n"
      return
  else: discard
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
  if mode == "search": search()
  true

proc target(): Buffer = (if mode.len > 0: mini else: b)

proc skkOn(): bool =
  # ponytail: one SKK state serves the buffer and the text minibuffers; y/n and goto prompts bypass it.
  inputMethod.enabled and mode in ["", "find", "write", "search"] and
    window.imeCompositionString.len == 0

proc following(): Rune =
  ## The character after the cursor, so SKK's ")" can step over a "）".
  let t = target()
  if t.cursor.col < t.lines[t.cursor.line].len: t.lines[t.cursor.line][t.cursor.col] else: Rune(0)

proc applySkk(res: SkkResult): bool =
  ## Inserts the engine's text like typed input; true when SKK consumed the key.
  let t = target()
  t.insert(res.text, true)
  if res.move != 0: t.cursor = t.point(t.offset(t.cursor) + res.move)
  if mode == "search" and res.text.len > 0: search()
  if res.consumed: echo = res.echo
  recenterCycle = 0
  res.consumed

proc dispatch(c: string) =
  if c == "C-g":
    if mode == "search": b.cursor = isearch.origin
    mode = ""
    prefix = ""
    matchStart = -1
    echo = ""
    discard b.command("quit")
    return
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
  if mode.len > 0:
    if c in ["enter", "C-m", "C-j"]: confirmMini()
    elif not editMini(c): echo = c & " is undefined"
    return
  let full = if prefix.len > 0: prefix & " " & c else: c
  prefix = ""
  if full in ["C-x", "M-g"]:
    prefix = full
    echo = full & "-"
    b.finish()
    return
  if full != "C-l": recenterCycle = 0
  let cmd = case full
    of "C-f", "right": "forward"
    of "C-b", "left": "backward"
    of "C-n", "down": "next-line"
    of "C-p", "up": "previous-line"
    of "C-a", "home": "bol"
    of "C-e", "end": "eol"
    of "M-f": "forward-word"
    of "M-b": "backward-word"
    of "M-<", "C-home": "bob"
    of "M->", "C-end": "eob"
    of "M-m": "indent"
    of "enter", "C-m", "C-j": "newline"
    of "tab", "C-i": "tab"
    of "backspace", "C-h": "backspace"
    of "C-d", "delete": "delete"
    of "C-k": "kill-line"
    of "C-o": "open-line"
    of "C-t": "transpose"
    of "M-d": "kill-word"
    of "M-backspace": "backward-kill-word"
    of "M-u": "upcase"
    of "M-l": "downcase"
    of "M-c": "capitalize"
    of "C-SPC", "C-@": "mark"
    of "C-x C-x": "exchange"
    of "C-w": "kill-region"
    of "M-w": "copy-region"
    of "C-y": "yank"
    of "M-y": "yank-pop"
    of "C-x h": "whole"
    of "C-/", "C-_", "C-x u": "undo"
    else: ""
  if cmd.len > 0:
    echo = b.command(cmd, if cmd == "yank" and b.kills.len == 0: getClipboardString() else: "")
    if b.last in ["kill", "copy"] and b.kills.len > 0: setClipboardString(b.kills[0])
    return
  b.finish()
  case full
  of "C-x C-j":
    let message = if inputMethod.loaded: "" else: inputMethod.loadDefaults()
    discard applySkk(inputMethod.toggle())
    if message.len > 0: echo = message
  of "C-v", "pagedown", "M-v", "pageup":
    let direction = if full in ["C-v", "pagedown"]: 1 else: -1
    if direction > 0 and renderer.top + renderer.rows > b.lines.high:
      echo = "End of buffer"
      return
    if direction < 0 and renderer.top == 0:
      echo = "Beginning of buffer"
      return
    let delta = direction * max(1, renderer.rows-2)
    b.vertical(delta)
    renderer.top = clamp(renderer.top + delta, 0, max(0, b.lines.len-renderer.rows))
  of "C-l":
    let row = case recenterCycle
      of 0: renderer.rows div 2
      of 1: 0
      else: renderer.rows - 1
    renderer.top = max(0, b.cursor.line - row)
    recenterCycle = (recenterCycle + 1) mod 3
  of "M-g g", "M-g M-g": beginMini("goto", "Goto line: ")
  of "C-x C-s":
    if b.path.len == 0: beginMini("write", "Write file: ", getCurrentDir() & DirSep)
    else:
      b.save()
      echo = "Wrote " & b.path
  of "C-x C-f":
    beginMini("find", "Find file: ", (if b.path.len > 0: parentDir(b.path) else: getCurrentDir()) & DirSep)
  of "C-x C-w": beginMini("write", "Write file: ", b.path)
  of "C-x C-c": quitEditor()
  of "C-s", "C-r":
    isearch = b.startSearch(if full == "C-s": 1 else: -1)
    matchStart = -1
    beginMini("search", if isearch.state.direction > 0: "I-search: " else: "I-search backward: ")
  else: echo = full & " is undefined"

window.onButtonPress = proc(key: Button) =
  if key in {KeyLeftControl, KeyRightControl, KeyLeftAlt, KeyRightAlt,
             KeyLeftShift, KeyRightShift, KeyLeftSuper, KeyRightSuper,
             KeyCapsLock, KeyNumLock, KeyScrollLock, KeyPause, KeyMenu, KeyPrintScreen,
             KeyInsert, KeyEscape} or key < Key0: return
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
    if prefix.len > 0:
      dispatch($Rune(scalar))
      return
    if skkOn() and applySkk(if scalar == 32: inputMethod.feed(skSpace)
                           else: inputMethod.feed(Rune(scalar), following())): return
    if mode.len > 0:
      mini.insert($Rune(scalar), true)
      if mode == "search": search()
    else:
      recenterCycle = 0
      b.insert($Rune(scalar), true)
  except CatchableError as e: echo = e.msg

window.onImeChange = proc() =
  if window.imeCompositionString.len > 0:
    prefix = ""
    suppressRune = false
    highSurrogate = 0
    b.finish()

window.onCloseRequest = proc() = quitEditor()

proc redraw() =
  if not running or window.closed or window.minimized or window.size.x == 0 or window.size.y == 0: return
  renderer.resize(window, b)
  let skkShown = skkOn()
  # The candidate page lives in echo; a command that cleared echo brings it back.
  let message = if echo.len == 0 and skkShown: inputMethod.page() else: echo
  let miniText = prompt & mini.text & (if message.len > 0: "  [" & message & "]" else: "")
  renderer.draw(window, b, message, miniText,
    if mode.len > 0: prompt.runeLen + mini.cursor.col else: -1,
    if mode == "search": matchStart else: -1,
    if mode == "search": mini.text.runeLen else: 0,
    if skkShown: inputMethod.preedit() else: "", inputMethod.tag())

window.onResize = redraw
while running and not window.closed:
  pollEvents()
  redraw()
  if window.minimized or window.size.x == 0 or window.size.y == 0: sleep(16)
window.close()
