import std/[os, unicode, sets, tables, math, strutils]
import windy, boxy, pixie, opengl
import buffer, syntax
when not defined(windows) and not defined(macosx): import std/osproc

type
  Renderer* = ref object
    gpu: Boxy
    fonts: seq[Font]
    chosen: Table[int, int]
    glyphs: HashSet[string]
    scale: float32
    zoom*: float32
    lastTitle: string
    pad, areaW: int
    cellW*, cellH*, rows*, cols*, top*, left*: int
    candTop: int  # first candidate row shown in the popup
  Anchor* = enum atTop, atBottom
  CursorBox* = object   ## a completion or hover box hanging from a buffer position
    lines*, tags*, details*: seq[string]  # tags / details: one per line, or none
    selected*, top*: int  # selected -1 = none; top: the first line shown
    line*, cell*: int     # the buffer line and cell the box hangs from
    maxRows*: int
  Theme* = object
    bg*, fg*, cursor*, region*, modeLine*, modeLineFg*, search*, searchFg*, border*,
      label*, popup*, paren*, lineNo*, lineNoNow*: Color
    comment*, str*, keyword*, fnname*, variable*, typ*, constant*, builtin*: Color
    review*: array[5, Color]  # bg, removed, added, removed-refine, added-refine
    err*, warn*, info*, hint*: Color  # diagnostic underlines

proc hex(s: string): Color = parseHtmlColor(s).color

let themes = {
  "modus-vivendi": Theme(bg: hex"#000000", fg: hex"#ffffff", cursor: hex"#ffffff",
    region: hex"#5a5a5a", modeLine: hex"#505050", modeLineFg: hex"#ffffff",
    search: hex"#7a6100", searchFg: hex"#ffffff", border: hex"#646464",
    label: hex"#989898", popup: hex"#1e1e1e", paren: hex"#2f7f9f",
    lineNo: hex"#535353", lineNoNow: hex"#ffffff",
    comment: hex"#989898", str: hex"#79a8ff", keyword: hex"#b6a0ff", fnname: hex"#feacd0",
    variable: hex"#00d3d0", typ: hex"#6ae4b9", constant: hex"#00bcff", builtin: hex"#f78fe7",
    review: [hex"#000000", hex"#4f1119", hex"#00381f", hex"#781a1f", hex"#034f2f"],
    err: hex"#ff5f59", warn: hex"#d0bc00", info: hex"#2fafff", hint: hex"#989898"),
  "catppuccin": Theme(bg: hex"#1e1e2e", fg: hex"#cdd6f4", cursor: hex"#f5e0dc",
    region: hex"#45475a", modeLine: hex"#313244", modeLineFg: hex"#cdd6f4",
    search: hex"#f9e2af", searchFg: hex"#1e1e2e", border: hex"#585b70",
    label: hex"#a6adc8", popup: hex"#313244", paren: hex"#585b70",
    lineNo: hex"#45475a", lineNoNow: hex"#b4befe",
    comment: hex"#6c7086", str: hex"#a6e3a1", keyword: hex"#cba6f7", fnname: hex"#89b4fa",
    variable: hex"#b4befe", typ: hex"#f9e2af", constant: hex"#fab387", builtin: hex"#f38ba8",
    review: [hex"#1e1e2e", hex"#512e3a", hex"#294638", hex"#784452", hex"#3e6950"],
    err: hex"#f38ba8", warn: hex"#f9e2af", info: hex"#89b4fa", hint: hex"#6c7086")}.toTable
var theme* = themes["modus-vivendi"]

proc setTheme*(name: string): bool =
  result = name in themes
  if result: theme = themes[name]

when not defined(windows) and not defined(macosx):
  proc fcMatch(pattern: string): string =
    try:
      # Keep stderr out: fontconfig warnings would corrupt the path.
      let (o, c) = execCmdEx("fc-match -f '%{file}' " & quoteShell(pattern), {poUsePath})
      if c == 0 and fileExists(o.strip): result = o.strip
    except CatchableError: discard

proc iosevka(dir: string): seq[string] =
  for weight in ["ExtraLight", "Light", "Regular"]:
    result.add dir / ("IosevkaNerdFontMono-" & weight & ".ttf")

