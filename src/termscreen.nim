## A terminal screen for full-screen programs: a cols x rows grid of runes with
## colours, a cursor, a scrolling region, an alternate screen and scrollback, fed with
## what a process on a pty writes (VT100 / xterm sequences the common TUIs use).
import std/[unicode, strutils, sequtils]
import buffer  # runeWidth

type
  Cell* = object
    r*: Rune
    color*: int8   ## foreground: 0 = default, 1..8 = ANSI black .. white
    bg*: int8      ## background: 0 = none, 1..8
    attr*: uint8   ## bit 0 bold, bit 1 underline, bit 2 inverse
  Screen* = object
    cols*, rows*: int
    cells: seq[seq[Cell]]       ## rows x cols
    row*, col*: int             ## the cursor
    color, bg: int8             ## the current SGR colours
    attr: uint8
    top, bottom: int            ## the scrolling region (DECSTBM), inclusive
    wrapPending: bool           ## the cursor sits past the last column until the next rune
    pending: string             ## an incomplete escape or UTF-8 sequence
    saved: tuple[row, col: int]
    alt*: bool                  ## the alternate screen is shown (a full-screen program)
    mouse*: int                 ## mouse reporting asked for: 0 none, 1000 clicks, 1002 + drags, 1003 any motion
    sgrMouse*: bool             ## ?1006: SGR encoding of the reports
    main: seq[seq[Cell]]        ## the main screen while the alternate one is shown
    mainCursor: tuple[row, col: int]
    scrollback*: seq[seq[Cell]] ## lines scrolled off the top of the main screen
    maxScrollback*: int

const blank = Cell(r: Rune(' '), color: 0)

proc blankRow(cols: int): seq[Cell] = newSeq[Cell](cols).mapIt(blank)

proc initScreen*(cols, rows: int, maxScrollback = 2000): Screen =
  result.cols = max(1, cols)
  result.rows = max(1, rows)
  result.maxScrollback = maxScrollback
  for i in 0..<result.rows: result.cells.add blankRow(result.cols)
  result.top = 0
  result.bottom = result.rows - 1

proc cellAt*(s: Screen, row, col: int): Cell = s.cells[row][col]

const filler = Rune(0)  ## the second cell of a wide (CJK) rune

proc rowText(cells: seq[Cell]): string =
  var last = -1
  for i, c in cells:
    if (c.r != Rune(' ') and c.r != filler) or c.color != 0: last = i
  for i in 0..last:
    if cells[i].r != filler: result.add $cells[i].r

proc runeIndex*(s: Screen, row, col: int): int =
  ## The rune index in the row's text of the cell at col (wide runes take two cells).
  for i in 0..<min(col, s.cols):
    if s.cells[row][i].r != filler: inc result

proc lines*(s: Screen): seq[string] =
  ## The screen rows as text, trailing blanks trimmed.
  for r in s.cells: result.add rowText(r)

