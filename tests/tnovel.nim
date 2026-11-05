import std/[os, tables, unicode]
import pixie, pixie/fontformats/opentype
import ../src/novel

proc texts(line: string, height: int): seq[string] =
  let rs = line.toRunes
  for span in columns(rs, height): result.add $rs[span.start..<span.stop]

block wrapping:
  doAssert texts("", 4) == @[""]
  doAssert texts("abc", 4) == @["abc"]
  doAssert texts("abcdefgh", 4) == @["abcd", "efgh", ""]  # the cursor's room after a full column
  doAssert texts("あいうえおか", 4) == @["あいうえ", "おか"]
  doAssert columns("abc".toRunes, 0).len == 4              # a degenerate height still moves on

block kinsoku:
  doAssert texts("あいう。えお", 3) == @["あい", "う。え", "お"]  # 。 keeps out of a column's start
  doAssert texts("あいう」えお", 3) == @["あい", "う」え", "お"]
  doAssert texts("あいーうえ", 2) == @["あ", "いー", "うえ", ""]
  doAssert texts("あいっうえ", 2) == @["あ", "いっ", "うえ", ""]
  doAssert texts("あ「いう", 2) == @["あ", "「い", "う"]        # 「 keeps out of a column's end
  doAssert texts("。。。。。", 2) == @["。。", "。。", "。"]    # nothing legal: still splits
  doAssert texts("e\u0301き", 1) == @["e\u0301", "き", ""]   # a mark stays with its base

block cells:
  let rs = "e\u0301きa".toRunes
  let spans = columns(rs, 10)
  doAssert cellOf(rs, spans[0], 0) == 0
  doAssert cellOf(rs, spans[0], 1) == 0
  doAssert cellOf(rs, spans[0], 2) == 1
  doAssert cellOf(rs, spans[0], 4) == 3
  doAssert colAtCell(rs, spans[0], 1, true) == 2
  doAssert colAtCell(rs, spans[0], 9, true) == 4
  doAssert colAtCell(rs, spans[0], 9, false) == 3
  let wrapped = "あいうえお".toRunes
  let parts = columns(wrapped, 3)
  doAssert columnOf(parts, 2) == 0
  doAssert columnOf(parts, 3) == 1
  doAssert columnOf(parts, 5) == 1

let page = @["あいうえおかきくけこ".toRunes, "".toRunes, "さしすせそ".toRunes]  # height 3: 4 + 1 + 2 columns
let height = 3
let count = counter(page, height)

block stepping:
  doAssert count(0) == 4 and count(1) == 1 and count(2) == 2
  doAssert stepSpot(count, 3, (0, 0), 3) == (0, 3)
  doAssert stepSpot(count, 3, (0, 3), 1) == (1, 0)
  doAssert stepSpot(count, 3, (0, 0), 5) == (2, 0)
  doAssert stepSpot(count, 3, (0, 0), 99) == (2, 1)
  doAssert stepSpot(count, 3, (2, 1), -2) == (1, 0)
  doAssert stepSpot(count, 3, (2, 0), -2) == (0, 3)
  doAssert stepSpot(count, 3, (2, 1), -99) == (0, 0)
  doAssert distance(count, (0, 1), (0, 3)) == 2
  doAssert distance(count, (0, 1), (2, 1)) == 5

block scrolling:
  doAssert scrollToShow(count, 3, (0, 0), (0, 2), 4) == (0, 0)  # already in view
  doAssert scrollToShow(count, 3, (0, 0), (0, 3), 4) == (0, 0)
  doAssert scrollToShow(count, 3, (0, 0), (1, 0), 4) == (0, 1)  # one step past the edge: one column
  doAssert scrollToShow(count, 3, (0, 2), (0, 1), 4) == (0, 1)  # and back
  doAssert scrollToShow(count, 3, (0, 0), (2, 1), 2) == (2, 0)  # a jump centres
  doAssert scrollToShow(count, 3, (2, 1), (0, 0), 2) == (0, 0)
  doAssert scrollToShow(count, 3, (99, 99), (2, 1), 4) == (2, 1)  # a stale anchor is clamped
  doAssert scrollToShow(count, 3, (0, 99), (0, 3), 4) == (0, 3)
  doAssert clampSpot(count, 3, (99, 99)) == (2, 1)
  doAssert clampSpot(count, 3, (-1, -1)) == (0, 0)

