## Per-buffer novel mode: the novel font and, by default, vertical writing (columns right
## to left, characters top to bottom). Folds, inline pictures, review bands and paren
## highlights are not drawn in vertical panes yet.
import std/[math, os, sets, strutils, tables, unicode]
import windy, boxy, pixie, pixie/fontformats/opentype
import ../[core, buffer, lisp, syntax, render, olivetti, novel, skk, fontcatalog]
import fonts

type VerticalFace = object
  ## A font's vertical glyphs. Pixie keeps a typeface's tables private, so this is a parse
  ## of its file of our own; a font it cannot be read from has none (face nil).
  face: OpenType
  forms: Table[uint16, uint16]

const
  ideographicBaseline = 0.88    # of the em box from its top, in CJK fonts
  verticalPlane = 0x100000      # private runes standing for vertical glyphs: pixie reads
                                # outlines by rune only, so they go in our copy's cmap

var
  enabled: HashSet[Buffer]
  drawnVertical: HashSet[Buffer]  # their pane's `left` counts columns, not cells
  regular, bold: Font
  regularName, boldName = "\0"    # the settings the fonts were loaded for
  fontProblem: string             # why the novel font is not in use; "" = it is
  generation = 0                  # cache keys of the glyphs of older novel fonts are never reused
  verticalFaces: Table[string, VerticalFace]  # by font file
  recentreCycle = 0

proc setting(name: string): Value = interp.env.values.getOrDefault(name)

proc number(name: string, fallback, low, high: float): float =
  let v = setting(name)
  if v == nil or v.kind != vNumber: fallback else: clamp(v.asNumber, low, high)

proc text(name: string): string =
  let v = setting(name)
  if v != nil and v.kind == vString: expandTilde(v.str) else: ""

proc vertical(): bool =
  let v = setting("novel-vertical")
  v == nil or v.kind != vNil

proc isVertical(buf: Buffer): bool = buf in enabled and vertical()

proc tryFont(path: string, problem: var string): Font =
  try: result = loadFont(path)
  except CatchableError as e: problem = path & ": " & e.msg

proc syncFonts() =
  ## Loads the fonts the settings name, when they changed. Without them the mode goes on
  ## with the usual fonts and fontProblem says why.
  let regularWanted = text("novel-font")
  let boldWanted = text("novel-bold-font")
  if regularWanted == regularName and boldWanted == boldName: return
  (regularName, boldName) = (regularWanted, boldWanted)
  inc generation
  let dirs = fontSearchDirs()
  regular = nil
  bold = nil
  fontProblem = ""
  let path = findFont(regularWanted, dirs)
  if path.len == 0:
    fontMissing(regularWanted)
    fontProblem = (if regularWanted.len > 0: regularWanted else: "novel-font") & " not found"
  else:
    regular = tryFont(path, fontProblem)
  if regular != nil:
    var ignored: string
    let boldPath = findFont(boldWanted, dirs)
    if boldPath.len > 0: bold = tryFont(boldPath, ignored)

proc fontNote(): string =
  if fontProblem.len > 0: " (normal fonts: " & fontProblem & fontHint(regularName) & ")" else: ""

proc gridOf(r: Renderer, w, h: int): Grid =
  let em = 16 * r.scale.float * number("novel-font-scale", 1.25, 0.5, 4)
  gridFor(w * r.cellW, max(1, h - 1) * r.cellH, em, number("novel-column-spacing", 1.7, 1, 4))

proc verticalFace(typeface: Typeface): VerticalFace =
  if typeface.filePath in verticalFaces: return verticalFaces[typeface.filePath]
  try:
    if typeface.filePath.len > 0:
      let buf = readFile(typeface.filePath)
      let face = if typeface.filePath.toLowerAscii.endsWith(".ttc"): parseOpenTypeCollection(buf)[0]
                 else: parseOpenType(buf)
      if "GSUB" in face.tableRecords:
        result = VerticalFace(face: face, forms: vertGlyphs(buf, face.tableRecords["GSUB"].offset.int))
  except CatchableError: discard
  verticalFaces[typeface.filePath] = result

