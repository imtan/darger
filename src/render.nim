import std/[os, unicode, sets, tables, math, strutils]
import windy, boxy, pixie, opengl
import panes
import buffer, syntax
when not defined(windows) and not defined(macosx): import std/osproc

type
  Renderer* = ref object
    gpu: Boxy
    fonts: seq[Font]
    fallbacks: string  # set-fallback-fonts / DARGER_FALLBACK_FONTS entries; "" uses the defaults
    chosen: Table[int, int]
    glyphs: HashSet[string]
    scale: float32
    zoom*: float32
    lastTitle: string
    pad, areaW: int
    bar, padTop: int  # the title bar's height; the text area's top: bar + pad
    cellW*, cellH*, rows*, cols*, top*, left*: int  # rows/cols/top/left: the selected pane
    frameRows*, frameCols*: int  # the text area in cells: every pane and mode line, not the echo line
    px, py, pw, ph: int   # the pane being drawn: its cell origin and size (ph includes its mode line)
    background*: proc()   # draws under everything (a shader); nil = the theme's background colour
    backgroundDim*: float32  # the theme background's opacity laid over it, 0 .. 1
    pictureOnly*: bool    # show the background alone: no text, mode lines or echo line
    candTop: int  # first candidate row shown in the popup
  Anchor* = enum atTop, atBottom
  CursorBox* = object   ## a completion or hover box hanging from a buffer position
    lines*, tags*, details*: seq[string]  # tags / details: one per line, or none
    selected*, top*: int  # selected -1 = none; top: the first line shown
    line*, cell*: int     # the buffer line and cell the box hangs from
    maxRows*: int
  Theme* = object
    bg*, fg*, cursor*, region*, modeLine*, modeLineFg*, search*, searchFg*, border*,
      label*, popup*, paren*, lineNo*, lineNoNow*, titleBar*, titleBarFg*: Color
    comment*, str*, keyword*, fnname*, variable*, typ*, constant*, builtin*: Color
    review*: array[5, Color]  # bg, removed, added, removed-refine, added-refine
    err*, warn*, info*, hint*: Color  # diagnostic underlines
    ansi*: array[8, Color]    # terminal colours: black red green yellow blue magenta cyan white

proc hex(s: string): Color = parseHtmlColor(s).color

let themes = {
  "modus-vivendi": Theme(bg: hex"#000000", fg: hex"#ffffff", cursor: hex"#ffffff",
    region: hex"#5a5a5a", modeLine: hex"#505050", modeLineFg: hex"#ffffff",
    search: hex"#7a6100", searchFg: hex"#ffffff", border: hex"#646464",
    label: hex"#989898", popup: hex"#1e1e1e", paren: hex"#2f7f9f",
    lineNo: hex"#535353", lineNoNow: hex"#ffffff", titleBar: hex"#1e1e1e", titleBarFg: hex"#989898",
    comment: hex"#989898", str: hex"#79a8ff", keyword: hex"#b6a0ff", fnname: hex"#feacd0",
    variable: hex"#00d3d0", typ: hex"#6ae4b9", constant: hex"#00bcff", builtin: hex"#f78fe7",
    review: [hex"#000000", hex"#4f1119", hex"#00381f", hex"#781a1f", hex"#034f2f"],
    err: hex"#ff5f59", warn: hex"#d0bc00", info: hex"#2fafff", hint: hex"#989898",
    ansi: [hex"#989898", hex"#ff5f59", hex"#44bc44", hex"#d0bc00", hex"#2fafff", hex"#feacd0",
           hex"#00d3d0", hex"#ffffff"]),
  "catppuccin": Theme(bg: hex"#1e1e2e", fg: hex"#cdd6f4", cursor: hex"#f5e0dc",
    region: hex"#45475a", modeLine: hex"#313244", modeLineFg: hex"#cdd6f4",
    search: hex"#f9e2af", searchFg: hex"#1e1e2e", border: hex"#585b70",
    label: hex"#a6adc8", popup: hex"#313244", paren: hex"#585b70",
    lineNo: hex"#45475a", lineNoNow: hex"#b4befe", titleBar: hex"#181825", titleBarFg: hex"#a6adc8",
    comment: hex"#6c7086", str: hex"#a6e3a1", keyword: hex"#cba6f7", fnname: hex"#89b4fa",
    variable: hex"#b4befe", typ: hex"#f9e2af", constant: hex"#fab387", builtin: hex"#f38ba8",
    review: [hex"#1e1e2e", hex"#512e3a", hex"#294638", hex"#784452", hex"#3e6950"],
    err: hex"#f38ba8", warn: hex"#f9e2af", info: hex"#89b4fa", hint: hex"#6c7086",
    ansi: [hex"#6c7086", hex"#f38ba8", hex"#a6e3a1", hex"#f9e2af", hex"#89b4fa", hex"#f5c2e7",
           hex"#94e2d5", hex"#cdd6f4"])}.toTable
