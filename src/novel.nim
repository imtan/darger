## Vertical writing for novel mode: columns with kinsoku, the scroll position counted in
## columns, the pixel grid, and the font's own vertical glyph table.
import std/[math, tables, unicode]
import buffer, wrap

const
  noColumnStart = "ーぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶ々ゝゞヽヾ〜…‥・：；！？!?,.，．）］｝〉》〕"
  noColumnEnd = "〈《〔［｛"
  rotatedForms = "ー〜…‥―—─–‐～－＝｜＿「」『』（）［］｛｝〈〉《》〔〕【】＜＞"
  cornerForms = "、。，．"
  smallForms = "ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶ"

type
  ColumnSpan* = tuple[start, stop: int]    ## the runes start..<stop of a line, one column
  Spot* = tuple[line, column: int]   ## a column of a logical line
  Counter* = proc(line: int): int    ## how many columns a line takes
  Grid* = object
    ## A pane in pixels: square cells of `cell` px, columns every `pitch` px from the right.
    width*, cell*, pitch*, inset*, rows*, columns*: int
  VerticalForm* = enum vfUpright, vfRotate, vfCorner, vfSmall

proc digit(r: Rune): bool = int(r) in ord('0')..ord('9')
proc bang(r: Rune): bool = r in [Rune('!'), Rune('?')]

proc tcySecond*(rs: seq[Rune], i: int): bool =
  ## Punctuation pairs are grouped from the start of their run; digits must be exactly two.
  if i <= 0 or i >= rs.len: return false
  if digit(rs[i]) and digit(rs[i - 1]):
    return (i == 1 or not digit(rs[i - 2])) and
      (i + 1 == rs.len or not digit(rs[i + 1]))
  if bang(rs[i]) and bang(rs[i - 1]):
    var start = i - 1
    while start > 0 and bang(rs[start - 1]): dec start
    return (i - start) mod 2 == 1

proc tcyFirst*(rs: seq[Rune], i: int): bool =
  i >= 0 and tcySecond(rs, i + 1)

proc advance(rs: seq[Rune], i: int): int =
  ## A combining mark or the second member of tate-chu-yoko shares its base's cell.
  if runeWidth(rs[i]) == 0 or tcySecond(rs, i): 0 else: 1

proc legalBreak(rs: seq[Rune], at: int): bool =
  if tcySecond(rs, at): return false
  if rs[at] in "…―—─".toRunes:
    var start = at
    while start > 0 and rs[start - 1] == rs[at]: dec start
    if (at - start) mod 2 == 1: return false
  legal(rs, at) and (rs[at] == Rune(0x2026) or rs[at] notin noColumnStart.toRunes) and
    rs[at - 1] notin noColumnEnd.toRunes

proc columns*(rs: seq[Rune], height: int): seq[ColumnSpan] =
  ## The columns of a line, each at most `height` cells. A column ending on a rune that
  ## must not be split from what follows gives that rune to the next column. A full last
  ## column is followed by an empty one, where the cursor at the end of the line goes.
  let height = max(1, height)
  var start, cells = 0
  while start < rs.len:
    var stop = start
    cells = 0
    while stop < rs.len and cells + advance(rs, stop) <= height:
      cells += advance(rs, stop)
      inc stop
    if stop < rs.len:
      var back = stop
      while back > start and not legalBreak(rs, back): dec back
      if back > start:
        stop = back
        cells = 0
    result.add (start, stop)
    start = stop
  if result.len == 0 or cells >= height: result.add (rs.len, rs.len)

proc columnOf*(spans: seq[ColumnSpan], col: int): int =
  ## The column holding rune col; the end of a column is the start of the next.
  for i, span in spans:
    if col < span.stop: return i
  spans.high

proc cellOf*(rs: seq[Rune], span: ColumnSpan, col: int): int =
  ## The cell of rune col in its column; a combining mark shares its base's cell.
  for i in span.start..<min(col, rs.len):
    result += advance(rs, i)
  if col < rs.len and advance(rs, col) == 0: result = max(0, result - 1)