proc newRenderer*(): Renderer =
  result = Renderer(zoom: 1)
  var paths: seq[string]
  let primary = getEnv("DARGER_FONT")
  if primary.len > 0: paths.add primary
  when defined(windows):
    paths.add iosevka(getEnv("LOCALAPPDATA") / "Microsoft/Windows/Fonts")
    paths.add iosevka("C:/Windows/Fonts")
    paths.add @[getEnv("LOCALAPPDATA") / "Microsoft/Windows/Fonts/HackGenConsoleNF-Regular.ttf",
      "C:/Windows/Fonts/CascadiaMono.ttf", "C:/Windows/Fonts/consola.ttf",
      "C:/Windows/Fonts/cour.ttf"]
  else:
    when defined(macosx): paths.add iosevka(getHomeDir() / "Library/Fonts")
    else:
      paths.add iosevka("/usr/share/fonts/TTF")
      paths.add iosevka(getHomeDir() / ".local/share/fonts")
    paths.add @["/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
      "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
      "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
      "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
      "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
      "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
      "/usr/share/fonts/liberation-mono-fonts/LiberationMono-Regular.ttf",
      "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
      "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
      "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
      "/System/Library/Fonts/Menlo.ttc", "/Library/Fonts/Menlo.ttf"]
  proc load(path: string): Font =
    try:
      # readTypeface rejects .ttc; readTypefaces parses ttcf directory offsets.
      if path.toLowerAscii.endsWith(".ttc"):
        let faces = readTypefaces(path)
        if faces.len == 0: raise newException(IOError, "Empty font collection")
        result = newFont(faces[0])
      else: result = readFont(path)
      result.paint = color(1, 1, 1, 1)
    except CatchableError as e:
      stderr.writeLine("Skipping font " & path & ": " & e.msg)
  # File names of loaded default fonts, so distro and fc-match duplicates load once.
  var loaded: HashSet[string]
  for path in paths:
    if not fileExists(path) and path != primary: continue
    let font = load(path)
    if font != nil:
      result.fonts.add font
      loaded.incl extractFilename(path)
      break
  when not defined(windows) and not defined(macosx):
    if result.fonts.len == 0:
      let path = fcMatch("monospace:spacing=mono")
      let font = if path.len > 0: load(path) else: nil
      if font != nil:
        result.fonts.add font
        loaded.incl extractFilename(path)
  if result.fonts.len == 0:
    raise newException(IOError, "Set DARGER_FONT to a readable monospace font")
  let fallbacks = getEnv("DARGER_FALLBACK_FONTS")
  if fallbacks.len > 0: paths = fallbacks.split(';')
  else:
    when defined(windows):
      paths = @["C:/Windows/Fonts/BIZ-UDGothicR.ttc", "C:/Windows/Fonts/YuGothM.ttc",
        "C:/Windows/Fonts/msgothic.ttc", "C:/Windows/Fonts/malgun.ttf",
        "C:/Windows/Fonts/seguiemj.ttf", "C:/Windows/Fonts/seguisym.ttf"]
    else:
      # No colour emoji: pixie rejects CBDT and sbix.
      paths = @["/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/google-noto-sans-cjk-fonts/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
        "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"]
      when not defined(macosx):
        # %{file} only: the TTC face index would pick a Korean face; lang=ja matches non-CJK fonts.
        paths.add fcMatch("monospace:charset=3042 6f22")
        paths.add fcMatch("monospace:charset=d55c")
  for entry in paths:
    let path = entry.strip
    if path.len == 0 or (fallbacks.len == 0 and not fileExists(path)): continue
    if fallbacks.len == 0 and extractFilename(path) in loaded: continue
    let font = load(path)
    if font != nil:
      result.fonts.add font
      loaded.incl extractFilename(path)
  loadExtensions()
  result.gpu = newBoxy()

proc envScale(name: string): float32 =
  try:
    let v = parseFloat(getEnv(name))
    if v.classify == fcNormal and v > 0 and v < 16: return v.float32
  except ValueError: discard

