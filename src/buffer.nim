import std/[unicode, strutils, os]
import fileio
export fileio

type
  Point* = tuple[line, col: int]
  Snapshot = tuple[lines: seq[seq[Rune]], cursor: Point]
  Buffer* = ref object
    lines*: seq[seq[Rune]]
    cursor*, mark*: Point
    regionActive*, markSet*, modified*, crlf*, bom*: bool
    path*, last*, saved: string
    goal*: int
    kills*: seq[string]
    undoStack: seq[Snapshot]
    yankStart, yankEnd: int
    yankIndex*: int
    version*: int  # bumped on every change to lines, for caches such as highlighting
  SearchState* = object
    query*: string
    matchStart*: int
    cursor*: Point
    direction*: int
    failing*, wrapped*: bool
  ISearch* = object
    origin*: Point
    state*: SearchState
    history: seq[SearchState]

proc text*(b: Buffer): string =
  for i, line in b.lines:
    if i > 0: result.add '\n'
    result.add $line

proc setText(b: Buffer, s: string) =
  inc b.version
  b.lines = @[]
  for line in s.split('\n'): b.lines.add line.toRunes

proc newBuffer*(s = ""): Buffer =
  result = Buffer(goal: -1, saved: s)
  result.setText(s)

proc loadBuffer*(path: string): Buffer =
  if dirExists(path): raise newException(IOError, "Is a directory: " & path)
  var raw = if fileExists(path): readFile(path) else: ""
  if validateUtf8(raw) != -1:
    raise newException(ValueError, "File is not valid UTF-8")
  let bom = raw.startsWith("\xEF\xBB\xBF")
  if bom: raw = raw[3..^1]
  result = newBuffer(raw.replace("\r\n", "\n"))
  result.bom = bom
  result.crlf = "\r\n" in raw
  result.path = absolutePath(path)

proc save*(b: Buffer, path = "") =
  let target = if path.len > 0: absolutePath(path) else: b.path
  if target.len == 0: raise newException(ValueError, "No file name")
  let s = b.text
  atomicWrite(target, (if b.bom: "\xEF\xBB\xBF" else: "") &
    (if b.crlf: s.replace("\n", "\r\n") else: s))
  b.path = target
  b.saved = s
  b.modified = false

proc finish*(b: Buffer) =
  b.last = ""
  b.goal = -1

proc offset*(b: Buffer, p: Point): int =
  for i in 0..<p.line: result += b.lines[i].len + 1
  result += p.col

proc point*(b: Buffer, n: int): Point =
  var left = max(0, n)
  for i, line in b.lines:
    if left <= line.len: return (i, left)
    left -= line.len + 1
  (b.lines.high, b.lines[^1].len)

proc runeWidth*(r: Rune): int =
  let code = int(r)
  if r.isCombining or code in 0x200B..0x200D or code in 0xFE00..0xFE0F or
      code in 0xE0100..0xE01EF or code in 0x1F3FB..0x1F3FF: return 0
  if code in 0x1100..0x115F or code in 0x2E80..0x303E or
      code in 0x3041..0x33FF or code in 0x3400..0x4DBF or
      code in 0x4E00..0x9FFF or code in 0xA000..0xA4CF or
      code in 0xAC00..0xD7A3 or code in 0xF900..0xFAFF or
      code in 0xFE30..0xFE4F or code in 0xFF00..0xFF60 or
      code in 0xFFE0..0xFFE6 or code in 0x1F300..0x1F64F or
      code in 0x1F680..0x1F6FF or code in 0x1F900..0x1F9FF or
      code in 0x20000..0x3FFFD: return 2
  # ponytail: U+2600..27BF stays one cell like Emacs; add configurable widths if needed.
  1

proc cellWidth*(r: Rune, col: int): int =
  if r == Rune(9): 8 - col mod 8
  else: runeWidth(r)

proc cellCol*(line: openArray[Rune], runeCol: int): int =
  for i in 0..<clamp(runeCol, 0, line.len):
    result += cellWidth(line[i], result)

proc runeCol*(line: openArray[Rune], cell: int): int =
  ## Floor inside wide glyphs/tabs; choose the last boundary at zero-width marks.
  var col = 0
  for r in line:
    let width = cellWidth(r, col)
    if col + width > max(0, cell): break
    col += width
    inc result

proc cellCol*(b: Buffer, p: Point): int =
  cellCol(b.lines[p.line], p.col)

proc vertical*(b: Buffer, delta: int) =
  if b.goal < 0: b.goal = b.cellCol(b.cursor)
  b.cursor.line = clamp(b.cursor.line + delta, 0, b.lines.high)
  b.cursor.col = runeCol(b.lines[b.cursor.line], b.goal)
  b.last = "move"

proc region*(b: Buffer): tuple[a, z: int] =
  let a = b.offset(b.cursor)
  let z = b.offset(b.mark)
  (min(a, z), max(a, z))