proc colAtCell*(rs: seq[Rune], span: ColumnSpan, cell: int, last: bool): int =
  ## The rune at a cell of a column. Past its end: the line's end in the last column,
  ## else the column's last rune (its end would already be the next column).
  var cells = 0
  for i in span.start..<span.stop:
    if cells == cell and advance(rs, i) > 0: return i
    cells += advance(rs, i)
  if last: return span.stop
  result = max(span.start, span.stop - 1)
  while result > span.start and advance(rs, result) == 0: dec result

proc counter*(lines: seq[seq[Rune]], height: int): Counter =
  let lines = lines
  result = proc(line: int): int = columns(lines[line], height).len

proc stepSpot*(count: Counter, lineCount: int, at: Spot, delta: int): Spot =
  ## delta columns on (positive: towards the end), stopping at the buffer's ends.
  result = at
  var left = delta
  while left > 0:
    let room = count(result.line) - 1 - result.column
    if left <= room:
      result.column += left
      return
    if result.line >= lineCount - 1:
      result.column += room
      return
    left -= room + 1
    inc result.line
    result.column = 0
  while left < 0:
    if -left <= result.column:
      result.column += left
      return
    if result.line == 0:
      result.column = 0
      return
    left += result.column + 1
    dec result.line
    result.column = count(result.line) - 1

proc distance*(count: Counter, a, z: Spot, limit = int.high): int =
  ## Columns from a on to z (a <= z), giving up once past limit.
  if a.line == z.line: return z.column - a.column
  result = count(a.line) - a.column
  for line in a.line + 1..<z.line:
    result += count(line)
    if result > limit: return
  result += z.column

proc clampSpot*(count: Counter, lineCount: int, at: Spot): Spot =
  ## A scroll position left over from before an edit, back inside the buffer.
  let line = clamp(at.line, 0, lineCount - 1)
  (line, clamp(at.column, 0, count(line) - 1))

proc scrollToShow*(count: Counter, lineCount: int, anchor, cursor: Spot, visible: int): Spot =
  ## The first column to draw so the cursor's is among the `visible` from there: a step
  ## away scrolls just enough, as typing past the edge does; a jump centres the cursor.
  result = clampSpot(count, lineCount, anchor)
  if cursor < result:
    if distance(count, cursor, result, visible) <= visible div 2: result = cursor
    else: result = stepSpot(count, lineCount, cursor, -(visible div 2))
  else:
    let away = distance(count, result, cursor, 2 * visible)
    if away >= visible + visible div 2: result = stepSpot(count, lineCount, cursor, -(visible div 2))
    elif away >= visible: result = stepSpot(count, lineCount, cursor, -(visible - 1))

proc pointAtCell*(lines: seq[seq[Rune]], height: int, anchor: Spot, column, cell: int): Point =
  ## The point under a cell, `column` columns on from the anchor.
  let at = stepSpot(counter(lines, height), lines.len, anchor, column)
  let rs = lines[at.line]
  let spans = columns(rs, height)
  (at.line, colAtCell(rs, spans[at.column], cell, at.column == spans.high))

proc moveColumn*(lines: seq[seq[Rune]], height: int, cursor: Point, delta, goal: int):
    tuple[point: Point, goal: int] =
  ## The cursor delta columns on, at the cell it keeps (goal, or -1 for its current one).
  let rs = lines[cursor.line]
  let spans = columns(rs, height)
  let k = columnOf(spans, cursor.col)
  let cell = if goal >= 0: goal else: cellOf(rs, spans[k], cursor.col)
  let at = stepSpot(counter(lines, height), lines.len, (cursor.line, k), delta)
  if at == (cursor.line, k): return (cursor, cell)
  (pointAtCell(lines, height, at, 0, cell), cell)

proc spotOf*(lines: seq[seq[Rune]], height: int, cursor: Point): Spot =
  (cursor.line, columnOf(columns(lines[cursor.line], height), cursor.col))