var theme* = themes["modus-vivendi"]

proc setTheme*(name: string): bool =
  result = name in themes
  if result: theme = themes[name]

type TitleHit* = enum thNone, thBar, thMinimize, thMaximize, thClose
const
  titleButtons* = {thMinimize, thMaximize, thClose}
  # Like the native bars: traffic lights on the left on macOS, controls on the right elsewhere.
  titleOrder = when defined(macosx): [thClose, thMinimize, thMaximize]
               else: [thMinimize, thMaximize, thClose]

proc titleButtonWidth*(cellH: int): int = cellH * 3 div 2

proc titleButtonLeft*(cellH, width, i: int): int =
  ## The left edge of the i-th title bar button in a window `width` pixels wide.
  when defined(macosx): i * titleButtonWidth(cellH)
  else: width - (3 - i) * titleButtonWidth(cellH)

proc titleHit*(cellH, width, x, y: int): TitleHit =
  ## What the title bar, the top cellH pixels of a window `width` pixels wide, holds at x, y.
  if y < 0 or y >= cellH or x < 0 or x >= width: return thNone
  for i, hit in titleOrder:
    let left = titleButtonLeft(cellH, width, i)
    if x >= left and x < left + titleButtonWidth(cellH): return hit
  thBar

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

proc loadFont(path: string): Font =
  ## Raises IOError or PixieError, with the reason, for a font the editor cannot use.
  # readTypeface rejects .ttc; readTypefaces parses ttcf directory offsets.
  if path.toLowerAscii.endsWith(".ttc"):
    let faces = readTypefaces(path)
    if faces.len == 0: raise newException(IOError, "Empty font collection")
    result = newFont(faces[0])
  else: result = readFont(path)
  # Pixie only reads Windows (platform 3) cmap subtables; Apple's Menlo.ttc
  # has none, so it loads with an empty glyph map. Treat that as a failure.
  if not result.typeface.hasGlyph(Rune('e')):
    raise newException(IOError, "No glyph for 'e' (unsupported cmap)")
  result.paint = color(1, 1, 1, 1)

proc tryLoadFont(path: string): Font =
  ## nil, with a note on stderr, when the font cannot be used.
  try: result = loadFont(path)
  except CatchableError as e:
    result = nil
    stderr.writeLine("Skipping font " & path & ": " & e.msg)

proc defaultFallbacks(): seq[string] =
  when defined(windows):
    result = @["C:/Windows/Fonts/BIZ-UDGothicR.ttc", "C:/Windows/Fonts/YuGothM.ttc",
      "C:/Windows/Fonts/msgothic.ttc", "C:/Windows/Fonts/malgun.ttf",
      "C:/Windows/Fonts/seguiemj.ttf", "C:/Windows/Fonts/seguisym.ttf"]
  else:
    # No colour emoji: pixie rejects CBDT and sbix.
    result = @["/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
      "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
      "/usr/share/fonts/google-noto-sans-cjk-fonts/NotoSansCJK-Regular.ttc",
      "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
      "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
      "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
      "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"]
    when not defined(macosx):
      # %{file} only: the TTC face index would pick a Korean face; lang=ja matches non-CJK fonts.
      result.add fcMatch("monospace:charset=3042 6f22")
      result.add fcMatch("monospace:charset=d55c")