proc verticalPath(typeface: Typeface, rune: Rune): Path =
  ## The outline of rune's vertical glyph in this font, nil when it has none.
  if int(rune) < 0x80: return nil
  let vertical = verticalFace(typeface)
  if vertical.face == nil: return nil
  let form = vertical.forms.getOrDefault(vertical.face.cmap.runeToGlyphId.getOrDefault(rune))
  if form == 0: return nil
  let stand = Rune(verticalPlane + form.int)
  vertical.face.cmap.runeToGlyphId[stand] = form
  result = newPath()
  result.addPath(vertical.face.getGlyphPath(stand))  # a copy: the face keeps its own

proc columnGlyph(r: Renderer, rune: Rune, x, y, cell: int, tint: Color, wantBold: bool) =
  ## A rune in a square cell at window pixel x, y: the font's vertical glyph if it has
  ## one, else rotated or moved by verticalForm. Half-width runes stand upright, centred
  ## across the column, one to a cell.
  let code = int(rune)
  if rune in [Rune(9), Rune(32)] or code in 0x200B..0x200D or code in 0xFE00..0xFE0F or
      code in 0xE0100..0xE01EF: return
  var font: Font
  var index = -3
  if wantBold and bold != nil and bold.typeface.hasGlyph(rune): (font, index) = (bold, -2)
  elif regular != nil and regular.typeface.hasGlyph(rune): (font, index) = (regular, -1)
  else:
    for i, candidate in r.fonts:
      if candidate.typeface.hasGlyph(rune):
        (font, index) = (candidate, i)
        break
  let key = "nv" & $generation & ":" & $cell & ":" & $index & ":" & $code
  if key notin r.glyphs:
    let img = newImage(cell, cell)
    let size = cell.float32
    if font == nil:
      let path = newPath()
      path.rect(1, 1, size - 2, size - 2)
      img.strokePath(path, color(1, 1, 1, 1), strokeWidth = 1)
    else:
      let typeface = font.typeface
      let s = size / typeface.scale
      let width = typeface.getAdvance(rune) * s
      let baseline = size * ideographicBaseline
      let form = verticalPath(typeface, rune)
      let path = if form != nil: form else: typeface.getGlyphPath(rune)
      path.transform(scale(vec2(s)))
      let shape = if form != nil: vfUpright else: verticalForm(rune)
      let upright = translate(vec2((size - width) / 2, baseline))
      let placed = case shape
        of vfRotate: translate(vec2(size / 2, size / 2)) * rotate(PI.float32 / 2) *
          translate(vec2(-width / 2, baseline - size / 2))
        of vfCorner: translate(vec2(size * 0.6, -size * 0.6)) * upright
        of vfSmall: translate(vec2(size * 0.12, -size * 0.12)) * upright
        of vfUpright: upright
      img.fillPath(path, color(1, 1, 1, 1), placed)
    r.gpu.addImage(key, img)
    r.glyphs.incl key
  r.gpu.drawImage(key, vec2(x.float32, y.float32), tint)

proc rowGlyph(r: Renderer, rune: Rune, x, y: int, tint: Color, wantBold: bool): bool =
  ## A rune of a horizontal novel pane in the novel font, on the usual font's baseline;
  ## proportional Latin wider than its cell is narrowed to fit. False for the usual fonts.
  let font = if wantBold and bold != nil and bold.typeface.hasGlyph(rune): bold else: regular
  let cells = runeWidth(rune)
  if cells == 0 or not font.typeface.hasGlyph(rune): return false
  let key = "nh" & $generation & ":" & $r.cellW & "x" & $r.cellH & ":" &
    (if font == bold: "B:" else: "R:") & $int(rune)
  if key notin r.glyphs:
    let img = newImage(r.cellW * cells, r.cellH)
    let typeface = font.typeface
    let s = 16 * r.scale / typeface.scale
    let width = typeface.getAdvance(rune) * s
    let squeeze = min(1'f32, img.width.float32 / max(1'f32, width))
    let primary = r.fonts[0]
    let path = typeface.getGlyphPath(rune)
    path.transform(scale(vec2(s)))
    img.fillPath(path, color(1, 1, 1, 1),
      translate(vec2((img.width.float32 - width * squeeze) / 2, primary.typeface.ascent * primary.scale)) *
      scale(vec2(squeeze, 1)))
    r.gpu.addImage(key, img)
    r.glyphs.incl key
  r.gpu.drawImage(key, vec2(x.float32, y.float32), tint)
  true