proc gridFor*(width, height: int, em, spacing: float): Grid =
  ## A pane width by height pixels at a text size of em pixels, columns spacing ems apart.
  result.width = width
  result.cell = max(1, int(ceil(em)))
  result.pitch = max(result.cell, int(round(result.cell.float * spacing)))
  result.inset = result.cell div 2
  result.rows = max(1, (height - 2 * result.inset) div result.cell)
  result.columns = max(1, width div result.pitch)

proc columnLeft*(g: Grid, column: int): int =
  ## The pixel x, from the pane's left, of a column's cells; column 0 is the rightmost.
  g.width - (column + 1) * g.pitch + (g.pitch - g.cell) div 2

proc columnAtX*(g: Grid, x: int): int = max(0, g.width - 1 - x) div g.pitch
proc cellAtY*(g: Grid, y: int): int = clamp((y - g.inset) div g.cell, 0, g.rows - 1)

proc verticalForm*(r: Rune): VerticalForm =
  ## How to draw a rune whose font has no vertical glyph for it.
  if r in rotatedForms.toRunes: vfRotate
  elif r in cornerForms.toRunes: vfCorner
  elif r in smallForms.toRunes: vfSmall
  else: vfUpright

proc vertGlyphs*(buf: string, gsub: int): Table[uint16, uint16] =
  ## glyph -> vertical glyph, from the single substitutions of the GSUB table at offset
  ## gsub: its `vert` feature, or `vrt2` in a font without one. A damaged table gives
  ## what could be read before the damage.
  proc u16(at: int): int =
    if at < 0 or at + 2 > buf.len: raise newException(ValueError, "GSUB ends early")
    int(buf[at].uint8) shl 8 or int(buf[at + 1].uint8)
  proc u32(at: int): int = u16(at) shl 16 or u16(at + 2)
  proc covered(at: int): seq[int] =
    if u16(at) == 1:
      for i in 0..<u16(at + 2): result.add u16(at + 4 + i * 2)
    elif u16(at) == 2:
      for i in 0..<u16(at + 2):
        let record = at + 4 + i * 6
        for glyph in u16(record)..u16(record + 2): result.add glyph
  proc addSubstitutions(table: var Table[uint16, uint16], sub: int) =
    let format = u16(sub)
    for i, glyph in covered(sub + u16(sub + 2)):
      let to = if format == 1: (glyph + u16(sub + 4)) and 0xFFFF
               elif format == 2: u16(sub + 6 + i * 2)
               else: glyph
      discard table.hasKeyOrPut(glyph.uint16, to.uint16)
  try:
    let features = gsub + u16(gsub + 6)
    let lookups = gsub + u16(gsub + 8)
    for tag in ["vert", "vrt2"]:
      for i in 0..<u16(features):
        let record = features + 2 + i * 6
        discard u16(record + 4)
        if buf[record..<record + 4] != tag: continue
        let feature = features + u16(record + 4)
        for j in 0..<u16(feature + 2):
          let lookup = lookups + u16(lookups + 2 + u16(feature + 4 + j * 2) * 2)
          let kind = u16(lookup)
          for s in 0..<u16(lookup + 4):
            let sub = lookup + u16(lookup + 6 + s * 2)
            if kind == 1: result.addSubstitutions(sub)
            elif kind == 7 and u16(sub + 2) == 1: result.addSubstitutions(sub + u32(sub + 4))
      if result.len > 0: break
  except ValueError: discard