proc loadFallbacks(fonts: var seq[Font], fallbacks: string, loaded: var HashSet[string]) =
  ## Appends the fonts after the primary: the ';'-separated entries as given, else
  ## the platform defaults that exist, each file name once. Unusable ones are skipped.
  let paths = if fallbacks.len > 0: fallbacks.split(';') else: defaultFallbacks()
  for entry in paths:
    let path = entry.strip
    if path.len == 0 or (fallbacks.len == 0 and not fileExists(path)): continue
    if fallbacks.len == 0 and extractFilename(path) in loaded: continue
    let font = tryLoadFont(path)
    if font != nil:
      fonts.add font
      loaded.incl extractFilename(path)

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
      "/System/Library/Fonts/SFNSMono.ttf",
      "/System/Library/Fonts/Menlo.ttc", "/Library/Fonts/Menlo.ttf"]
  # File names of loaded default fonts, so distro and fc-match duplicates load once.
  var loaded: HashSet[string]
  for path in paths:
    if not fileExists(path) and path != primary: continue
    let font = tryLoadFont(path)
    if font != nil:
      result.fonts.add font
      loaded.incl extractFilename(path)
      break
  when not defined(windows) and not defined(macosx):
    if result.fonts.len == 0:
      let path = fcMatch("monospace:spacing=mono")
      let font = if path.len > 0: tryLoadFont(path) else: nil
      if font != nil:
        result.fonts.add font
        loaded.incl extractFilename(path)
  if result.fonts.len == 0:
    raise newException(IOError, "Set DARGER_FONT to a readable monospace font")
  result.fallbacks = getEnv("DARGER_FALLBACK_FONTS")
  loadFallbacks(result.fonts, result.fallbacks, loaded)
  loadExtensions()
  result.gpu = newBoxy()

proc swapFonts(r: Renderer, fonts: seq[Font]) =
  # Glyph choices and cached images are per font index, so both start over.
  r.fonts = fonts
  r.chosen.clear()
  for key in r.glyphs: r.gpu.removeImage(key)
  r.glyphs.clear()
  r.scale = 0  # the next resize sizes the new fonts and measures the cell again

proc setFont*(r: Renderer, path: string) =
  ## Makes path the primary font, keeping the fallbacks; raises with the reason
  ## (and leaves the fonts alone) when it cannot be used.
  var fonts = @[loadFont(path)]
  var loaded = toHashSet([extractFilename(path)])
  loadFallbacks(fonts, r.fallbacks, loaded)
  r.swapFonts(fonts)

proc setFallbackFonts*(r: Renderer, fallbacks: string) =
  ## Replaces the fonts after the primary with the ';'-separated paths; raises on
  ## the first that cannot be used (and leaves the fonts alone).
  var fonts = @[r.fonts[0]]
  for entry in fallbacks.split(';'):
    let path = entry.strip
    if path.len > 0: fonts.add loadFont(path)
  if fonts.len == 1: raise newException(ValueError, "Expected font paths separated by ';'")
  r.fallbacks = fallbacks
  r.swapFonts(fonts)

proc envScale(name: string): float32 =
  try:
    let v = parseFloat(getEnv(name))
    if v.classify == fcNormal and v > 0 and v < 16: return v.float32
  except ValueError: discard

proc uiScale*(window: Window): float32 =
  let forced = envScale("DARGER_SCALE")
  if forced > 0: return forced
  result = window.contentScale
  when defined(linux):
    # XWayland with zero scaling reports 1.0 on HiDPI; GDK_SCALE carries the real factor.
    if result == 1:
      let g = envScale("GDK_SCALE")
      if g > 0: result = g

proc setPane*(r: Renderer, x, y, w, h: int) =
  ## Draws into the pane at cells (x, y), w by h (h includes its mode line row); the
  ## text rows and columns the editor's commands see are this pane's.
  (r.px, r.py, r.pw, r.ph) = (x, y, w, h)
  r.rows = max(1, h - 1)
  r.cols = max(1, w)

proc setFrame*(r: Renderer) =
  ## The whole text area as one pane, for the prompt popup and the echo line.
  r.setPane(0, 0, r.frameCols, r.frameRows)

proc cellAt*(r: Renderer, pos: IVec2): tuple[x, y: int] =
  ## The frame cell under a window position (y < 0 above the text area).
  ((pos.x.int - r.pad) div r.cellW, (pos.y.int - r.padTop) div r.cellH)

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
  r.bar = r.cellH
  r.pad = max(0, min(int(round(32 * ui)), min((w - r.cellW) div 2, (h - r.bar - 3 * r.cellH) div 2)))
  r.padTop = r.bar + r.pad
  r.areaW = max(0, w - 2 * r.pad)
  r.frameRows = max(2, (h - r.bar - 2 * r.pad) div r.cellH - 1)
  r.frameCols = max(1, r.areaW div r.cellW)
  r.setFrame()  # one pane filling the frame until the editor lays its panes out