proc uiScale(window: Window): float32 =
  let forced = envScale("DARGER_SCALE")
  if forced > 0: return forced
  result = window.contentScale
  when defined(linux):
    # XWayland with zero scaling reports 1.0 on HiDPI; GDK_SCALE carries the real factor.
    if result == 1:
      let g = envScale("GDK_SCALE")
      if g > 0: result = g

proc resize*(r: Renderer, window: Window, b: Buffer) =
  let ui = window.uiScale
  let scale = ui * r.zoom
  if r.scale != scale:
    for key in r.glyphs: r.gpu.removeImage(key)
    r.glyphs.clear()
    r.scale = scale
    for font in r.fonts: font.size = 16 * r.scale
    let primary = r.fonts[0]
    r.cellW = max(1, int(ceil(primary.typeface.getAdvance(Rune(77)) * primary.scale)))
    r.cellH = max(1, int(ceil(primary.typeface.lineHeight * primary.scale)))
    b.goal = -1
  # Like Emacs' internal-border-width, the border ignores text zoom; small windows shrink it.
  let w = window.size.x.int
  let h = window.size.y.int
  r.pad = max(0, min(int(round(32 * ui)), min((w - r.cellW) div 2, (h - 3 * r.cellH) div 2)))
  r.areaW = max(0, w - 2 * r.pad)
  r.rows = max(1, (h - 2 * r.pad) div r.cellH - 2)
  r.cols = max(1, r.areaW div r.cellW)

proc glyph(r: Renderer, rune: Rune, x, y: int, tint: Color) =
  if rune in [Rune(9), Rune(32)]: return
  let code = int(rune)
  # ponytail: no shaping; ZWJ, flag and keycap sequences render as their parts.
  if code in 0x200B..0x200D or code in 0xFE00..0xFE0F or code in 0xE0100..0xE01EF: return
  if code notin r.chosen:
    r.chosen[code] = -1
    for i, font in r.fonts:
      if font.typeface.hasGlyph(rune):
        r.chosen[code] = i
        break
  let index = r.chosen[code]
  let key = "g" & $index & ":" & $code
  if key notin r.glyphs:
    let cells = runeWidth(rune)
    let img = newImage(r.cellW * max(1, cells), r.cellH)
    if index >= 0:
      let font = r.fonts[index]
      let primary = r.fonts[0]
      let ascent = font.typeface.ascent * font.scale
      let baselineOffset = primary.typeface.ascent * primary.scale - ascent
      let path = font.typeface.getGlyphPath(rune)
      path.transform(scale(vec2(font.scale)))
      let bounds = path.computeBounds()
      let xOffset = if cells == 0: (img.width.float32 - bounds.w) / 2 - bounds.x
                    elif cells == 2: (img.width.float32 - font.typeface.getAdvance(rune) * font.scale) / 2
                    else: 0'f32
      # Glyph paths use baseline zero; the cell image clips taller fallback outlines.
      img.fillPath(path, color(1, 1, 1, 1), translate(vec2(xOffset, ascent + baselineOffset)))
    else:
      let path = newPath()
      path.rect(1, 3, (img.width - 2).float32, (img.height - 6).float32)
      img.strokePath(path, color(1, 1, 1, 1), strokeWidth = 1)
    r.gpu.addImage(key, img)
    r.glyphs.incl key
  r.gpu.drawImage(key, vec2((x + r.pad).float32, (y + r.pad).float32), tint)

proc fill(r: Renderer, cell, row, count: int, c: Color) =
  r.gpu.drawRect(rect((r.pad + cell * r.cellW).float32, (r.pad + row * r.cellH).float32,
    (count * r.cellW).float32, r.cellH.float32), c)

proc band(r: Renderer, row: int, c: Color) =
  ## A full-width row of the text area, including the part right of the last cell.
  r.gpu.drawRect(rect(r.pad.float32, (r.pad + row * r.cellH).float32,
    r.areaW.float32, r.cellH.float32), c)

proc cursorSpan(line: seq[Rune], col: int): tuple[cell, width: int] =
  result.cell = cellCol(line, col)
  let width = if col < line.len: cellWidth(line[col], result.cell) else: 1
  if width == 0: result.cell = max(0, result.cell - 1)
  result.width = max(1, width)