proc snapshot*(b: Buffer, coalesce = false) =
  # ponytail: full snapshot per step; go diff-based if large files matter.
  if not coalesce:
    b.undoStack.add (b.lines, b.cursor)
    if b.undoStack.len > 200: b.undoStack.delete(0)

proc splice*(b: Buffer, a, z: int, s: string) =
  # ponytail: flatten on edits; use line-local splices if large files matter.
  let runes = b.text.toRunes
  let inserted = s.toRunes
  let oldMark = b.offset(b.mark)
  b.setText($(runes[0..<a] & inserted & runes[z..<runes.len]))
  b.cursor = b.point(a + inserted.len)
  b.mark = b.point(if oldMark <= a: oldMark
                   elif oldMark >= z: oldMark + inserted.len - (z - a)
                   else: a)
  b.modified = b.text != b.saved
  b.regionActive = false
  b.goal = -1

proc insert*(b: Buffer, s: string, selfInsert = false) =
  if s.len == 0: return
  let whitespace = s.toRunes.len != 1 or s.toRunes[0].isWhiteSpace
  b.snapshot(selfInsert and not whitespace and b.last == "insert")
  let n = b.offset(b.cursor)
  b.splice(n, n, s)
  b.last = if selfInsert and not whitespace: "insert" else: "edit"

proc wordRune(r: Rune): bool = r.isAlpha or r == Rune(ord('_')) or
  (int(r) >= ord('0') and int(r) <= ord('9'))

proc wordEnd*(b: Buffer, n, direction: int): int =
  let rs = b.text.toRunes
  result = n
  if direction > 0:
    while result < rs.len and not wordRune(rs[result]): inc result
    while result < rs.len and wordRune(rs[result]): inc result
  else:
    while result > 0 and not wordRune(rs[result-1]): dec result
    while result > 0 and wordRune(rs[result-1]): dec result

proc kill(b: Buffer, a, z: int, backward = false, copyOnly = false): string =
  if a == z:
    b.finish()
    return "Region is empty"
  let s = $(b.text.toRunes[a..<z])
  if b.last == "kill" and b.kills.len > 0 and not copyOnly:
    b.kills[0] = if backward: s & b.kills[0] else: b.kills[0] & s
  else:
    b.kills.insert(s, 0)
    if b.kills.len > 60: b.kills.setLen(60)
  if not copyOnly:
    b.snapshot()
    b.splice(a, z, "")
  b.regionActive = false
  b.last = if copyOnly: "copy" else: "kill"
  b.yankIndex = 0
  b.goal = -1

proc findMatch*(b: Buffer, query: string, start, direction: int, wrap = false): int =
  let source = b.text.toRunes
  let needle = query.toRunes
  if needle.len == 0: return clamp(start, 0, source.len)
  if needle.len > source.len: return -1
  let sensitive = query != unicode.toLower(query)
  let count = source.len - needle.len + 1
  var n = if direction > 0: max(0, start) else: min(start, count-1)
  for step in 0..<count:
    if n notin 0..<count:
      if not wrap: break
      n = if direction > 0: 0 else: count-1
    var matches = true
    for j, r in needle:
      if (if sensitive: source[n+j] != r else: source[n+j].toLower != r.toLower):
        matches = false
        break
    if matches: return n
    n += direction
  -1

proc startSearch*(b: Buffer, direction: int): ISearch =
  ISearch(origin: b.cursor, state: SearchState(matchStart: -1, cursor: b.cursor, direction: direction))

proc searchStep*(b: Buffer, search: var ISearch, query: string, repeat = false, direction = 0) =
  let old = search.state
  search.history.add old
  var state = old
  state.query = query
  if direction != 0: state.direction = direction
  if query.len == 0:
    state.cursor = search.origin
    state.matchStart = -1
    state.failing = false
  else:
    var start = if old.matchStart >= 0: old.matchStart
                else: b.offset(search.origin) - (if state.direction < 0: query.runeLen else: 0)
    # Reversing direction re-finds the current match from point, as Emacs does.
    if repeat and state.direction == old.direction:
      if old.failing:
        start = if state.direction > 0: 0 else: b.text.runeLen
        state.wrapped = true
      elif old.matchStart >= 0: start += state.direction * query.runeLen
    let found = b.findMatch(query, start, state.direction)
    state.failing = found < 0
    if found >= 0:
      state.matchStart = found
      state.cursor = b.point(found + (if state.direction > 0: query.runeLen else: 0))
  search.state = state
  b.cursor = state.cursor

proc searchBackspace*(b: Buffer, search: var ISearch) =
  if search.history.len > 0: search.state = search.history.pop()
  b.cursor = search.state.cursor