block movement:
  doAssert moveColumn(page, height, (0, 1), 1, -1) == (point: (0, 4), goal: 1)
  doAssert moveColumn(page, height, (0, 4), -1, 1) == (point: (0, 1), goal: 1)
  doAssert moveColumn(page, height, (0, 10), 1, -1).point == (1, 0)
  doAssert moveColumn(page, height, (1, 0), 1, 2).point == (2, 2)  # the goal survives an empty line
  doAssert moveColumn(page, height, (2, 5), 1, -1).point == (2, 5)
  doAssert moveColumn(page, height, (0, 0), -1, -1).point == (0, 0)
  doAssert moveColumn(page, height, (0, 8), 1, -1).point == (0, 10)  # past a short last column's end
  doAssert spotOf(page, height, (0, 9)) == (0, 3)

block clicks:
  doAssert pointAtCell(page, height, (0, 0), 0, 0) == (0, 0)
  doAssert pointAtCell(page, height, (0, 0), 1, 2) == (0, 5)
  doAssert pointAtCell(page, height, (0, 1), 0, 2) == (0, 5)
  doAssert pointAtCell(page, height, (0, 3), 0, 2) == (0, 10)  # below a last column: the line's end
  doAssert pointAtCell(page, height, (0, 0), 4, 2) == (1, 0)
  doAssert pointAtCell(page, height, (0, 0), 99, 0) == (2, 3)
  doAssert pointAtCell(page, height, (2, 0), 0, 2) == (2, 2)

block grid:
  let g = gridFor(800, 600, 32, 1.75)
  doAssert g.cell == 32 and g.pitch == 56 and g.inset == 16 and g.rows == 17 and g.columns == 14
  doAssert g.columnLeft(0) == 800 - 56 + 12
  doAssert g.columnLeft(1) == 800 - 112 + 12
  doAssert g.columnAtX(799) == 0 and g.columnAtX(744) == 0 and g.columnAtX(743) == 1
  doAssert g.cellAtY(0) == 0 and g.cellAtY(16) == 0 and g.cellAtY(48) == 1 and g.cellAtY(9999) == 16
  let tiny = gridFor(1, 1, 32, 0.5)  # a pane smaller than a cell still has one
  doAssert tiny.rows == 1 and tiny.columns == 1 and tiny.pitch == tiny.cell

block forms:
  doAssert verticalForm("ー".runeAt(0)) == vfRotate
  doAssert verticalForm("「".runeAt(0)) == vfRotate
  doAssert verticalForm("…".runeAt(0)) == vfRotate
  doAssert verticalForm("─".runeAt(0)) == vfRotate
  doAssert verticalForm("、".runeAt(0)) == vfCorner
  doAssert verticalForm("っ".runeAt(0)) == vfSmall
  doAssert verticalForm("猫".runeAt(0)) == vfUpright
  doAssert verticalForm(Rune('a')) == vfUpright

proc be16(n: int): string = char((n shr 8) and 255) & char(n and 255)
proc be32(n: int): string = be16(n shr 16) & be16(n and 0xFFFF)

proc gsub(tag: string, lookups: seq[string]): string =
  ## A GSUB table: one feature using every lookup, each lookup given as (type, subtables).
  let features = be16(1) & tag & be16(8) & be16(0) & be16(lookups.len)
  var indices = ""
  for i in 0..<lookups.len: indices.add be16(i)
  let featureList = features & indices
  var offsets = be16(lookups.len)
  var at = 2 + lookups.len * 2
  for lookup in lookups:
    offsets.add be16(at)
    at += lookup.len
  var lookupList = offsets
  for lookup in lookups: lookupList.add lookup
  let header = be32(0x10000) & be16(0) & be16(10) & be16(10 + featureList.len)
  header & featureList & lookupList

proc lookup(kind: int, sub: string): string = be16(kind) & be16(0) & be16(1) & be16(8) & sub

