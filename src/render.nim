import std/[os, unicode, sets, tables, math, strutils]
import windy, boxy, pixie, opengl
import buffer
when not defined(windows) and not defined(macosx): import std/osproc

type Renderer* = ref object
  gpu: Boxy
  fonts: seq[Font]
  chosen: Table[int, int]
  glyphs: HashSet[string]
  scale: float32
  lastTitle: string
  cellW*, cellH*, rows*, cols*, top*, left*: int

let
  bg = parseHtmlColor("#1e1e2e").color
  fg = parseHtmlColor("#cdd6f4").color
  cursorColor = parseHtmlColor("#f5e0dc").color
  regionColor = parseHtmlColor("#45475a").color
  modeColor = parseHtmlColor("#313244").color
  searchColor = parseHtmlColor("#f9e2af").color
  reviewColors = [bg, parseHtmlColor("#512e3a").color, parseHtmlColor("#294638").color,
    parseHtmlColor("#784452").color, parseHtmlColor("#3e6950").color]

when not defined(windows) and not defined(macosx):
  proc fcMatch(pattern: string): string =
    try:
      # Keep stderr out: fontconfig warnings would corrupt the path.
      let (o, c) = execCmdEx("fc-match -f '%{file}' " & quoteShell(pattern), {poUsePath})
      if c == 0 and fileExists(o.strip): result = o.strip
    except CatchableError: discard

proc newRenderer*(): Renderer =
  result = Renderer()
  var paths: seq[string]
  let primary = getEnv("DARGER_FONT")
  if primary.len > 0: paths.add primary
  when defined(windows):
    paths.add @[getEnv("LOCALAPPDATA") / "Microsoft/Windows/Fonts/HackGenConsoleNF-Regular.ttf",
      "C:/Windows/Fonts/CascadiaMono.ttf", "C:/Windows/Fonts/consola.ttf",
      "C:/Windows/Fonts/cour.ttf"]
  else:
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
  let scale = window.uiScale
  if r.scale != scale:
    for key in r.glyphs: r.gpu.removeImage(key)
    r.glyphs.clear()
    r.scale = scale
    for font in r.fonts: font.size = 16 * r.scale
    let primary = r.fonts[0]
    r.cellW = max(1, int(ceil(primary.typeface.getAdvance(Rune(77)) * primary.scale)))
    r.cellH = max(1, int(ceil(primary.typeface.lineHeight * primary.scale)))
    b.goal = -1
  r.rows = max(1, window.size.y.int div r.cellH - 2)
  r.cols = max(1, window.size.x.int div r.cellW)

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
  r.gpu.drawImage(key, vec2(x.float32, y.float32), tint)

proc fill(r: Renderer, cell, row, count: int, c: Color) =
  r.gpu.drawRect(rect((cell * r.cellW).float32, (row * r.cellH).float32,
    (count * r.cellW).float32, r.cellH.float32), c)

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

proc drawLine(r: Renderer, line: seq[Rune], row, scroll: int, cursor = -1,
              selectionStart = -1, selectionEnd = -1, matchStart = -1, matchEnd = -1,
              composition: seq[Rune] = @[], imeCursor = 0) =
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
      if at + size > scroll and at < scroll + r.cols:
        if pass == 0:
          if selected or composing: r.fill(at-scroll, row, size, regionColor)
          if matched: r.fill(at-scroll, row, size, searchColor)
        else:
          r.glyph(rune, (at-scroll)*r.cellW, row*r.cellH, if matched or underCursor: bg else: fg)
      cell += width
    if pass == 0 and caret >= 0: r.fill(span.cell-scroll, row, span.width, cursorColor)

proc status(r: Renderer, window: Window, text: string, row: int, cursor = -1,
            composition: seq[Rune] = @[], imeCursor = 0) =
  var scroll = 0
  if cursor >= 0:
    let span = cursorSpan(displayLine(text.toRunes, composition, cursor), cursor + imeCursor)
    scroll = max(0, span.cell + span.width - r.cols)
    when defined(windows) or defined(macosx):
      window.imePos = ivec2(((span.cell-scroll)*r.cellW).int32, ((row+1)*r.cellH).int32)
  r.drawLine(text.toRunes, row, scroll, cursor, composition = composition, imeCursor = imeCursor)

proc draw*(r: Renderer, window: Window, b: Buffer, echo, mini: string,
           miniCursor = -1, matchStart = -1, matchLen = 0,
           inputSegment = "", modeTag = "", lineColors: seq[int8] = @[]) =
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
  if span.cell + span.width > r.left + r.cols: r.left = max(0, span.cell + span.width - r.cols)
  when defined(windows) or defined(macosx):
    if miniCursor < 0:
      window.imePos = ivec2(((span.cell-r.left)*r.cellW).int32,
        ((b.cursor.line-r.top+1)*r.cellH).int32)
  r.gpu.beginFrame(window.size)
  r.gpu.drawRect(rect(0, 0, window.size.x.float32, window.size.y.float32), bg)
  let selection = b.region
  var offset = b.offset((min(r.top, b.lines.high), 0))
  for line in r.top..<min(b.lines.len, r.top + r.rows):
    let row = line - r.top
    if line < lineColors.len and lineColors[line] in 1'i8..4'i8:
      r.fill(0, row, r.cols + 1, reviewColors[lineColors[line]])
    let cursor = if miniCursor < 0 and line == b.cursor.line: b.cursor.col else: -1
    r.drawLine(b.lines[line], row, r.left, cursor,
      if b.regionActive: selection.a-offset else: -1,
      if b.regionActive: selection.z-offset else: -1,
      if matchStart >= 0: matchStart-offset else: -1,
      if matchStart >= 0: matchStart+matchLen-offset else: -1,
      if cursor >= 0: textComposition else: @[], imeCursor)
    offset += b.lines[line].len + 1
  r.fill(0, r.rows, r.cols + 1, modeColor)
  let name = if b.path.len == 0: "*scratch*" else: extractFilename(b.path)
  r.status(window, " -" & (if b.modified: "**" else: "--") & "- " & name &
    "   L" & $(b.cursor.line+1) & " C" & $cursorCell & "  (Text) " & modeTag, r.rows)
  r.status(window, if miniCursor >= 0: mini else: echo, r.rows+1, miniCursor,
    if miniCursor >= 0: composition else: @[], if miniCursor >= 0: imeCursor else: 0)
  r.gpu.endFrame()
  window.swapBuffers()
  let title = "darger — " & name
  if r.lastTitle != title: (window.title = title; r.lastTitle = title)
