## darger: the window, its input and the main loop. The editor itself is core.nim; the
## features are registered there and in the ext modules.
import std/[os, times, unicode, strutils, tables]
import windy, vmath
when defined(macosx): import macwin
import core, buffer, buffers, render, skk, update
import ext/[org, web, rss, dired, help, dash, blist, agent, selfupdate, langserver, revert, shader, term, claude, grep, eagle, project, migemo]

when defined(macosx):
  # AppKit reports a borderless window as always zoomed and zoom() leaves it alone, so
  # darger keeps its own maximized state: the screen's visible area and back.
  var
    zoomed = false
    zoomFrom: tuple[pos, size: IVec2]
  proc isMaximized(): bool = zoomed
  proc setMaximized(on: bool) =
    if on == zoomed: return
    zoomed = on
    if on:
      zoomFrom = (window.pos, window.size)
      let area = window.visibleArea
      let scale = window.contentScale
      # windy sizes in pixels and positions in points, keeping the top edge when it
      # resizes, and places the frame one point below the position given.
      window.size = ivec2(int32(area.w * scale), int32(area.h * scale))
      window.pos = ivec2(int32(area.x), int32(area.y) - 1)
    else:
      window.size = zoomFrom.size
      window.pos = zoomFrom.pos
else:
  proc isMaximized(): bool = window.maximized
  proc setMaximized(on: bool) = window.maximized = on

proc moveBy(delta: IVec2) =
  ## Moves the window by a mouse delta. macOS positions windows in points while the
  ## mouse and the size count pixels; truncating keeps a slow drag from jittering.
  when defined(macosx):
    let s = window.contentScale
    window.pos = window.pos + ivec2(int32(delta.x.float32 / s), int32(delta.y.float32 / s))
  else: window.pos = window.pos + delta

var
  grab = ivec2(-1, -1)  # where in the window the left button went down; x < 0: nothing to drag
  grabSize: IVec2       # the window size then
  grabX, grabY: bool    # it went down on the right / bottom edge: the drag resizes that way
  pressed = thNone      # the title bar button the left button went down on
  hover = thNone        # the title bar button under the mouse, drawn highlighted