proc shownFg(c: Cell): int8 =
  ## Inverse video swaps the colours: default-on-default becomes black on white.
  if (c.attr and 4) != 0: (if c.bg > 0: c.bg else: 1'i8) else: c.color

proc shownBg(c: Cell): int8 =
  if (c.attr and 4) != 0: (if c.color > 0: c.color else: 8'i8) else: c.bg

proc perRune(s: Screen, pick: proc(c: Cell): int8): seq[seq[int8]] =
  for r in s.cells:
    var row: seq[int8]
    let count = rowText(r).runeLen
    for c in r:
      if row.len >= count: break
      if c.r != filler: row.add pick(c)
    result.add row

proc colors*(s: Screen): seq[seq[int8]] =
  ## The foreground colour of every shown rune, per row (0 = default, 1..8).
  s.perRune(shownFg)

proc backgrounds*(s: Screen): seq[seq[int8]] =
  ## The background colour of every shown rune, per row (0 = none, 1..8).
  s.perRune(shownBg)

proc underlines*(s: Screen): seq[seq[int8]] =
  ## 5 under every underlined rune (the renderer's plain underline mark), else 0.
  s.perRune(proc(c: Cell): int8 = (if (c.attr and 2) != 0: 5'i8 else: 0'i8))

proc scrollbackLines*(s: Screen): seq[string] =
  for r in s.scrollback: result.add rowText(r)

proc text*(s: Screen): string =
  ## Scrollback, then the screen, as lines.
  (s.scrollbackLines & s.lines).join("\n")

proc clampCursor(s: var Screen) =
  s.row = clamp(s.row, 0, s.rows - 1)
  s.col = clamp(s.col, 0, s.cols - 1)

proc scrollUp(s: var Screen, n: int) =
  ## Lines leave the top of the region; on the main screen with the region at the top they enter the scrollback.
  for i in 0..<n:
    if s.top == 0 and not s.alt:
      s.scrollback.add s.cells[0]
      if s.scrollback.len > s.maxScrollback: s.scrollback.delete(0)
    s.cells.delete(s.top)
    s.cells.insert(blankRow(s.cols), s.bottom)

proc scrollDown(s: var Screen, n: int) =
  for i in 0..<n:
    s.cells.delete(s.bottom)
    s.cells.insert(blankRow(s.cols), s.top)

proc lineFeed(s: var Screen) =
  if s.row == s.bottom: s.scrollUp(1)
  elif s.row < s.rows - 1: inc s.row

proc put(s: var Screen, r: Rune) =
  let wide = runeWidth(r) == 2 and s.cols >= 2  # a one-column screen has no room for the filler
  if s.wrapPending or (wide and s.col == s.cols - 1):  # a wide rune never straddles the margin
    if wide and not s.wrapPending: s.cells[s.row][s.col] = blank
    s.col = 0
    s.lineFeed()
    s.wrapPending = false
  s.cells[s.row][s.col] = Cell(r: r, color: s.color, bg: s.bg, attr: s.attr)
  if wide:
    s.cells[s.row][s.col + 1] = Cell(r: filler, color: s.color, bg: s.bg, attr: s.attr)
    s.col += 2
    if s.col >= s.cols:
      s.col = s.cols - 1
      s.wrapPending = true
  elif s.col == s.cols - 1: s.wrapPending = true
  else: inc s.col

proc erase(s: var Screen, row, a, z: int) =
  for c in max(0, a)..min(s.cols - 1, z): s.cells[row][c] = blank

proc sgr(s: var Screen, codes: seq[int]) =
  ## Colours (30-37 / 90-97, 40-47 / 100-107, 38;5;n / 48;5;n for the first 16, true
  ## colour as default), bold (1), underline (4), inverse (7) and their resets.
  var i = 0
  while i < codes.len:
    let c = codes[i]
    case c
    of 0: (s.color = 0; s.bg = 0; s.attr = 0)
    of 1: s.attr = s.attr or 1
    of 4: s.attr = s.attr or 2
    of 7: s.attr = s.attr or 4
    of 22: s.attr = s.attr and not 1'u8
    of 24: s.attr = s.attr and not 2'u8
    of 27: s.attr = s.attr and not 4'u8
    of 39: s.color = 0
    of 49: s.bg = 0
    of 30..37: s.color = int8(c - 30 + 1)
    of 90..97: s.color = int8(c - 90 + 1)
    of 40..47: s.bg = int8(c - 40 + 1)
    of 100..107: s.bg = int8(c - 100 + 1)
    of 38, 48:
      var value = 0'i8
      if i + 2 < codes.len and codes[i+1] == 5:
        if codes[i+2] in 0..15: value = int8(codes[i+2] mod 8 + 1)
        i += 2
      elif i + 4 < codes.len and codes[i+1] == 2: i += 4
      if c == 38: s.color = value else: s.bg = value
    else: discard
    inc i

proc csi(s: var Screen, params: string, final: char) =
  let private = params.len > 0 and params[0] == '?'
  var codes: seq[int]
  for part in (if private: params[1..^1] else: params).split(';'):
    if part.len == 0: codes.add 0
    else:
      try: codes.add parseInt(part)
      except ValueError: codes.add 0
  proc arg(i: int, default = 1): int =
    if i < codes.len and codes[i] != 0: codes[i] else: default
  if private:
    case final
    of 'h', 'l':
      for c in codes:
        if c in [1000, 1002, 1003]: s.mouse = (if final == 'h': c else: 0)
        elif c == 1006: s.sgrMouse = final == 'h'
        elif c in [1049, 1047, 47]:  # the alternate screen
          if final == 'h' and not s.alt:
            s.main = s.cells
            s.mainCursor = (s.row, s.col)
            s.alt = true
            for i in 0..<s.rows: s.cells[i] = blankRow(s.cols)
            (s.row, s.col) = (0, 0)
          elif final == 'l' and s.alt:
            s.cells = s.main
            (s.row, s.col) = s.mainCursor
            s.alt = false
            s.clampCursor()
    else: discard  # cursor visibility, bracketed paste, mouse: nothing to show
    return
  s.wrapPending = false
  case final
  of 'A': s.row = max(s.top, s.row - arg(0))
  of 'B': s.row = min(s.bottom, s.row + arg(0))
  of 'C': s.col = min(s.cols - 1, s.col + arg(0))
  of 'D': s.col = max(0, s.col - arg(0))
  of 'E': (s.row = min(s.bottom, s.row + arg(0)); s.col = 0)
  of 'F': (s.row = max(s.top, s.row - arg(0)); s.col = 0)
  of 'G', '`': s.col = clamp(arg(0) - 1, 0, s.cols - 1)
  of 'd': s.row = clamp(arg(0) - 1, 0, s.rows - 1)
  of 'H', 'f': (s.row = clamp(arg(0) - 1, 0, s.rows - 1); s.col = clamp(arg(1) - 1, 0, s.cols - 1))
  of 'J':
    case arg(0, 0)
    of 0:
      s.erase(s.row, s.col, s.cols - 1)
      for r in s.row+1..<s.rows: s.erase(r, 0, s.cols - 1)
    of 1:
      for r in 0..<s.row: s.erase(r, 0, s.cols - 1)
      s.erase(s.row, 0, s.col)
    else:
      for r in 0..<s.rows: s.erase(r, 0, s.cols - 1)
      if arg(0, 0) == 3: s.scrollback = @[]
  of 'K':
    case arg(0, 0)
    of 0: s.erase(s.row, s.col, s.cols - 1)
    of 1: s.erase(s.row, 0, s.col)
    else: s.erase(s.row, 0, s.cols - 1)
  of 'L':  # insert blank lines at the cursor, within the region
    if s.row in s.top..s.bottom:
      for i in 0..<min(arg(0), s.bottom - s.row + 1):
        s.cells.delete(s.bottom)
        s.cells.insert(blankRow(s.cols), s.row)
  of 'M':  # delete lines at the cursor
    if s.row in s.top..s.bottom:
      for i in 0..<min(arg(0), s.bottom - s.row + 1):
        s.cells.delete(s.row)
        s.cells.insert(blankRow(s.cols), s.bottom)
  of '@':  # insert blanks, pushing the rest of the line right
    for i in 0..<min(arg(0), s.cols - s.col):
      s.cells[s.row].delete(s.cols - 1)
      s.cells[s.row].insert(blank, s.col)
  of 'P':  # delete characters, pulling the rest left
    for i in 0..<min(arg(0), s.cols - s.col):
      s.cells[s.row].delete(s.col)
      s.cells[s.row].add blank
  of 'X': s.erase(s.row, s.col, s.col + arg(0) - 1)
  of 'S': s.scrollUp(arg(0))
  of 'T': s.scrollDown(arg(0))
  of 'r':
    let a = clamp(arg(0) - 1, 0, s.rows - 1)
    let z = clamp(arg(1, s.rows) - 1, 0, s.rows - 1)
    if z > a: (s.top, s.bottom) = (a, z)
    (s.row, s.col) = (0, 0)
  of 's': s.saved = (s.row, s.col)
  of 'u':  # the screen may have shrunk since the save
    (s.row, s.col) = s.saved
    s.clampCursor()
  of 'm': s.sgr(codes)
  else: discard  # device requests, modes, tabs: nothing to show

proc escapeLen(s: string, i: int): int =
  if i + 1 >= s.len: return 0
  case s[i+1]
  of '[':
    var j = i + 2
    while j < s.len and s[j].ord notin 0x40..0x7E: inc j
    if j >= s.len: 0 else: j - i + 1
  of ']':
    var j = i + 2
    while j < s.len:
      if s[j] == '\a': return j - i + 1
      if s[j] == '\x1b' and j + 1 < s.len and s[j+1] == '\\': return j - i + 2
      inc j
    0
  of '(', ')', '*', '+', '#': (if i + 2 < s.len: 3 else: 0)
  else: 2

proc feed*(s: var Screen, data: string) =
  let src = s.pending & data
  s.pending = ""
  var i = 0
  while i < src.len:
    let c = src[i]
    if c == '\x1b':
      let n = escapeLen(src, i)
      if n == 0:
        s.pending = src[i..^1]
        return
      case src[i+1]
      of '[': s.csi(src[i+2..<i+n-1], src[i+n-1])
      of '7': s.saved = (s.row, s.col)
      of '8':
        (s.row, s.col) = s.saved
        s.clampCursor()
      of 'D': s.lineFeed()                      # index
      of 'E': (s.col = 0; s.lineFeed())         # next line
      of 'M':                                   # reverse index
        if s.row == s.top: s.scrollDown(1) elif s.row > 0: dec s.row
      of 'c': s = initScreen(s.cols, s.rows, s.maxScrollback)  # full reset
      else: discard
      i += n
      continue
    if c.ord < 0x20 or c == '\x7f':
      case c
      of '\n', '\v', '\f': s.lineFeed()
      of '\r': (s.col = 0; s.wrapPending = false)
      of '\b': (s.col = max(0, s.col - 1); s.wrapPending = false)
      of '\t':
        s.col = min(s.cols - 1, (s.col div 8 + 1) * 8)
        s.wrapPending = false
      else: discard
      inc i
      continue
    let need = runeLenAt(src, i)
    if i + need > src.len:
      s.pending = src[i..^1]
      return
    s.put(runeAt(src, i))
    i += need

proc resize*(s: var Screen, cols, rows: int) =
  ## A new size: rows are kept from the top, cut or padded; the cursor stays inside.
  let cols = max(1, cols)
  let rows = max(1, rows)
  for r in s.cells.mitems:
    if r.len > cols: r.setLen(cols)
    else:
      while r.len < cols: r.add blank
  while s.cells.len > rows:
    if not s.alt:
      s.scrollback.add s.cells[0]
      if s.scrollback.len > s.maxScrollback: s.scrollback.delete(0)
    s.cells.delete(0)
    s.row = max(0, s.row - 1)
  while s.cells.len < rows: s.cells.add blankRow(cols)
  s.cols = cols
  s.rows = rows
  s.top = 0
  s.bottom = rows - 1
  s.wrapPending = false
  s.clampCursor()

proc inputAfter*(shown, current: string): string =
  ## Line mode: what the user typed into the terminal buffer beyond the text the
  ## screen last put there ("" when the buffer was changed elsewhere).
  if current.startsWith(shown): current[shown.len..^1] else: ""

proc keySequence*(chord: string, shift = false): string =
  ## The bytes a terminal sends a program for an editor key chord ("enter", "C-a",
  ## "M-f", "up", "f5" ...), xterm style; "" for keys the editor keeps.
  const named = {"enter": "\r", "C-m": "\r", "backspace": "\x7f", "C-h": "\x08", "tab": "\t",
    "C-i": "\t", "escape": "\x1b", "delete": "\x1b[3~", "insert": "\x1b[2~", "home": "\x1b[H",
    "end": "\x1b[F", "pageup": "\x1b[5~", "pagedown": "\x1b[6~", "up": "\x1b[A", "down": "\x1b[B",
    "right": "\x1b[C", "left": "\x1b[D", "f1": "\x1bOP", "f2": "\x1bOQ", "f3": "\x1bOR",
    "f4": "\x1bOS", "f5": "\x1b[15~", "f6": "\x1b[17~", "f7": "\x1b[18~", "f8": "\x1b[19~",
    "f9": "\x1b[20~", "f10": "\x1b[21~", "f11": "\x1b[23~", "f12": "\x1b[24~",
    "C-SPC": "\0", "C-@": "\0", "C-[": "\x1b", "C-\\": "\x1c", "C-]": "\x1d", "C-_": "\x1f",
    "C-/": "\x1f", "SPC": " "}
  if chord == "tab" and shift: return "\x1b[Z"
  for (name, bytes) in named:
    if chord == name: return bytes
  if chord.len == 3 and chord.startsWith("C-") and chord[2] in 'a'..'z':
    return $char(ord(chord[2]) - ord('a') + 1)
  if chord.startsWith("M-") and chord.len > 2:
    let rest = chord[2..^1]
    if rest.len == 1: return "\x1b" & rest
    let inner = keySequence(rest, shift)
    if inner.len > 0: return "\x1b" & inner
  ""

proc mouseReport*(s: Screen, button, col, row: int, release = false): string =
  ## What the program receives for a mouse event at cell (col, row), 0-based, when it
  ## asked for reports: SGR (`ESC[<b;x;yM`, `m` on release) or X10 (`ESC[M` + 3 bytes).
  ## button: 0 left, 1 middle, 2 right, 64 wheel up, 65 wheel down; "" when not reporting.
  if s.mouse == 0: return ""
  if s.sgrMouse:
    "\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) & (if release: "m" else: "M")
  else:
    let b = if release: 3 else: button
    "\x1b[M" & char(32 + b) & char(32 + min(col + 1, 223)) & char(32 + min(row + 1, 223))