proc imeRuneCol(composition: seq[Rune], index: int): int =
  # Windy's Windows IME cursor index counts UTF-16 code units, not Unicode scalars.
  var units = 0
  for rune in composition:
    let count = if int(rune) > 0xFFFF: 2 else: 1
    if units + count > index: break
    units += count
    inc result

proc displayLine(line, composition: seq[Rune], cursor: int): seq[Rune] =
  if cursor >= 0 and composition.len > 0:
    line[0..<cursor] & composition & line[cursor..<line.len]
  else: line

proc faceColor(f: Face, tint: Color): Color =
  case f
  of fPlain: tint
  of fComment: theme.comment
  of fString: theme.str
  of fKeyword: theme.keyword
  of fFnname: theme.fnname
  of fVariable: theme.variable
  of fType: theme.typ
  of fConstant: theme.constant
  of fBuiltin: theme.builtin

proc drawLine(r: Renderer, line: seq[Rune], row, scroll: int, cursor = -1,
              selectionStart = -1, selectionEnd = -1, matchStart = -1, matchEnd = -1,
              composition: seq[Rune] = @[], imeCursor = 0,
              x0 = 0, width = -1, tint = theme.fg, faces: seq[Face] = @[],
              marks: seq[int8] = @[], paren = [-1, -1]) =
  let visible = if width < 0: r.cols else: width
  let rs = displayLine(line, composition, cursor)
  let caret = if composition.len > 0 and cursor >= 0: cursor + imeCursor else: cursor
  let span = if caret >= 0: cursorSpan(rs, caret) else: (-1, 0)
  # Paint backgrounds before glyphs so zero-width marks do not erase their base.
  for pass in 0..1:
    var cell = 0
    for i in 0..rs.len:
      let rune = if i < rs.len: rs[i] else: Rune(32)
      let width = cellWidth(rune, cell)
      let at = if width == 0: max(0, cell - 1) else: cell
      let size = max(1, width)
      let composing = cursor >= 0 and i >= cursor and i < cursor + composition.len
      let original = if cursor >= 0 and i >= cursor + composition.len: i - composition.len else: i
      let selected = not composing and original >= selectionStart and original < selectionEnd
      let matched = not composing and original >= matchStart and original < matchEnd
      let underCursor = caret >= 0 and at < span.cell + span.width and at + size > span.cell
      # The popup has a frame, so wide runes cut by its edges are skipped.
      let shown = if width < 0: at + size > scroll and at < scroll + visible
        else: at >= scroll and at + size <= scroll + visible
      if shown:
        if pass == 0:
          if selected or composing: r.fill(x0+at-scroll, row, size, theme.region)
          if matched: r.fill(x0+at-scroll, row, size, theme.search)
          if not composing and original in paren: r.fill(x0+at-scroll, row, size, theme.paren)
        else:
          let face = if composing or original >= faces.len: fPlain else: faces[original]
          r.glyph(rune, (x0+at-scroll)*r.cellW, row*r.cellH,
            if underCursor: theme.bg elif matched: theme.searchFg else: faceColor(face, tint))
          let mark = if composing or original >= marks.len: 0'i8 else: marks[original]
          if mark in 1'i8..4'i8:  # a diagnostic: 2 px underline at the bottom of the cell
            r.gpu.drawRect(rect((r.pad + (x0+at-scroll)*r.cellW).float32,
              (r.pad + (row+1)*r.cellH - 2).float32, (size*r.cellW).float32, 2),
              [theme.err, theme.warn, theme.info, theme.hint][mark - 1])
      cell += width
    if pass == 0 and caret >= 0: r.fill(x0+span.cell-scroll, row, span.width, theme.cursor)

proc status(r: Renderer, window: Window, text: string, row: int, cursor = -1,
            composition: seq[Rune] = @[], imeCursor = 0, x0 = 0, width = -1, tint = theme.fg) =
  let visible = if width < 0: r.cols else: width
  var scroll = 0
  if cursor >= 0:
    let span = cursorSpan(displayLine(text.toRunes, composition, cursor), cursor + imeCursor)
    scroll = max(0, span.cell + span.width - visible)
    when defined(windows) or defined(macosx):
      window.imePos = ivec2((r.pad + (x0+span.cell-scroll)*r.cellW).int32,
        (r.pad + (row+1)*r.cellH).int32)
  r.drawLine(text.toRunes, row, scroll, cursor, composition = composition, imeCursor = imeCursor,
    x0 = x0, width = width, tint = tint)