proc drawVertical(r: Renderer, window: Window, p: var PaneView, composition: seq[Rune],
                  imeCursor: int, textCursor: bool) =
  let b = p.b
  let showCursor = p.active and textCursor
  let comp = if showCursor: composition else: @[]
  let cursor = if p.active: b.cursor else: p.cursor
  let g = r.gridOf(p.w, p.h)
  var spansOf: Table[int, seq[ColumnSpan]]
  proc display(line: int): seq[Rune] =
    if line == cursor.line: displayLine(b.lines[line], comp, cursor.col) else: b.lines[line]
  proc spans(line: int): seq[ColumnSpan] =
    if line notin spansOf: spansOf[line] = columns(display(line), g.rows)
    spansOf[line]
  let count: Counter = proc(line: int): int = spans(line).len
  let caret = cursor.col + (if comp.len > 0: imeCursor else: 0)
  let cursorRunes = display(cursor.line)
  let cursorColumn = columnOf(spans(cursor.line), caret)
  let anchor = scrollToShow(count, b.lines.len, (p.top, p.left), (cursor.line, cursorColumn), g.columns)
  p.top = anchor.line
  p.left = anchor.column
  let originX = r.cellX(0)
  let originY = r.rowY(0) + g.inset
  let cursorCell = cellOf(cursorRunes, spans(cursor.line)[cursorColumn], caret)
  let selection = if p.active and b.regionActive: b.region else: (a: -1, z: -1)
  var cursorPixel = ivec2(-1, -1)
  var column = 0
  var line = anchor.line
  var offset = b.offset((line, 0))
  while line < b.lines.len and column < g.columns:
    let rs = display(line)
    let spansHere = spans(line)
    let faces = if line < p.faces.len: p.faces[line] else: @[]
    let bolds = if line < p.bolds.len: p.bolds[line] else: @[]
    let marks = if line < p.marks.len: p.marks[line] else: @[]
    let compAt = if line == cursor.line and comp.len > 0: cursor.col else: -1
    for k in (if line == anchor.line: anchor.column else: 0)..spansHere.high:
      if column >= g.columns: break
      let x = originX + g.columnLeft(column)
      let onCursor = showCursor and line == cursor.line and k == cursorColumn
      if onCursor: cursorPixel = ivec2(x.int32, (originY + cursorCell * g.cell).int32)
      for pass in 0..1:
        var cell = 0
        for i in spansHere[k].start..<spansHere[k].stop:
          let width = runeWidth(rs[i])
          let at = if width == 0: max(0, cell - 1) else: cell
          let y = originY + at * g.cell
          let composing = compAt >= 0 and i >= compAt and i < compAt + comp.len
          let original = if compAt >= 0 and i >= compAt + comp.len: i - comp.len else: i
          let place = offset + original
          let matched = not composing and p.matchStart >= 0 and place >= p.matchStart and
            place < p.matchStart + p.matchLen
          let underCursor = onCursor and at == cursorCell
          if pass == 0:
            let box = rect(x.float32, y.float32, g.cell.float32, g.cell.float32)
            if composing or (place >= selection.a and place < selection.z):
              r.gpu.drawRect(box, theme.region)
            if matched: r.gpu.drawRect(box, theme.search)
          else:
            let face = if composing or original >= faces.len: fPlain else: faces[original]
            r.columnGlyph(rs[i], x, y, g.cell,
              if underCursor: theme.bg elif matched: theme.searchFg else: faceColor(face, theme.fg),
              not composing and original < bolds.len and bolds[original] == 1)
            let mark = if composing or original >= marks.len: 0'i8 else: marks[original]
            if mark in 1'i8..5'i8:  # an underline goes down the right of the column
              r.gpu.drawRect(rect((x + g.cell + 1).float32, y.float32, 2, g.cell.float32),
                if mark == 5: faceColor(face, theme.fg) else: [theme.err, theme.warn, theme.info, theme.hint][mark - 1])
          if width > 0: inc cell
        if pass == 0 and onCursor:
          r.gpu.drawRect(rect(cursorPixel.x.float32, cursorPixel.y.float32, g.cell.float32, g.cell.float32), theme.cursor)
      inc column
    offset += b.lines[line].len + 1
    inc line
  when defined(windows) or defined(macosx):
    if cursorPixel.x >= 0: window.imePos = ivec2(cursorPixel.x, cursorPixel.y + g.cell.int32)
  if p.box.lines.len > 0 and cursorPixel.x >= 0:
    # A completion or SKK's candidates hang from the cursor, on the frame's own cell grid.
    r.cursorBox(p.box.lines, p.box.selected, (cursorPixel.x.int - originX) div r.cellW,
      (cursorPixel.y.int + g.cell - 1 - r.rowY(0)) div r.cellH, p.box.maxRows, p.box.top, p.box.tags,
      p.box.details)
  r.band(r.rows, if p.active: theme.modeLine else: theme.popup)
  r.status(window, p.modeLine, r.rows, tint = if p.active: theme.modeLineFg else: theme.label)