proc titleHit*(r: Renderer, window: Window, pos: IVec2): TitleHit =
  titleHit(r.bar, window.size.x.int, pos.x.int, pos.y.int)

proc glyph(r: Renderer, rune: Rune, x, y: int, tint: Color) =
  ## One rune with its top left at window pixel x, y.
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
  r.gpu.drawImage(key, vec2(x.float32, y.float32), tint)

proc cellX(r: Renderer, cell: int): int = r.pad + (r.px + cell) * r.cellW
proc rowY(r: Renderer, row: int): int = r.padTop + (r.py + row) * r.cellH

proc fill(r: Renderer, cell, row, count: int, c: Color) =
  r.gpu.drawRect(rect(r.cellX(cell).float32, r.rowY(row).float32,
    (count * r.cellW).float32, r.cellH.float32), c)

proc band(r: Renderer, row: int, c: Color) =
  ## A full-width row of the pane; the rightmost pane's reaches the text area's edge.
  let w = if r.px + r.pw >= r.frameCols: r.pad + r.areaW - r.cellX(0) else: r.pw * r.cellW
  r.gpu.drawRect(rect(r.cellX(0).float32, r.rowY(row).float32, w.float32, r.cellH.float32), c)

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
  of fAnsi0..fAnsi7: theme.ansi[ord(f) - ord(fAnsi0)]

proc drawLine(r: Renderer, line: seq[Rune], row, scroll: int, cursor = -1,
              selectionStart = -1, selectionEnd = -1, matchStart = -1, matchEnd = -1,
              composition: seq[Rune] = @[], imeCursor = 0,
              x0 = 0, width = -1, tint = theme.fg, faces: seq[Face] = @[],
              marks: seq[int8] = @[], paren = [-1, -1], bgs: seq[int8] = @[]) =
  let visible = if width < 0: r.pw else: width
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
          let bg = if composing or original >= bgs.len: 0'i8 else: bgs[original]
          if bg in 1'i8..8'i8: r.fill(x0+at-scroll, row, size, theme.ansi[bg - 1])
          if selected or composing: r.fill(x0+at-scroll, row, size, theme.region)
          if matched: r.fill(x0+at-scroll, row, size, theme.search)
          if not composing and original in paren: r.fill(x0+at-scroll, row, size, theme.paren)
        else:
          let face = if composing or original >= faces.len: fPlain else: faces[original]
          r.glyph(rune, r.cellX(x0+at-scroll), r.rowY(row),
            if underCursor: theme.bg elif matched: theme.searchFg else: faceColor(face, tint))
          let mark = if composing or original >= marks.len: 0'i8 else: marks[original]
          if mark in 1'i8..5'i8:  # a diagnostic (1-4) or a plain underline (5): 2 px at the bottom
            r.gpu.drawRect(rect(r.cellX(x0+at-scroll).float32,
              (r.rowY(row+1) - 2).float32, (size*r.cellW).float32, 2),
              if mark == 5: faceColor(face, tint) else: [theme.err, theme.warn, theme.info, theme.hint][mark - 1])
      cell += width
    if pass == 0 and caret >= 0: r.fill(x0+span.cell-scroll, row, span.width, theme.cursor)

proc status(r: Renderer, window: Window, text: string, row: int, cursor = -1,
            composition: seq[Rune] = @[], imeCursor = 0, x0 = 0, width = -1, tint = theme.fg) =
  let visible = if width < 0: r.pw else: width
  var scroll = 0
  if cursor >= 0:
    let span = cursorSpan(displayLine(text.toRunes, composition, cursor), cursor + imeCursor)
    scroll = max(0, span.cell + span.width - visible)
    when defined(windows) or defined(macosx):
      window.imePos = ivec2(r.cellX(x0+span.cell-scroll).int32, r.rowY(row+1).int32)
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
  ## The popup floats over the whole frame, whatever the panes.
  let rows = r.frameRows - 1
  if rows >= 6: min(10, max(2, rows - 7)) else: 0

proc popupShown*(r: Renderer, candidates: int): int =
  ## Candidate rows the popup lists.
  min(candidates, r.popupFit)

