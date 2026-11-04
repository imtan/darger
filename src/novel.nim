## Vertical writing for novel mode: columns with kinsoku, the scroll position counted in
## columns, the pixel grid, and the font's own vertical glyph table.
import std/[math, tables, unicode]
import buffer, wrap

const
  noColumnStart = "ーぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶ々ゝゞヽヾ〜…‥・：；！？!?,.，．）］｝〉》〕"
  noColumnEnd = "〈《〔［｛"
  rotatedForms = "ー〜…‥―—–‐～－＝｜＿「」『』（）［］｛｝〈〉《》〔〕【】＜＞"
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

proc advance(r: Rune): int =
  ## Cells a rune takes in a column: one, whatever its width; a combining mark none.
  if runeWidth(r) == 0: 0 else: 1

proc legalBreak(rs: seq[Rune], at: int): bool =
  legal(rs, at) and rs[at] notin noColumnStart.toRunes and rs[at - 1] notin noColumnEnd.toRunes

proc columns*(rs: seq[Rune], height: int): seq[ColumnSpan] =
  ## The columns of a line, each at most `height` cells. A column ending on a rune that
  ## must not be split from what follows gives that rune to the next column. A full last
  ## column is followed by an empty one, where the cursor at the end of the line goes.
  let height = max(1, height)
  var start, cells = 0
  while start < rs.len:
    var stop = start
    cells = 0
    while stop < rs.len and cells + advance(rs[stop]) <= height:
      cells += advance(rs[stop])
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
    result += advance(rs[i])
  if col < rs.len and advance(rs[col]) == 0: result = max(0, result - 1)

proc colAtCell*(rs: seq[Rune], span: ColumnSpan, cell: int, last: bool): int =
  ## The rune at a cell of a column. Past its end: the line's end in the last column,
  ## else the column's last rune (its end would already be the next column).
  var cells = 0
  for i in span.start..<span.stop:
    if cells == cell and advance(rs[i]) > 0: return i
    cells += advance(rs[i])
  if last: return span.stop
  result = max(span.start, span.stop - 1)
  while result > span.start and advance(rs[result]) == 0: dec result

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