proc selectedGrid(): Grid = renderer.gridOf(pane.w, pane.h)

proc moveByColumns(delta: int) =
  ## Left / Right: the next / previous column, keeping the place in it.
  echoLine = ""
  let (point, goal) = moveColumn(core.b.lines, selectedGrid().rows, core.b.cursor, delta, core.b.goal)
  core.b.cursor = point
  core.b.goal = goal
  core.b.last = "move"

proc pageColumns(direction: int) =
  ## C-v / M-v: a screen of columns, less two kept for context.
  let g = selectedGrid()
  let count = counter(core.b.lines, g.rows)
  let lineCount = core.b.lines.len
  let anchor = clampSpot(count, lineCount, (renderer.top, renderer.left))
  let last: Spot = (lineCount - 1, count(lineCount - 1) - 1)
  if direction > 0 and distance(count, anchor, last, g.columns) < g.columns:
    echoLine = "End of buffer"
    return
  if direction < 0 and anchor == (0, 0):
    echoLine = "Beginning of buffer"
    return
  let delta = direction * max(1, g.columns - 2)
  moveByColumns(delta)
  let moved = stepSpot(count, lineCount, anchor, delta)
  renderer.top = moved.line
  renderer.left = moved.column

proc recentreColumns() =
  ## C-l: the cursor's column in the middle, then rightmost, then leftmost.
  let g = selectedGrid()
  let back = case recentreCycle
    of 0: g.columns div 2
    of 1: 0
    else: g.columns - 1
  let moved = stepSpot(counter(core.b.lines, g.rows), core.b.lines.len,
    spotOf(core.b.lines, g.rows, core.b.cursor), -back)
  renderer.top = moved.line
  renderer.left = moved.column
  recentreCycle = (recentreCycle + 1) mod 3

proc wheelColumns(p: Pane, buf: Buffer, delta: int) =
  ## A wheel notch moves a column; the cursor follows to stay on screen, as mwheel-scroll does.
  let g = renderer.gridOf(p.w, p.h)
  let count = counter(buf.lines, g.rows)
  let anchor = clampSpot(count, buf.lines.len, if p == pane: (renderer.top, renderer.left) else: (p.top, p.left))
  let last: Spot = (buf.lines.high, count(buf.lines.high) - 1)
  if delta > 0 and distance(count, anchor, last, g.columns) < g.columns: return
  let moved = stepSpot(count, buf.lines.len, anchor, delta)
  var cursor = if p == pane: buf.cursor else: p.cursor
  cursor.line = min(cursor.line, buf.lines.high)
  cursor.col = min(cursor.col, buf.lines[cursor.line].len)
  let spot = spotOf(buf.lines, g.rows, cursor)
  if spot < moved: cursor = pointAtCell(buf.lines, g.rows, moved, 0, 0)
  elif distance(count, moved, spot, g.columns) >= g.columns:
    cursor = pointAtCell(buf.lines, g.rows, moved, g.columns - 1, 0)
  if p == pane:
    (renderer.top, renderer.left) = moved
    buf.cursor = cursor
    buf.goal = -1
  else:
    (p.top, p.left) = moved
    p.cursor = cursor