block gsubParsing:
  let coverage1 = be16(1) & be16(2) & be16(5) & be16(9)
  let coverage2 = be16(2) & be16(1) & be16(20) & be16(22) & be16(0)
  let delta = lookup(1, be16(1) & be16(6) & be16(100) & coverage1)
  doAssert vertGlyphs(gsub("vert", @[delta]), 0) == {5'u16: 105'u16, 9'u16: 109'u16}.toTable
  let negative = lookup(1, be16(1) & be16(6) & be16(0xFFFF) & coverage1)
  doAssert vertGlyphs(gsub("vert", @[negative]), 0)[5] == 4
  let explicit = lookup(1, be16(2) & be16(12) & be16(3) & be16(70) & be16(71) & be16(72) & coverage2)
  doAssert vertGlyphs(gsub("vert", @[explicit]), 0) ==
    {20'u16: 70'u16, 21'u16: 71'u16, 22'u16: 72'u16}.toTable
  let extended = lookup(7, be16(1) & be16(1) & be32(8) & be16(1) & be16(6) & be16(1) & coverage1)
  doAssert vertGlyphs(gsub("vert", @[extended]), 0)[9] == 10
  doAssert vertGlyphs(gsub("vrt2", @[delta]), 0)[5] == 105
  doAssert vertGlyphs(gsub("liga", @[delta]), 0).len == 0
  let shifted = "padding!" & gsub("vert", @[delta])
  doAssert vertGlyphs(shifted, 8)[9] == 109
  let whole = gsub("vert", @[delta])
  for cut in 0..<whole.len:  # any damage is survived, whatever it leaves
    discard vertGlyphs(whole[0..<cut], 0)
  doAssert vertGlyphs("", 0).len == 0
  doAssert vertGlyphs(whole, whole.len + 100).len == 0

block realFont:  # RinMincho, where installed: its table and the glyphs it sends us to
  let path = getHomeDir() / "Library/Fonts/RinMincho-Regular.ttf"
  if fileExists(path):
    let opentype = parseOpenType(readFile(path))
    let table = vertGlyphs(opentype.buf, opentype.tableRecords["GSUB"].offset.int)
    doAssert table.len == 267, $table.len
    for mark in "、。「」ー…ぁっ".toRunes:
      doAssert opentype.cmap.runeToGlyphId[mark] in table, $mark
    let form = table[opentype.cmap.runeToGlyphId["、".runeAt(0)]]
    let rune = Rune(0x100000 + form.int)
    opentype.cmap.runeToGlyphId[rune] = form
    let upright = opentype.getGlyphPath("、".runeAt(0)).computeBounds()
    let turned = opentype.getGlyphPath(rune).computeBounds()
    doAssert turned.x > upright.x and turned.y < upright.y  # up and to the right

block tateChuYoko:
  doAssert texts("あ!?いう", 3) == @["あ!?い", "う"]
  doAssert texts("あ12いう", 3) == @["あ12い", "う"]
  doAssert texts("123あ", 3) == @["123", "あ"]
  doAssert texts("1あ", 1) == @["1", "あ", ""]
  for pair in ["!!", "!?", "?!", "??", "12"]:
    let rs = ("あ" & pair & "い").toRunes
    doAssert tcyFirst(rs, 1) and tcySecond(rs, 2)
    doAssert cellOf(rs, (0, rs.len), 1) == cellOf(rs, (0, rs.len), 2)
    doAssert colAtCell(rs, (0, rs.len), 1, true) == 1
    doAssert texts(pair, 1) == @[pair, ""]
    doAssert moveColumn(@[rs], 2, (0, 2), 1, -1).goal == 1
    doAssert pointAtCell(@[rs], 2, (0, 0), 0, 1) == (0, 1)
  for text in ["1", "123", "1234", "1a", "a2"]:
    for i in 0..<text.toRunes.len: doAssert not tcySecond(text.toRunes, i)
  doAssert tcySecond("!?!?".toRunes, 3)
  doAssert not tcySecond("!?!?".toRunes, 2)

block pairedBreaks:
  for pair in ["……", "――", "——", "──"]:
    doAssert texts("あい" & pair & "う", 3) == @["あい", pair & "う", ""]
    doAssert texts(pair & pair & "う", 3) == @[pair, pair & "う", ""]
    doAssert texts(pair, 1).len == 3  # no legal break: retain the fallback

