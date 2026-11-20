import std/[unicode, strutils, options, sequtils]
import ../src/[orgmode, orgfootnote]

block syntax:
  let line = "日本語 [fn:1] [fn:note-1:本文 [補足 [内側]]] [fn::匿名] [fn:組合]".toRunes
  let notes = footnotesOnLine(line, 3)
  doAssert notes.len == 4
  doAssert notes[0].kind == fnReference and notes[0].label == "1" and notes[0].col == 4
  doAssert notes[1].kind == fnInline and notes[1].text == "本文 [補足 [内側]]"
  doAssert notes[2].kind == fnInline and notes[2].label == "" and notes[2].text == "匿名"
  doAssert notes[3].label == "組合" and notes[3].line == 3
  doAssert footnotesOnLine("[fn:組合] 定義".toRunes, 0)[0].kind == fnDefinition
  doAssert footnotesOnLine("[fn:x]".toRunes, 0)[0].kind == fnDefinition
  doAssert footnotesOnLine(" [fn:x] 定義ではない".toRunes, 0)[0].kind == fnReference
  for text in ["[fn:x]続く", "[fn:x]\ttext", "[fn:x][fn:y]"]:  # column 0 defines, whatever follows
    doAssert footnotesOnLine(text.toRunes, 0)[0].kind == fnDefinition
  doAssert footnotesOnLine("[fn::匿名] at column zero".toRunes, 0)[0].kind == fnInline
  for label in ["1", "cnt", "note-1", "組合", "A_１", "١٢"]:
    doAssert validFootnoteLabel(label)
  for label in ["", "a b", " x", "a:b", "a]", "😀"]:
    doAssert not validFootnoteLabel(label)
  for i, note in notes:
    for col in [note.col, note.endCol - 1, note.endCol]:  # both brackets and just after
      doAssert footnoteAt(@[line], 0, col).get.label == note.label
    # the space before a marker is "just after" the marker before it, when there is one
    let before = footnoteAt(@[line], 0, note.col - 1)
    doAssert (if i == 0: before.isNone else: before.get.label == notes[i-1].label)
  doAssert footnoteAt(@[line], -1, 0).isNone
  doAssert footnoteAt(@[line], 1, 0).isNone

block definitions:
  let lines = orgLines("参照 [fn:a] [fn:組合]\n[fn:a] 一行目\n二行目\n\n次の段落\n[fn:組合] 日本語\n続き\n** Head\n[fn:c] body\n\n\nnot body\n[fn:d]\nlast")
  let defs = footnoteDefinitions(lines)
  doAssert defs.len == 4
  doAssert defs[0].line == 1 and defs[0].lastLine == 4 and defs[0].bodyCol == 7
  doAssert definitionBody(lines, defs[0]) == "一行目\n二行目\n\n次の段落"
  doAssert definitionBody(lines, defs[1]) == "日本語\n続き"
  doAssert definitionBody(lines, defs[2]) == "body"
  doAssert definitionBody(lines, defs[3]) == "\nlast"
  doAssert defs[3].lastLine == lines.high
  doAssert footnoteReferences(lines).len == 2
  let trailing = orgLines("[fn:a] body\n \n\t\n")
  doAssert definitionBody(trailing, footnoteDefinitions(trailing)[0]) == "body"
  let empty = orgLines("[fn:a]   \n\n")
  doAssert definitionBody(empty, footnoteDefinitions(empty)[0]) == ""
  let tight = orgLines("[fn:a]続く\n[fn:b]\t本文")  # no space after the marker, as Japanese is often written
  doAssert footnoteDefinitions(tight).len == 2 and footnoteDefinitions(tight)[0].bodyCol == 6
  doAssert definitionBody(tight, footnoteDefinitions(tight)[0]) == "続く"
  doAssert definitionBody(tight, footnoteDefinitions(tight)[1]) == "本文"
  let bodyRef = orgLines("[fn:a] body [fn:b]\n [fn:c]")
  doAssert footnoteReferences(bodyRef).mapIt(it.label) == @["b", "c"]

block labels:
  let lines = orgLines("text [fn:1] [fn:3] [fn:note-1] [fn:note-3:body]\n[fn:2] body\n[fn:note-2] body")
  doAssert newFootnoteLabel(lines) == "4"
  doAssert newFootnoteLabel(lines, "note-") == "note-4"
  doAssert newFootnoteLabel(lines, "脚注-") == "脚注-1"
  doAssert newFootnoteLabel(orgLines("text [fn:2]")) == "1"
  doAssert footnoteLabelUsed(lines, "note-3")
  doAssert not footnoteLabelUsed(lines, "4")