proc fitCells(s: string, width: int): seq[Rune] =
  ## s cut to width cells, ending in "…" when cut.
  result = s.toRunes
  if cellCol(result, result.len) <= width: return
  var cells, n = 0
  while n < result.len and cells + cellWidth(result[n], cells) <= width - 1:
    cells += cellWidth(result[n], cells)
    inc n
  result = result[0..<n] & Rune(0x2026)

proc popupFit(r: Renderer): int =
  ## Candidate rows the popup has room for, leaving a few text rows visible
  ## beside it; 0 when not even 2 fit (the bottom-line prompt is used instead).
  if r.rows >= 6: min(10, max(2, r.rows - 7)) else: 0

proc popupShown*(r: Renderer, candidates: int): int =
  ## Candidate rows the popup lists.
  min(candidates, r.popupFit)

proc popupRows*(r: Renderer, candidates: int, anchor: Anchor): tuple[top, bottom: int] =
  ## Whole rows the popup frame covers: label, input and candidates plus a margin
  ## row above and below. The top box may cover the mode line, never the echo line.
  ## The bottom box sits on the last text row and keeps its full height, so the
  ## preview above it does not shift while the list is filtered.
  let fit = r.popupFit
  if fit == 0: return (r.rows, r.rows)
  if anchor == atBottom: (r.rows - 4 - fit, r.rows - 1)
  else: (1, 4 + min(candidates, fit))

proc popupBox(r: Renderer, window: Window, label: seq[Rune], text: string, cursor: int,
              composition: seq[Rune], imeCursor: int, candidates: openArray[string],
              selected: int, listed: bool, anchor: Anchor) =
  # Floating minibuffer: label row at y0, input row below, then the candidate
  # rows, in a theme.border frame covering popupRows.
  let count = if listed: $(selected + 1) & "/" & $candidates.len else: ""
  let reserve = if listed: count.len + 2 else: 0
  let w = min(max(clamp(r.cols - 6, 24, 80), cellCol(label, label.len) + reserve), r.cols - 2)
  let x0 = (r.cols - w) div 2
  let box = r.popupRows(candidates.len, anchor)
  let y0 = box.top + 1
  let shown = r.popupShown(candidates.len)
  let fx = (r.pad + (x0 - 1) * r.cellW).float32
  let fy = (r.pad + (y0 - 1) * r.cellH).float32
  let fw = ((w + 2) * r.cellW).float32
  let fh = ((box.bottom - box.top + 1) * r.cellH).float32
  r.gpu.drawRect(rect(fx - 2, fy - 2, fw + 4, fh + 4), theme.border)
  r.gpu.drawRect(rect(fx, fy, fw, fh), theme.popup)
  r.drawLine(label, y0, 0, x0 = x0, width = max(0, w - reserve), tint = theme.label)
  if listed and count.len <= w:
    r.drawLine(count.toRunes, y0, 0, x0 = x0 + w - count.len, width = count.len, tint = theme.label)
  r.status(window, text, y0 + 1, cursor, composition, imeCursor, x0 = x0, width = w)
  if shown == 0: return
  if selected >= 0:
    if selected < r.candTop: r.candTop = selected
    elif selected >= r.candTop + shown: r.candTop = selected - shown + 1
  r.candTop = clamp(r.candTop, 0, candidates.len - shown)
  for i in 0..<shown:
    let n = r.candTop + i
    if n == selected: r.fill(x0, y0 + 2 + i, w, theme.region)
    r.drawLine(fitCells(candidates[n], w), y0 + 2 + i, 0, x0 = x0, width = w)

proc boxPlace(r: Renderer, n, maxRows, row: int): (bool, int) =
  ## Whether a cursor box of n lines hanging from text row `row` goes under it (else
  ## above), and how many rows it shows.
  let want = min(n, maxRows)
  let under = r.rows - row - 1 >= min(3, want)
  (under, max(0, min(want, if under: r.rows - row - 1 else: row)))