proc command*(b: Buffer, cmd: string, clipboard = ""): string =
  let n = b.offset(b.cursor)
  let total = b.text.runeLen
  let previous = b.last
  if cmd notin ["kill-line", "kill-word", "backward-kill-word", "kill-region"]:
    b.last = cmd
  if cmd notin ["next-line", "previous-line"]: b.goal = -1
  case cmd
  of "forward", "backward":
    let delta = if cmd == "forward": 1 else: -1
    if n + delta < 0: return "Beginning of buffer"
    if n + delta > total: return "End of buffer"
    b.cursor = b.point(n + delta)
  of "next-line", "previous-line":
    let delta = if cmd == "next-line": 1 else: -1
    if b.cursor.line + delta < 0: return "Beginning of buffer"
    if b.cursor.line + delta > b.lines.high: return "End of buffer"
    b.vertical(delta)
  of "bol": b.cursor.col = 0
  of "eol": b.cursor.col = b.lines[b.cursor.line].len
  of "bob": b.cursor = (0, 0)
  of "eob": b.cursor = b.point(total)
  of "indent":
    b.cursor.col = 0
    for r in b.lines[b.cursor.line]:
      if r notin [Rune(9), Rune(32)]: break
      inc b.cursor.col
  of "forward-word", "backward-word":
    b.cursor = b.point(b.wordEnd(n, if cmd == "forward-word": 1 else: -1))
  of "newline": b.insert("\n")
  of "tab":
    # ponytail: insert spaces at four-cell stops; add configurable indentation when needed.
    b.insert(repeat(' ', 4 - b.cellCol(b.cursor) mod 4))
  of "open-line":
    b.insert("\n")
    b.cursor = b.point(n)
  of "delete", "backspace":
    if b.regionActive and b.region.a != b.region.z:
      # An active region is deleted as a whole, without touching the kill ring.
      let (a, z) = b.region
      b.snapshot()
      b.splice(a, z, "")
      return
    let a = if cmd == "backspace": n - 1 else: n
    if a < 0: return "Beginning of buffer"
    if a >= total: return "End of buffer"
    b.snapshot()
    b.splice(a, a + 1, "")
  of "kill-line":
    let z = n + b.lines[b.cursor.line].len - b.cursor.col
    if n == total:
      b.finish()
      return "End of buffer"
    result = b.kill(n, if z == n: n + 1 else: z)
  of "kill-word", "backward-kill-word":
    let z = b.wordEnd(n, if cmd == "kill-word": 1 else: -1)
    result = b.kill(min(n, z), max(n, z), z < n)
  of "mark":
    if b.regionActive: b.regionActive = false
    else:
      b.mark = b.cursor
      b.markSet = true
      b.regionActive = true
      result = "Mark set"
  of "exchange":
    if not b.markSet: return "No mark set in this buffer"
    swap(b.cursor, b.mark)
    b.regionActive = true
  of "whole":
    b.mark = b.point(total)
    b.markSet = true
    b.cursor = (0, 0)
    b.regionActive = true
    result = "Mark set"
  of "kill-region", "copy-region":
    if not b.markSet:
      b.finish()
      return "No mark set in this buffer"
    let (a, z) = b.region
    result = b.kill(a, z, n > b.offset(b.mark), cmd == "copy-region")
  of "yank":
    let s = if b.kills.len > 0: b.kills[b.yankIndex mod b.kills.len] else: clipboard.replace("\r\n", "\n")
    if s.len == 0:
      b.finish()
      return "Kill ring is empty"
    if b.kills.len == 0: b.kills.add s
    b.insert(s)
    b.yankStart = n
    b.yankEnd = b.offset(b.cursor)
    b.mark = b.point(n)
    b.markSet = true
    b.last = "yank"
  of "yank-pop":
    if previous notin ["yank", "yank-pop"] or b.yankStart < 0 or b.yankEnd > total:
      b.finish()
      return "Previous command was not a yank"
    if b.kills.len == 0:
      b.finish()
      return "Kill ring is empty"
    b.snapshot()
    b.yankIndex = (b.yankIndex + 1) mod b.kills.len
    b.splice(b.yankStart, b.yankEnd, b.kills[b.yankIndex])
    b.yankEnd = b.offset(b.cursor)
    b.mark = b.point(b.yankStart)
    b.last = "yank-pop"
  of "undo":
    if b.undoStack.len == 0: return "No further undo information"
    let state = b.undoStack.pop()
    let markOffset = b.offset(b.mark)
    b.lines = state.lines
    inc b.version
    b.cursor = state.cursor
    b.mark = b.point(markOffset)
    b.regionActive = false
    b.modified = b.text != b.saved
    result = "Undo"
  of "transpose":
    if n == 0 or total < 2: return "Beginning of buffer"
    let z = if b.cursor.col == b.lines[b.cursor.line].len: n else: n + 1
    if z < 2: return "Beginning of buffer"
    let rs = b.text.toRunes
    b.snapshot()
    b.splice(z-2, z, $( @[rs[z-1], rs[z-2]] ))
  of "upcase", "downcase", "capitalize":
    let z = b.wordEnd(n, 1)
    var rs = b.text.toRunes[n..<z]
    var first = true
    for r in rs.mitems:
      if wordRune(r):
        r = if cmd == "upcase" or (cmd == "capitalize" and first): r.toUpper else: r.toLower
        first = false
    if z > n:
      b.snapshot()
      b.splice(n, z, $rs)
  of "quit": b.regionActive = false
  else: result = cmd & " is undefined"