paneHooks.add proc(r: Renderer, window: Window, p: var PaneView, composition: seq[Rune],
                   imeCursor: int, textCursor: bool): bool =
  let wanted = p.b in enabled
  if wanted: syncFonts()
  if wanted and vertical():
    drawnVertical.incl p.b
    r.drawVertical(window, p, composition, imeCursor, textCursor)
    return true
  if p.b in drawnVertical:  # back to rows: `left` counted columns
    drawnVertical.excl p.b
    p.left = 0
  if wanted and regular != nil:
    r.glyphHook = proc(rune: Rune, x, y: int, tint: Color, wantBold: bool): bool =
      r.rowGlyph(rune, x, y, tint, wantBold)

keyFilters.add proc(c: string): bool =
  ## Arrows follow the writing direction: Down / Up along the text, Left / Right across
  ## the columns. SKK's candidates keep their keys.
  if c != "C-l": recentreCycle = 0
  if mode.len > 0 or prefix.len > 0 or not isVertical(core.b) or inputMethod.composing: return false
  result = true
  case c
  of "down": discard runCommand("forward")
  of "up": discard runCommand("backward")
  of "left": moveByColumns(1)
  of "right": moveByColumns(-1)
  of "C-v", "pagedown": pageColumns(1)
  of "M-v", "pageup": pageColumns(-1)
  of "C-l": recentreColumns()
  else: result = false

mouseFilters.add proc(p: Pane, cx, cy, button: int, pressed: bool): bool =
  let buf = if p == pane: core.b else: p.buf
  if not isVertical(buf) or cy - p.y >= p.h - 1: return false
  result = true
  if button in [64, 65]:
    wheelColumns(p, buf, if button == 65: 1 else: -1)
  elif button == 0 and pressed:
    if p != pane: selectPane(p)
    renderer.setPane(p.x, p.y, p.w, p.h)
    let g = renderer.gridOf(p.w, p.h)
    # In window pixels: the columns and cells do not fall on the frame's cell grid.
    let at = window.mousePos
    let column = min(g.columnAtX(at.x.int - renderer.cellX(0)), g.columns - 1)
    let cell = g.cellAtY(at.y.int - renderer.rowY(0))
    let anchor = clampSpot(counter(core.b.lines, g.rows), core.b.lines.len, (renderer.top, renderer.left))
    core.b.cursor = pointAtCell(core.b.lines, g.rows, anchor, column, cell)
    core.b.regionActive = false
    core.b.goal = -1
    moveDirection = 0

marginProviders.add proc(buf: Buffer, paneWidth: int): int =
  if buf in enabled and not vertical():
    olivettiMargin(paneWidth, 0, number("novel-body-width", 80, 1, 1000).int)
  else: 0

noGutter.add proc(buf: Buffer): bool = buf in enabled

modeNameProviders.add proc(buf: Buffer): string =
  if buf in enabled: (if vertical(): "Novel縦" else: "Novel") else: ""

interp.defPrimitive("novel-mode", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if core.b in enabled:
    enabled.excl core.b
    echoLine = "Novel off"
  else:
    enabled.incl core.b
    syncFonts()
    echoLine = "Novel on" & fontNote()
  nilValue())

visitHooks.add proc() =
  let languages = setting("novel-languages")
  var wanted = false
  if languages != nil and languages.kind != vNil:
    for language in languages.asList:
      if language.asString == langOf(core.b).name: wanted = true
  let suffixes = setting("novel-file-suffixes")
  if suffixes != nil and suffixes.kind != vNil:
    for suffix in suffixes.asList:
      if core.b.path.endsWith(suffix.asString): wanted = true
  if wanted:
    enabled.incl core.b
    syncFonts()
    if fontProblem.len > 0: echoLine = "Novel" & fontNote()

killHooks.add proc(buf: Buffer) =
  enabled.excl buf
  drawnVertical.excl buf

defaults.add """
(setq novel-font "RinMincho-Regular.ttf")
(setq novel-bold-font "RinMincho-Bold.ttf")
(setq novel-vertical t)
(setq novel-column-spacing 1.7)
(setq novel-font-scale 1.25)
(setq novel-body-width 80)
(setq novel-languages nil)
(setq novel-file-suffixes nil)
"""

fontInstalledHooks.add proc(font: CatalogFont) =
  regularName = "\0"
  boldName = "\0"