proc boxRows*(r: Renderer, n, maxRows, row: int): int =
  ## The rows cursorBox shows of n lines hanging from text row `row`, for scrolling it.
  r.boxPlace(n, maxRows, row)[1]

proc cursorBox(r: Renderer, lines: seq[string], selected: int, cell, row: int, maxRows = 8,
               top = 0, tags: seq[string] = @[], details: seq[string] = @[]) =
  ## Lines in a frame just below text row `row` (above it when fewer than 3 rows remain
  ## below), text from `cell`, at most 60 cells wide: a tag column in theme.label, then
  ## the line, then its detail right-aligned. It never covers the mode line.
  if lines.len == 0: return
  let (under, shown) = r.boxPlace(lines.len, maxRows, row)
  if shown <= 0: return
  let y0 = if under: row + 1 else: row - shown
  let tagW = if tags.len > 0: 2 else: 0
  var labelW, detailW = 0
  for s in lines: labelW = max(labelW, cellCol(s.toRunes, s.runeLen))
  for s in details: detailW = max(detailW, cellCol(s.toRunes, s.runeLen))
  let w = min(min(60, r.cols - 2), tagW + labelW + (if detailW > 0: 2 + detailW else: 0))
  if w <= tagW: return
  let x0 = clamp(cell - 1, 0, max(0, r.cols - w - 2))  # the frame's column; text at x0 + 1
  let first = clamp(top, 0, lines.len - shown)
  let fx = (r.pad + x0 * r.cellW).float32
  let fy = (r.pad + y0 * r.cellH).float32
  let fw = ((w + 2) * r.cellW).float32
  let fh = (shown * r.cellH).float32
  r.gpu.drawRect(rect(fx, fy, fw, fh), theme.popup)
  let avail = w - tagW
  for i in 0..<shown:
    let n = first + i
    let y = y0 + i
    if n == selected: r.fill(x0 + 1, y, w, theme.region)
    if tagW > 0 and n < tags.len:
      r.drawLine(tags[n].toRunes, y, 0, x0 = x0 + 1, width = 1, tint = theme.label)
    let label = fitCells(lines[n], avail)
    r.drawLine(label, y, 0, x0 = x0 + 1 + tagW, width = avail)
    if n < details.len and details[n].len > 0:
      let room = avail - cellCol(label, label.len) - 2
      if room >= 3:
        let d = fitCells(details[n], room)
        let dw = cellCol(d, d.len)
        r.drawLine(d, y, 0, x0 = x0 + 1 + w - dw, width = dw, tint = theme.label)
  for edge in [rect(fx, fy, fw, 1), rect(fx, fy + fh - 1, fw, 1), rect(fx, fy, 1, fh),
               rect(fx + fw - 1, fy, 1, fh)]:
    r.gpu.drawRect(edge, theme.border)  # 1 px, inside the rows so the mode line stays clear

