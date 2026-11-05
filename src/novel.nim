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
  DisplayLine* = object
    runes*: seq[Rune]      ## Display text; the source is never modified.
    origin*: seq[int]      ## Source group start for each display rune.
    index*: seq[int]       ## Display group start for each source position, including EOF.
  MappedRunes = object
    runes: seq[Rune]
    origin, ends: seq[int] # Exclusive source ends distinguish consumed groups from deletions.
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

proc addMapped(dst: var MappedRunes, rs: openArray[Rune], origin, finish: int) =
  for r in rs:
    dst.runes.add r
    dst.origin.add origin
    dst.ends.add finish

proc copyMapped(dst: var MappedRunes, src: MappedRunes, a, z: int) =
  for i in a..<z: dst.addMapped([src.runes[i]], src.origin[i], src.ends[i])

proc groupMapped(dst: var MappedRunes, src: MappedRunes, a, z: int, rs: openArray[Rune]) =
  dst.addMapped(rs, src.origin[a], src.ends[z - 1])

proc displayLine*(source: seq[Rune]): DisplayLine =
  ## Each rewrite carries its source interval through the following passes. Deleted
  ## positions map to the next group; positions consumed by a rewrite map to its start.
  var initial: MappedRunes
  for i, r in source:
    initial.addMapped([if int(r) in 0xFF10..0xFF19: Rune(int(r) - 0xFEE0) else: r], i, i + 1)
  var rs = initial.runes
  # Times: hh:mm (one or two hour digits, either colon) becomes hh時mm分, the minutes
  # left out at :00 and leading zeros dropped; the digit rules below then apply.
  var timed: MappedRunes
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
          var time = ($hours).toRunes
          time.add Rune(0x6642)  # 時
          if minutes > 0:
            time.add ($minutes).toRunes
            time.add Rune(0x5206)  # 分
          timed.groupMapped(initial, i, h + 3, time)
          i = h + 3
          continue
    timed.copyMapped(initial, i, i + 1)
    inc i
  rs = timed.runes
  var wide: MappedRunes
  i = 0
  while i < rs.len:
    let r = rs[i]
    if bang(r) and tcyFirst(rs, i):
      wide.groupMapped(timed, i, i + 2, rs[i..<i + 2])
      i += 2
      continue
    var stop = i + 1
    if r in [Rune('.'), Rune('-')]:
      while stop < rs.len and rs[stop] == r: inc stop
    if (r == Rune('.') and stop - i >= 3) or r == Rune('-'):
      wide.copyMapped(timed, i, stop)  # reserve these for the ellipsis/dash pass
      i = stop
      continue
    if int(r) in 0x21..0x7E and not digit(r) and
        not tcyFirst(rs, i) and not tcySecond(rs, i):
      wide.groupMapped(timed, i, i + 1, [Rune(int(r) + 0xFEE0)])
    else: wide.copyMapped(timed, i, i + 1)
    inc i
  var numbered: MappedRunes
  let kanji = "〇一二三四五六七八九".toRunes
  let units = " 十百千".toRunes
  i = 0
  while i < wide.runes.len:
    if not digit(wide.runes[i]):
      numbered.copyMapped(wide, i, i + 1)
      inc i
      continue
    var stop = i
    while stop < wide.runes.len and digit(wide.runes[stop]): inc stop
    let count = stop - i
    if count == 2:
      numbered.copyMapped(wide, i, stop)
    elif count in 3..4 and (stop == wide.runes.len or wide.runes[stop] != Rune(0x5E74)):
      var number: seq[Rune]
      for j in i..<stop:
        let n = int(wide.runes[j]) - ord('0')
        let power = stop - j - 1
        if n != 0:
          if n != 1 or power == 0: number.add kanji[n]
          if power > 0: number.add units[power]
      if number.len == 0: number.add kanji[0]
      numbered.groupMapped(wide, i, stop, number)
    else:
      for j in i..<stop:
        numbered.groupMapped(wide, j, j + 1, [kanji[int(wide.runes[j]) - ord('0')]])
    i = stop
  var paired: MappedRunes
  i = 0
  while i < numbered.runes.len:
    let r = numbered.runes[i]
    var stop = i + 1
    while stop < numbered.runes.len and numbered.runes[stop] == r: inc stop
    let count = stop - i
    if (r == Rune('.') or r == Rune(0x30FB)) and count >= 3:
      paired.groupMapped(numbered, i, stop, "……".toRunes)
    elif r == Rune(0x2026) or r in "―—─".toRunes or (r == Rune('-') and count >= 2):
      let mark = if r == Rune(0x2026): r else: Rune(0x2015)
      var pair: seq[Rune]
      for j in 0..<count + count mod 2: pair.add mark
      paired.groupMapped(numbered, i, stop, pair)
    else: paired.copyMapped(numbered, i, stop)
    i = stop
  var brackets: MappedRunes
  for i, r in paired.runes:
    if r == Rune(0x3002) and i + 1 < paired.runes.len and paired.runes[i + 1] in "」』".toRunes: continue
    brackets.copyMapped(paired, i, i + 1)
  var spaced: MappedRunes
  i = 0
  while i < brackets.runes.len:
    let r = brackets.runes[i]
    spaced.copyMapped(brackets, i, i + 1)
    let after = r in "！？".toRunes or (bang(r) and tcySecond(brackets.runes, i))
    inc i
    if after:
      var stop = i
      while stop < brackets.runes.len and brackets.runes[stop] in [Rune(' '), Rune(0x3000)]: inc stop
      if stop < brackets.runes.len and brackets.runes[stop] notin "\r\n」』）】〕］！？!?".toRunes:
        spaced.groupMapped(brackets, i - 1, stop, "　".toRunes)
        i = stop

  result.runes = spaced.runes
  result.origin = spaced.origin
  result.index = newSeq[int](source.len + 1)
  for i in 0..<source.len: result.index[i] = -1
  var filled, first = 0
  for i, origin in spaced.origin:
    if i == 0 or origin != spaced.origin[i - 1]: first = i
    for j in max(filled, origin)..<spaced.ends[i]: result.index[j] = first
    filled = max(filled, spaced.ends[i])
  result.index[source.len] = result.runes.len
  for i in countdown(source.high, 0):
    if result.index[i] < 0: result.index[i] = result.index[i + 1]