block formatting:
  for (source, expected) in [
      ("Hello, world!", "Ｈｅｌｌｏ， ｗｏｒｌｄ！"),
      ("2026年11月5日、午後3時", "二〇二六年11月五日、午後三時"),
      ("1500円と105円", "千五百円と百五円"),
      ("12345", "一二三四五"), ("２０２６年１２月０日", "二〇二六年12月〇日"),
      ("2026 1000 000", "二千二十六 千 〇"),
      ("0 9 100 9999", "〇 九 百 九千九百九十九"),
      ("０１２３４", "〇一二三四"), ("12年", "12年"),
      ("？）？】？〕？］？』", "？）？】？〕？］？』"),
      ("!!?!!?次", "!!?!!?　次"),
      ("そうか...そうだな・・・", "そうか……そうだな……"),
      ("……", "……"), ("…", "……"), ("………", "…………"),
      ("それは─違う", "それは――違う"), ("ラーメン", "ラーメン"),
      ("- -- --- — ―――", "- ―― ―――― ―― ――――"),
      ("「本当？」", "「本当？」"), ("本当？そうか", "本当？　そうか"),
      ("本当? そうか", "本当？　そうか"), ("なに!?すごい!!", "なに!?　すごい!!"),
      ("「そうです。」", "「そうです」"), ("です。」次", "です」次"),
      ("『はい。』", "『はい』"), ("？ 　そう", "？　そう"),
      ("!?\n次", "!?\n次"), ("！？」", "！？」"),
      ("(A,.:)\"", "（Ａ，．：）＂"), ("....", "……"), ("・・", "・・"),
      ("", ""), ("!?　次", "!?　次"), ("!!!次", "!!！　次"),
      ("15:30と3:05に", "15時30分と三時五分に"), ("10:00発", "10時発"), ("09:07", "九時七分"),
      ("１５：３０", "15時30分"), ("25:00", "25：00"), ("3:2", "三：二"), ("123:45", "百二十三：45"),
      ("0:00", "〇時"), ("24:59", "24時59分")]:
    doAssert novelFormat(source) == expected, source & " -> " & novelFormat(source)
    doAssert novelFormat(novelFormat(source)) == novelFormat(source), source
    if Rune(10) notin source.toRunes:
      let shown = displayLine(source.toRunes)
      doAssert shown.runes == novelFormat(source).toRunes
      doAssert shown.origin.len == shown.runes.len
      doAssert shown.index.len == source.runeLen + 1
      doAssert shown.index[^1] == shown.runes.len
      for i, origin in shown.origin:
        doAssert origin >= 0 and origin < source.runeLen
        if i > 0: doAssert shown.origin[i - 1] <= origin
      for i in 1..<shown.index.len: doAssert shown.index[i - 1] <= shown.index[i]

block displayMapping:
  for (source, expected, origin, index) in [
      ("A1", "Ａ一", @[0, 1], @[0, 1, 2]),
      ("15:30発", "15時30分発", @[0, 0, 0, 0, 0, 0, 5], @[0, 0, 0, 0, 0, 6, 7]),
      ("そうです。」", "そうです」", @[0, 1, 2, 3, 5], @[0, 1, 2, 3, 4, 4, 5]),
      ("本当？そうか", "本当？　そうか", @[0, 1, 2, 2, 3, 4, 5], @[0, 1, 2, 4, 5, 6, 7]),
      ("?  次", "？　次", @[0, 0, 3], @[0, 0, 0, 2, 3]),
      ("...次", "……次", @[0, 0, 3], @[0, 0, 0, 2, 3])]:
    let rs = source.toRunes
    let shown = displayLine(rs)
    doAssert $rs == source  # Display never mutates the buffer's rune sequence.
    doAssert $shown.runes == expected
    doAssert shown.origin == origin, source & " " & $shown.origin
    doAssert shown.index == index, source & " " & $shown.index
    for col in 0..<shown.runes.len: doAssert shown.sourceCol(col) == origin[col]
    doAssert shown.sourceCol(shown.runes.len) == rs.len
  let time = displayLine("15:30発".toRunes)
  doAssert time.stepSource(0, 1) == 5
  doAssert time.stepSource(2, 1) == 5
  doAssert time.stepSource(2, -1) == 0
  doAssert time.stepSource(5, -1) == 0
  doAssert time.displayRange(1, 3) == (0, 6)  # search/region entirely inside the time
  doAssert time.displayRange(2, 2) == (0, 0)  # an empty selection stays empty
  doAssert time.displayRange(5, 6) == (6, 7)
  doAssert time.displayRange(-3, -1) == (0, 0)
  doAssert time.displayRange(8, 10) == (7, 7)
  let deleted = displayLine("そうです。」".toRunes)
  doAssert deleted.stepSource(3, 1) == 5
  doAssert deleted.stepSource(5, -1) == 3
  doAssert deleted.displayRange(4, 5) == (4, 4)  # deleted punctuation has no glyph
  let punctuation = displayLine("!?次".toRunes)
  doAssert punctuation.origin == @[0, 0, 0, 2]
  doAssert punctuation.index == @[0, 0, 3, 4]
  doAssert punctuation.stepSource(0, 1) == 2
  let spans = columns(time.runes, 3)
  doAssert spans.len == 2
  doAssert time.sourceCol(colAtCell(time.runes, spans[1], 0, true)) == 0
  doAssert cellOf(time.runes, spans[0], time.index[3]) == 0
  doAssert novelFormat("A1\r\n15:30\n") == "Ａ一\r\n15時30分\n"

echo "novel ok"