window.onMouseMove = proc() =
  # No frame, so dragging moves the window; its right and bottom edges and its corner
  # resize it. ponytail: the mouse does nothing else, so the whole window is the handle;
  # keep only the title bar and the border once clicks place the cursor
  let hit = renderer.titleHit(window, window.mousePos)
  let over = if hit in titleButtons: hit else: thNone
  if over != hover:
    hover = over
    dirty = true
  if grab.x < 0 or not window.buttonDown[MouseLeft] or isMaximized(): return
  let delta = window.mousePos - grab
  if grabX or grabY:
    window.size = ivec2(if grabX: max(200'i32, grabSize.x + delta.x) else: grabSize.x,
                        if grabY: max(120'i32, grabSize.y + delta.y) else: grabSize.y)
  else: moveBy(delta)

window.onButtonRelease = proc(key: Button) =
  if key != MouseLeft: return
  if mode.len == 0:
    let (cx, cy) = renderer.cellAt(window.mousePos)
    discard mouseEvent(cx, cy, 0, false)  # a terminal reporting the mouse hears the release
  let button = pressed
  pressed = thNone
  grab.x = -1
  if button == thNone: return
  dirty = true
  if renderer.titleHit(window, window.mousePos) != button: return  # released elsewhere: cancelled
  try:
    case button
    of thClose: quitEditor()
    of thMinimize: window.minimized = true
    of thMaximize: setMaximized(not isMaximized())
    else: discard
  except CatchableError as e: echoLine = e.msg

window.onButtonPress = proc(key: Button) =
  dirty = true
  if key == MouseLeft:
    let hit = renderer.titleHit(window, window.mousePos)
    pressed = if hit in titleButtons: hit else: thNone
    grab = if pressed == thNone: window.mousePos else: ivec2(-1, -1)
    if hit == thNone and mode.len == 0:  # a click in the text places the cursor (the drag still moves the window)
      let (cx, cy) = renderer.cellAt(window.mousePos)
      if not mouseEvent(cx, cy, 0, true): clickAt(cx, cy)
    grabSize = window.size
    let ui = window.uiScale
    let corner = int32(32 * ui)
    let edge = int32(6 * ui)
    let inCorner = grab.x > grabSize.x - corner and grab.y > grabSize.y - corner
    grabX = grab.x >= 0 and (inCorner or grab.x >= grabSize.x - edge)
    grabY = grab.x >= 0 and (inCorner or grab.y >= grabSize.y - edge)
  elif key == DoubleClick:
    if renderer.titleHit(window, window.mousePos) == thBar:
      setMaximized(not isMaximized())
      grab.x = -1  # the window jumped under the mouse; this click must not drag it
  if key in {KeyLeftControl, KeyRightControl, KeyLeftAlt, KeyRightAlt,
             KeyLeftShift, KeyRightShift, KeyLeftSuper, KeyRightSuper,
             KeyCapsLock, KeyNumLock, KeyScrollLock, KeyPause, KeyMenu, KeyPrintScreen,
             KeyInsert} or key < Key0: return
  # Escape only closes a view or a popup
  if key == KeyEscape and overlayOf(mode).len == 0 and not wantsEscape(): return
  if window.imeCompositionString.len > 0:
    if key == KeyG and ctrl():
      window.closeIme()
      dispatch("C-g")
    return
  echoLine = ""
  let printable = key in {Key0..KeyZ, KeyBacktick, KeyMinus, KeyEqual,
    KeyLeftBracket, KeyRightBracket, KeyBackslash, KeySemicolon,
    KeyApostrophe, KeyComma, KeyPeriod, KeySlash, KeySpace, NumpadAdd..NumpadEqual} or
    (key in {Numpad0..Numpad9, NumpadDecimal} and not keypadNavigation())
  suppressRune = prefix.len > 0 and printable and not ctrl() and not alt()
  if not ctrl() and not alt() and prefix.len == 0 and printable: return
  try:
    let c = chord(key)
    if c.len == 0 or c == "insert": return
    if c == "C-g" and busy():
      discard filterKey(c)
      dispatch(c)
      return
    if filterKey(c): return
    if prefix.len == 0 and skkOn():
      var key: SkkKey
      var named = true
      case c
      of "enter", "C-m": key = skEnter
      of "backspace", "C-h": key = skBackspace
      of "tab", "C-i": key = skTab
      of "C-j": key = skCtrlJ
      of "C-g": key = skCtrlG
      of "C-n", "down": key = skNext  # in ▼: the next / previous candidate
      of "C-p", "up": key = skPrev
      else: named = false
      if named:
        if applySkk(inputMethod.feed(key)): return
      elif inputMethod.composing:
        # Any other command (C-a, M-x, C-x ...) first commits what SKK has in progress,
        # as DDSKK does, instead of leaving ▽ / ▼ behind at the old cursor.
        discard applySkk(inputMethod.commit())
    dispatch(c)
  except CatchableError as e: echoLine = e.msg

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
  echoLine = ""
  try:
    if mode in modes:
      dispatch($Rune(scalar))
      return
    if prefix.len > 0:
      dispatch($Rune(scalar))
      return
    if filterRune(Rune(scalar)): return  # a terminal buffer takes every typed rune
    beforeRune()
    if skkOn():
      if applySkk(if scalar == 32: inputMethod.feed(skSpace)
                  else: inputMethod.feed(Rune(scalar), following())): return
    if inMini():
      mini.insert($Rune(scalar), true)
      if mode == "search": search() else: refreshCandidates()
    else:
      recenterCycle = 0
      b.insert($Rune(scalar), true)
      inserted(Rune(scalar))
  except CatchableError as e: echoLine = e.msg

window.onImeChange = proc() =
  dirty = true
  if mode in modes:
    if window.imeCompositionString.len > 0: window.closeIme()
    return
  if window.imeCompositionString.len > 0:
    prefix = ""
    suppressRune = false
    highSurrogate = 0
    b.finish()
    imeStarted()

window.onCloseRequest = proc() = quitEditor()

proc openSystemFiles(paths: seq[string]): bool =
  ## Files handed over by Finder, Spotlight or `open -a darger` (macOS); true when any came.
  for path in paths:
    result = true
    if overlayOf(mode) == "dash": closeOverlay()  # the file shows instead of the dashboard
    try: visit(path)
    except CatchableError as e: echoLine = e.msg

var args: seq[string]
for i in 1..paramCount(): args.add paramStr(i)
# The launch-time files arrive inside windy's finishLaunching, so they are already here.
# AppKit also reports our own command-line arguments as opened files: those are dropped.
var launchFiles: seq[string]
when defined(macosx):
  for path in takeOpenedFiles():
    var given = false
    for a in args:
      if absolutePath(a) == absolutePath(path): given = true
    if not given: launchFiles.add path
if args.len >= 1:
  var opened: seq[Buffer]
  var firstPath: string
  for path in args:
    try:
      if not dirExists(path):
        visit(path)
        opened.add b
      if firstPath.len == 0: firstPath = path
    except CatchableError as e: echoLine = e.msg
  for i in countdown(opened.high, 1): reg.touch opened[i]
  if opened.len > 0: switchTo(opened[0])
  if firstPath.len > 0 and dirExists(firstPath):
    try: visit(firstPath)  # a directory opens in dired
    except CatchableError as e: echoLine = e.msg
loadInit()

proc draw() = redraw(hover, isMaximized())
window.onResize = draw
removeStaleExe()
if not openSystemFiles(launchFiles) and args.len == 0 and startScreen != nil: startScreen()  # the dashboard over an empty *scratch*
var lastDraw = 0.0
var wheel = 0.0  # fractional wheel lines carried between frames
while running and not window.closed:
  pollEvents()
  let scroll = window.scrollDelta
  if scroll.y != 0 and mode.len == 0:
    wheel -= scroll.y * 3  # a notch scrolls three lines; up (positive) shows earlier text
    let lines = int(wheel)
    if lines != 0:
      wheel -= lines.float
      let (cx, cy) = renderer.cellAt(window.mousePos)
      try:
        var taken = false
        for i in 1..abs(lines): taken = mouseEvent(cx, cy, if lines < 0: 64 else: 65, true) or taken
        if not taken: wheelAt(cx, cy, lines)
      except CatchableError as e: echoLine = e.msg
      dirty = true
  when defined(macosx):
    if openSystemFiles(takeOpenedFiles()): dirty = true  # from Finder, Spotlight or `open -a darger` while running
  if runTicks(): dirty = true
  # ponytail: redraw after input or every 250 ms; an unconditional per-frame redraw kept ~2 cores busy while idle
  if dirty or epochTime() - lastDraw > 0.25:
    draw()
    dirty = false
    lastDraw = epochTime()
  else:
    sleep(8)
window.close()
runExit()