proc novelFormat*(text: string): string =
  ## Normalise novel prose without changing line boundaries. Keep display pairs in ASCII.
  var rs = text.toRunes
  for r in rs.mitems:
    if int(r) in 0xFF10..0xFF19: r = Rune(int(r) - 0xFEE0)
  # Times: hh:mm (one or two hour digits, either colon) becomes hh時mm分, the minutes
  # left out at :00 and leading zeros dropped; the digit rules below then apply.
  var timed: seq[Rune]
  var i = 0
  while i < rs.len:
    if digit(rs[i]) and (i == 0 or not digit(rs[i - 1])):
      var h = i
      while h < rs.len and digit(rs[h]): inc h
      if h - i <= 2 and h + 3 <= rs.len and rs[h] in [Rune(':'), Rune(0xFF1A)] and
          digit(rs[h + 1]) and digit(rs[h + 2]) and (h + 3 == rs.len or not digit(rs[h + 3])):
        var hours, minutes = 0
        for j in i..<h: hours = hours * 10 + int(rs[j]) - ord('0')
        minutes = (int(rs[h + 1]) - ord('0')) * 10 + int(rs[h + 2]) - ord('0')
        if hours <= 24 and minutes < 60:
          timed.add ($hours).toRunes
          timed.add Rune(0x6642)  # 時
          if minutes > 0:
            timed.add ($minutes).toRunes
            timed.add Rune(0x5206)  # 分
          i = h + 3
          continue
    timed.add rs[i]
    inc i
  rs = timed
  var wide: seq[Rune]
  i = 0
  while i < rs.len:
    let r = rs[i]
    var stop = i + 1
    if r in [Rune('.'), Rune('-')]:
      while stop < rs.len and rs[stop] == r: inc stop
    if (r == Rune('.') and stop - i >= 3) or r == Rune('-'):
      wide.add rs[i..<stop]  # reserve these for the ellipsis/dash pass
      i = stop
      continue
    if int(r) in 0x21..0x7E and not digit(r) and
        not tcyFirst(rs, i) and not tcySecond(rs, i):
      wide.add Rune(int(r) + 0xFEE0)
    else: wide.add r
    inc i
  var numbered: seq[Rune]
  let kanji = "〇一二三四五六七八九".toRunes
  let units = " 十百千".toRunes
  i = 0
  while i < wide.len:
    if not digit(wide[i]):
      numbered.add wide[i]
      inc i
      continue
    var stop = i
    while stop < wide.len and digit(wide[stop]): inc stop
    let count = stop - i
    if count == 2:
      numbered.add wide[i..<stop]
    elif count in 3..4 and (stop == wide.len or wide[stop] != Rune(0x5E74)):
      let before = numbered.len
      for j in i..<stop:
        let n = int(wide[j]) - ord('0')
        let power = stop - j - 1
        if n != 0:
          if n != 1 or power == 0: numbered.add kanji[n]
          if power > 0: numbered.add units[power]
      if numbered.len == before: numbered.add kanji[0]
    else:
      for j in i..<stop: numbered.add kanji[int(wide[j]) - ord('0')]
    i = stop
  var paired: seq[Rune]
  i = 0
  while i < numbered.len:
    let r = numbered[i]
    var stop = i + 1
    while stop < numbered.len and numbered[stop] == r: inc stop
    let count = stop - i
    if (r == Rune('.') or r == Rune(0x30FB)) and count >= 3:
      paired.add "……".toRunes
    elif r == Rune(0x2026) or r in "―—─".toRunes or (r == Rune('-') and count >= 2):
      let mark = if r == Rune(0x2026): r else: Rune(0x2015)
      for j in 0..<count + count mod 2: paired.add mark
    else: paired.add numbered[i..<stop]
    i = stop
  var brackets: seq[Rune]
  for i, r in paired:
    if r == Rune(0x3002) and i + 1 < paired.len and paired[i + 1] in "」』".toRunes: continue
    brackets.add r
  i = 0
  while i < brackets.len:
    let r = brackets[i]
    result.add $r
    let after = r in "！？".toRunes or (bang(r) and tcySecond(brackets, i))
    inc i
    if after:
      var stop = i
      while stop < brackets.len and brackets[stop] in [Rune(' '), Rune(0x3000)]: inc stop
      if stop < brackets.len and brackets[stop] notin "\r\n」』）】〕］！？!?".toRunes:
        result.add "　"
        i = stop