proc popupRows*(r: Renderer, candidates: int, anchor: Anchor): tuple[top, bottom: int] =
  ## Whole rows the popup frame covers: label, input and candidates plus a margin
  ## row above and below. The top box may cover the mode line, never the echo line.
  ## The bottom box sits on the last text row and keeps its full height, so the
  ## preview above it does not shift while the list is filtered.
  let fit = r.popupFit
  let rows = r.frameRows - 1
  if fit == 0: return (rows, rows)
  if anchor == atBottom: (rows - 4 - fit, rows - 1)
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
  let fx = r.cellX(x0 - 1).float32
  let fy = r.rowY(y0 - 1).float32
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
  let fx = r.cellX(x0).float32
  let fy = r.rowY(y0).float32
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

proc icon(r: Renderer, name: string): string =
  ## The atlas key of a title bar icon: a cellH square stroked by Pixie, so it needs no
  ## font. It lives with the glyphs and is dropped with them when the scale changes.
  result = "i:" & name & ":" & $r.bar
  if result in r.glyphs: return
  let n = r.bar
  let img = newImage(n, n)
  let s = float32(max(6, n div 2))      # the icon's side
  let o = float32((n - int(s)) div 2)   # its offset in the square
  let stroke = max(1'f32, round(r.scale))
  let path = newPath()
  case name
  of "min":
    path.moveTo(o, o + s / 2)
    path.lineTo(o + s, o + s / 2)
  of "max": path.rect(o, o, s, s)
  of "restore":  # the front square low left, the back one peeking out high right
    path.rect(o, o + s / 4, s * 3 / 4, s * 3 / 4)
    path.moveTo(o + s / 4, o + s / 4)
    path.lineTo(o + s / 4, o)
    path.lineTo(o + s, o)
    path.lineTo(o + s, o + s * 3 / 4)
    path.lineTo(o + s * 3 / 4, o + s * 3 / 4)
  else:
    path.moveTo(o, o)
    path.lineTo(o + s, o + s)
    path.moveTo(o + s, o)
    path.lineTo(o, o + s)
  # An odd stroke centred on a pixel edge blurs over two pixels; shift it onto one.
  let half = if int(stroke) mod 2 == 1: 0.5'f32 else: 0'f32
  img.strokePath(path, color(1, 1, 1, 1), translate(vec2(half, half)), strokeWidth = stroke)
  r.gpu.addImage(result, img)
  r.glyphs.incl result

proc titleBar(r: Renderer, window: Window, title: string, hover: TitleHit, maximized: bool) =
  ## The top row: the buttons, then the title centred in the space they leave on both sides.
  let w = window.size.x.int
  r.gpu.drawRect(rect(0, 0, w.float32, r.bar.float32), theme.titleBar)
  let bw = titleButtonWidth(r.bar)
  for i, hit in titleOrder:
    let left = titleButtonLeft(r.bar, w, i)
    if hit == hover:
      r.gpu.drawRect(rect(left.float32, 0, bw.float32, r.bar.float32),
        if hit == thClose: theme.err else: theme.region)
    let key = r.icon(case hit
      of thMinimize: "min"
      of thMaximize: (if maximized: "restore" else: "max")
      else: "close")
    r.gpu.drawImage(key, vec2((left + (bw - r.bar) div 2).float32, 0),
      if hit != hover: theme.titleBarFg elif hit == thClose: theme.bg else: theme.fg)
  let room = (w - 6 * bw) div r.cellW
  if room < 1: return
  let runes = fitCells(title, room)
  let x = (w - cellCol(runes, runes.len) * r.cellW) div 2
  var cell = 0
  for rune in runes:
    let width = cellWidth(rune, cell)
    r.glyph(rune, x + (if width == 0: max(0, cell - 1) else: cell) * r.cellW, 0, theme.titleBarFg)
    cell += width

type
  Picture* = object
    ## An image drawn in the rows under a line (an Org inline image): already fitted.
    line*: int
    key*: string   ## the renderer's picture key (addPicture)
    w*, h*: int    ## pixels

  PaneView* = object
    ## One pane to draw: its buffer, scroll (updated so the cursor stays in view) and
    ## what the editor shows in it. Only the selected pane (active) draws the cursor,
    ## the region, marks, the box and the input composition.
    b*: Buffer
    x*, y*, w*, h*: int
    top*, left*: int
    cursor*: Point
    active*: bool
    faces*: seq[seq[Face]]
    marks*: seq[seq[int8]]   # per rune: 1-4 diagnostic underlines, 5 a plain underline
    bgs*: seq[seq[int8]]     # per rune: 1-8 an ANSI background colour
    fold*: seq[int8]
    extra*: seq[int]         # rows under each line (inline images); missing = 0
    pictures*: seq[Picture]
    lineColors*: seq[int8]
    lineNumbers*: bool
    modeLine*: string
    box*: CursorBox
    matchStart*, matchLen*: int

proc addPicture*(r: Renderer, key: string, img: Image) =
  ## Keeps an image for Picture rows under `key` (replacing one with the same key).
  if r.gpu.contains(key): r.gpu.removeImage(key)
  r.gpu.addImage(key, img)

proc hasPicture*(r: Renderer, key: string): bool = r.gpu.contains(key)
proc removePicture*(r: Renderer, key: string) =
  if r.gpu.contains(key): r.gpu.removeImage(key)

proc drawPane(r: Renderer, window: Window, p: var PaneView, composition: seq[Rune],
              imeCursor: int, textCursor: bool) =
  ## textCursor: the cursor is in the text (no prompt open), so the active pane draws it.
  r.setPane(p.x, p.y, p.w, p.h)
  let b = p.b
  let showCursor = p.active and textCursor
  # The gutter: right-aligned numbers, at least 3 digits wide so it rarely shifts, and
  # 2 empty cells before the text.
  let gutter = if p.lineNumbers: gutterWidth(b.lines.len) else: 0
  let cols = max(1, r.cols - gutter)
  let comp = if showCursor: composition else: @[]
  let cursor = if p.active: b.cursor else: p.cursor
  let span = cursorSpan(displayLine(b.lines[cursor.line], comp, cursor.col),
    cursor.col + (if showCursor: imeCursor else: 0))
  # Hidden (folded) lines take no row: rows count shown lines from the top.
  let fold = p.fold
  let extra = p.extra
  var top = p.top  # (locals: a nested proc cannot capture the var parameter)
  var left = p.left
  proc hidden(n: int): bool = n < fold.len and fold[n] == 1
  proc below(n: int): int = (if n < extra.len: max(0, extra[n]) else: 0)  # image rows under line n
  proc rowOf(n: int): int =  # the row line n lands on, counting shown lines (and their image rows) from the top
    for i in top..<n:
      if not hidden(i): result += 1 + below(i)
  if cursor.line < top or rowOf(cursor.line) + below(cursor.line) >= r.rows:
    top = cursor.line
    var back = r.rows div 2 - below(cursor.line)
    while top > 0 and back > 0:
      dec top
      if not hidden(top): back -= 1 + below(top)
  let cursorRow = rowOf(cursor.line)
  if span.cell < left: left = span.cell
  if span.cell + span.width > left + cols: left = max(0, span.cell + span.width - cols)
  p.top = top
  p.left = left
  when defined(windows) or defined(macosx):
    if showCursor: window.imePos = ivec2(r.cellX(gutter+span.cell-left).int32, r.rowY(cursorRow+1).int32)
  let selection = b.region
  let pair = if showCursor: matchParen(b.lines, p.faces, cursor.line, cursor.col) else: @[]
  var offset = b.offset((min(top, b.lines.high), 0))
  var row = 0
  for line in top..<b.lines.len:
    if row >= r.rows: break
    if hidden(line):
      offset += b.lines[line].len + 1
      continue
    if line < p.lineColors.len and p.lineColors[line] in 1'i8..4'i8:
      r.band(row, theme.review[p.lineColors[line]])
    let at = if showCursor and line == cursor.line: cursor.col else: -1
    var paren = [-1, -1]
    for i, pp in pair:
      if pp.line == line: paren[i] = pp.col
    if gutter > 0:
      r.drawLine(align($(line + 1), gutter - 2).toRunes, row, 0, width = gutter - 2,
        tint = if line == cursor.line: theme.lineNoNow else: theme.lineNo)
    # A folded headline ends in "..." like Emacs' ellipsis for hidden text.
    let shownLine = if line < fold.len and fold[line] == 2: b.lines[line] & " ...".toRunes else: b.lines[line]
    r.drawLine(shownLine, row, left, at,
      if p.active and b.regionActive: selection.a-offset else: -1,
      if p.active and b.regionActive: selection.z-offset else: -1,
      if p.matchStart >= 0: p.matchStart-offset else: -1,
      if p.matchStart >= 0: p.matchStart+p.matchLen-offset else: -1,
      if at >= 0: comp else: @[], imeCursor,
      faces = if line < p.faces.len: p.faces[line] else: @[],
      marks = if line < p.marks.len: p.marks[line] else: @[], paren = paren,
      x0 = gutter, width = cols, bgs = if line < p.bgs.len: p.bgs[line] else: @[])
    offset += b.lines[line].len + 1
    inc row
    # The rows under a line hold its picture, drawn when they all fit in the pane.
    if below(line) > 0:
      for pic in p.pictures:
        if pic.line == line and row + below(line) <= r.rows and r.gpu.contains(pic.key):
          r.gpu.drawImage(pic.key, rect(r.cellX(gutter).float32, r.rowY(row).float32, pic.w.float32, pic.h.float32))
      row += below(line)
  if p.box.lines.len > 0 and p.box.line >= top and rowOf(p.box.line) < r.rows:
    r.cursorBox(p.box.lines, p.box.selected, gutter + p.box.cell - left, rowOf(p.box.line),
      p.box.maxRows, p.box.top, p.box.tags, p.box.details)
  # The mode line: the selected pane's in the mode line colours, the others dimmed.
  r.band(r.rows, if p.active: theme.modeLine else: theme.popup)
  r.status(window, p.modeLine, r.rows, tint = if p.active: theme.modeLineFg else: theme.label)

proc draw*(r: Renderer, window: Window, panes: var seq[PaneView], bars: seq[tuple[x, y, h: int]],
           echo, mini: string, miniCursor = -1, inputSegment = "", prompt = "", popup = false,
           candidates: openArray[string] = [], selected = -1, listed = false,
           anchor = atTop, title = "darger", hover = thNone, maximized = false) =
  ## A frame: the title bar, every pane with its mode line, the separators, then the
  ## prompt popup or the echo line over the whole text area.
  let nativeIme = window.imeCompositionString.len > 0
  let composition = (if nativeIme: window.imeCompositionString else: inputSegment).toRunes
  let imeCursor = if nativeIme: imeRuneCol(composition, window.imeCursorIndex) else: composition.len
  r.gpu.beginFrame(window.size)
  let whole = rect(0, 0, window.size.x.float32, window.size.y.float32)
  if r.background != nil:
    r.background()
    if r.pictureOnly:  # C-c C-o: the picture alone, under the title bar
      r.titleBar(window, title, hover, maximized)
      r.gpu.endFrame()
      window.swapBuffers()
      return
    let a = clamp(r.backgroundDim, 0, 1)  # premultiplied: boxy blends with ONE, ONE_MINUS_SRC_ALPHA
    r.gpu.drawRect(whole, color(theme.bg.r * a, theme.bg.g * a, theme.bg.b * a, a))
  else: r.gpu.drawRect(whole, theme.bg)
  r.titleBar(window, title, hover, maximized)
  for i in 0..<panes.len:
    r.drawPane(window, panes[i], composition, imeCursor, miniCursor < 0)
  r.setFrame()
  for bar in bars:
    for row in 0..<bar.h: r.glyph(Rune(0x2502), r.cellX(bar.x), r.rowY(bar.y + row), theme.border)
  let echoRow = r.frameRows
  let miniComp = if miniCursor >= 0: composition else: @[]
  let miniIme = if miniCursor >= 0: imeCursor else: 0
  let label = prompt.strip(leading = false).toRunes
  if popup and miniCursor >= 0 and r.popupFit > 0 and r.cols >= 10 and
      cellCol(label, label.len) <= r.cols - 2:
    r.status(window, echo, echoRow)
    r.popupBox(window, label, mini, miniCursor, miniComp, miniIme, candidates, selected, listed,
      anchor)
  elif miniCursor >= 0:
    # Isearch, or a window too small for the popup: the bottom-line minibuffer.
    # Like icomplete, the fallback shows the candidate Enter would accept.
    let pick = if listed and selected >= 0: "  {" & candidates[selected] & "}" else: ""
    r.status(window, prompt & mini & pick & (if echo.len > 0: "  [" & echo & "]" else: ""), echoRow,
      prompt.runeLen + miniCursor, miniComp, miniIme)
  else:
    r.status(window, echo, echoRow)
  r.gpu.endFrame()
  window.swapBuffers()
  if r.lastTitle != title: (window.title = title; r.lastTitle = title)
  for p in panes:  # the editor's rows and columns stay the selected pane's
    if p.active: r.setPane(p.x, p.y, p.w, p.h)