proc draw*(r: Renderer, window: Window, b: Buffer, echo, mini: string,
           miniCursor = -1, matchStart = -1, matchLen = 0,
           inputSegment = "", modeTag = "", lineColors: seq[int8] = @[],
           prompt = "", popup = false, faces: openArray[seq[Face]] = [], modeName = "Text",
           bufName = "", candidates: openArray[string] = [], selected = -1, listed = false,
           anchor = atTop, marks: openArray[seq[int8]] = [], box = CursorBox(),
           lineNumbers = false) =
  # The gutter: right-aligned numbers, at least 3 digits wide so it rarely shifts, and
  # 2 empty cells before the text.
  let gutter = if lineNumbers: max(3, len($b.lines.len)) + 2 else: 0
  let cols = max(1, r.cols - gutter)
  let cursorCell = b.cellCol(b.cursor)
  let nativeIme = window.imeCompositionString.len > 0
  let composition = (if nativeIme: window.imeCompositionString else: inputSegment).toRunes
  let imeCursor = if nativeIme: imeRuneCol(composition, window.imeCursorIndex) else: composition.len
  let textComposition = if miniCursor < 0: composition else: @[]
  let span = cursorSpan(displayLine(b.lines[b.cursor.line], textComposition, b.cursor.col),
    b.cursor.col + (if miniCursor < 0: imeCursor else: 0))
  if b.cursor.line < r.top or b.cursor.line >= r.top + r.rows:
    r.top = max(0, b.cursor.line - r.rows div 2)
  if span.cell < r.left: r.left = span.cell
  if span.cell + span.width > r.left + cols: r.left = max(0, span.cell + span.width - cols)
  when defined(windows) or defined(macosx):
    if miniCursor < 0:
      window.imePos = ivec2((r.pad + (gutter+span.cell-r.left)*r.cellW).int32,
        (r.pad + (b.cursor.line-r.top+1)*r.cellH).int32)
  r.gpu.beginFrame(window.size)
  r.gpu.drawRect(rect(0, 0, window.size.x.float32, window.size.y.float32), theme.bg)
  let selection = b.region
  let pair = if miniCursor < 0: matchParen(b.lines, faces, b.cursor.line, b.cursor.col) else: @[]
  var offset = b.offset((min(r.top, b.lines.high), 0))
  for line in r.top..<min(b.lines.len, r.top + r.rows):
    let row = line - r.top
    if line < lineColors.len and lineColors[line] in 1'i8..4'i8:
      r.band(row, theme.review[lineColors[line]])
    let cursor = if miniCursor < 0 and line == b.cursor.line: b.cursor.col else: -1
    var paren = [-1, -1]
    for i, p in pair:
      if p.line == line: paren[i] = p.col
    if gutter > 0:
      r.drawLine(align($(line + 1), gutter - 2).toRunes, row, 0, width = gutter - 2,
        tint = if line == b.cursor.line: theme.lineNoNow else: theme.lineNo)
    r.drawLine(b.lines[line], row, r.left, cursor,
      if b.regionActive: selection.a-offset else: -1,
      if b.regionActive: selection.z-offset else: -1,
      if matchStart >= 0: matchStart-offset else: -1,
      if matchStart >= 0: matchStart+matchLen-offset else: -1,
      if cursor >= 0: textComposition else: @[], imeCursor,
      faces = if line < faces.len: faces[line] else: @[],
      marks = if line < marks.len: marks[line] else: @[], paren = paren,
      x0 = gutter, width = if gutter > 0: cols else: -1)
    offset += b.lines[line].len + 1
  if box.lines.len > 0 and box.line - r.top in 0..<r.rows:
    r.cursorBox(box.lines, box.selected, gutter + box.cell - r.left, box.line - r.top, box.maxRows,
      box.top, box.tags, box.details)
  r.band(r.rows, theme.modeLine)
  let name = if bufName.len > 0: bufName elif b.path.len == 0: "*scratch*" else: extractFilename(b.path)
  r.status(window, " -" & (if b.modified: "**" else: "--") & "- " & name &
    "   L" & $(b.cursor.line+1) & " C" & $cursorCell & "  (" & modeName & ") " & modeTag, r.rows,
    tint = theme.modeLineFg)
  let miniComp = if miniCursor >= 0: composition else: @[]
  let miniIme = if miniCursor >= 0: imeCursor else: 0
  let label = prompt.strip(leading = false).toRunes
  if popup and miniCursor >= 0 and r.popupFit > 0 and r.cols >= 10 and
      cellCol(label, label.len) <= r.cols - 2:
    r.status(window, echo, r.rows+1)
    r.popupBox(window, label, mini, miniCursor, miniComp, miniIme, candidates, selected, listed,
      anchor)
  elif miniCursor >= 0:
    # Isearch, or a window too small for the popup: the bottom-line minibuffer.
    # Like icomplete, the fallback shows the candidate Enter would accept.
    let pick = if listed and selected >= 0: "  {" & candidates[selected] & "}" else: ""
    r.status(window, prompt & mini & pick & (if echo.len > 0: "  [" & echo & "]" else: ""), r.rows+1,
      prompt.runeLen + miniCursor, miniComp, miniIme)
  else:
    r.status(window, echo, r.rows+1)
  r.gpu.endFrame()
  window.swapBuffers()
  let title = "darger — " & name
  if r.lastTitle != title: (window.title = title; r.lastTitle = title)