proc novelFormat*(text: string): string =
  ## Use the same mapped rewrite, preserving line separators verbatim.
  var line: seq[Rune]
  for r in text.runes:
    if r in [Rune(10), Rune(13)]:
      result.add $displayLine(line).runes
      result.add $r
      line.setLen(0)
    else: line.add r
  result.add $displayLine(line).runes

proc sourceCol*(line: DisplayLine, col: int): int =
  ## A display hit lands at its source group's start; EOF remains EOF.
  if col >= line.runes.len: line.index.high else: line.origin[max(0, col)]

proc stepSource*(line: DisplayLine, col, direction: int): int =
  ## Skip all source positions sharing the cursor's displayed group. Up from inside
  ## a group returns to its start before moving to the preceding group.
  let at = line.index[col]
  if direction > 0:
    result = col + 1
    while result < line.index.high and line.index[result] == at: inc result
    result = line.sourceCol(line.index[min(result, line.index.high)])
  elif col > 0:
    let start = line.sourceCol(at)
    if start < col: return start
    var previous = col - 1
    while previous > 0 and line.index[previous] >= at: dec previous
    result = line.sourceCol(line.index[previous])
  else: result = 0

proc displayRange*(line: DisplayLine, a, z: int): tuple[a, z: int] =
  ## Highlight every group touched by a source range, even a match entirely inside one.
  let first = clamp(a, 0, line.index.high)
  let stop = clamp(z, first, line.index.high)
  result = (line.index[first], line.index[stop])
  if stop > first and result.z < line.runes.len and line.origin[result.z] < stop:
    let origin = line.origin[result.z]
    while result.z < line.runes.len and line.origin[result.z] == origin: inc result.z