block insertion:
  for ending in ["", "\n"]:
    let original = orgLines("日本語本文" & ending)
    let inserted = insertFootnote(original, (0, 3), "1", "Footnotes")
    doAssert orgText(inserted.lines) == "日本語[fn:1]本文\n\n* Footnotes\n\n[fn:1] " & ending
    doAssert orgText(original) == "日本語本文" & ending
    doAssert inserted.reference == (0, 9) and inserted.body == (4, 7)
    let plain = insertFootnote(original, (0, 3), "組合", "")
    doAssert orgText(plain.lines) == "日本語[fn:組合]本文\n\n[fn:組合] " & ending
    doAssert plain.body == (2, 8) and plain.reference == (0, 10)
  let existing = orgLines("本文\n* Footnotes\n[fn:old] first\ncontinuation\n** Child\nbody\n* Next\nend\n")
  let inserted = insertFootnote(existing, (0, 2), "1", "Footnotes")
  doAssert orgText(inserted.lines) == "本文[fn:1]\n* Footnotes\n[fn:old] first\ncontinuation\n** Child\nbody\n\n[fn:1] \n\n* Next\nend\n"
  doAssert inserted.body == (7, 7)
  let padded = insertFootnote(orgLines("本文\n* Footnotes\n[fn:old] first\n\n\n* Next\n"), (0, 2), "1", "Footnotes")
  doAssert orgText(padded.lines) == "本文[fn:1]\n* Footnotes\n[fn:old] first\n\n[fn:1] \n\n\n* Next\n"
  doAssert padded.body == (4, 7)
  let earlier = insertFootnote(existing, (7, 3), "1", "Footnotes")
  doAssert earlier.reference == (10, 9)
  doAssert $earlier.lines[earlier.reference.line] == "end[fn:1]"
  let noSection = insertFootnote(orgLines("本文\n[fn:a] old\ncontinued\n\n\nend"), (5, 3), "2", "")
  doAssert orgText(noSection.lines) == "本文\n[fn:a] old\ncontinued\n\n[fn:2] \n\n\nend[fn:2]"
  doAssert noSection.body == (4, 7) and noSection.reference == (7, 9)
  let blank = insertFootnote(orgLines("本文\n\n"), (0, 2), "1", "脚注")
  doAssert orgText(blank.lines) == "本文[fn:1]\n\n* 脚注\n\n[fn:1] \n"
  let eof = insertFootnote(orgLines("本文\n"), (1, 0), "1", "Footnotes")
  doAssert orgText(eof.lines) == "本文\n[fn:1]\n\n* Footnotes\n\n[fn:1] \n"
  doAssert eof.reference == (1, 6)

block diagnostics:
  let lines = orgLines("text [fn:missing]\n[fn:old] old\n[fn:used] body\n[fn:used] duplicate\ntext [fn:used]\n[fn:] [fn: x] [fn:a b] [fn:a")
  let issues = footnoteIssues(lines)
  doAssert issues.mapIt(it.kind) == @[fiUndefined, fiUnreferenced, fiDuplicate,
    fiMalformed, fiMalformed, fiMalformed, fiMalformed]
  doAssert issues[0].line == 0 and issues[0].col == 5 and issues[0].label == "missing"
  doAssert issues[2].line == 3 and issues[2].message == "duplicate definition [fn:used]"
  let clean = orgLines("text [fn:a] [fn:名:本文] [fn::匿名] [fn:名]\n[fn:a] body")
  doAssert footnoteIssues(clean).len == 0
  doAssert footnoteIssues(orgLines("x [fn:名:body]\n[fn:名] duplicate"))[0].kind == fiDuplicate
  doAssert footnoteIssues(orgLines("[fn:x:unclosed [nested]"))[0].kind == fiMalformed

block numbering:
  let lines = orgLines("text [fn:z] [fn:z] [fn::anonymous] [fn:組合:inline] [fn:1]\n[fn:1] one\n[fn:z] z\n[fn:old] unused")
  doAssert footnoteNumber(lines, "z") == 1
  doAssert footnoteNumber(lines, "組合") == 3
  doAssert footnoteNumber(lines, "1") == 4
  doAssert footnoteNumber(lines, "old") == 0
  doAssert footnoteNumber(lines, "") == 0

echo "org footnotes ok"
