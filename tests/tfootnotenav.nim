{.define: headless.}
import std/[os, strutils, unicode, tables, tempfiles, options]
import ../src/[core, buffer, buffers, render, lisp, lsp, syntax, orgmode, orgfootnote]
import ../src/ext/[org, orgfootnote, langserver]

let home = createTempDir("darger-footnote-", "")
putEnv("HOME", home) # no real init, history or server logs
renderer = Renderer(frameCols: 100, frameRows: 40)
layoutPanes()
proc eval(s: string) = discard interp.evalString(s, "<test>")
eval(defaultBindings)
for source in defaults: eval(source)

proc openText(text: string, path = "notes.org"): Buffer =
  result = newBuffer(text)
  result.path = home / path
  switchTo(result)
  mode = ""
  xrefStack = @[]
  hoverActive = false

block insertionAndUndo:
  discard openText("日本語本文\n")
  doAssert lang.name == "Org"
  b.cursor = (0, 3)
  let before = b.text
  eval("(org-footnote-insert)")
  doAssert b.text == "日本語[fn:1]本文\n\n* Footnotes\n\n[fn:1] \n"
  doAssert b.cursor == (4, 7) and b.last == "edit"
  doAssert echoLine == "Footnote [fn:1]"
  eval("(undo)")
  doAssert b.text == before and b.cursor == (0, 3)
  b.insert("追記")
  doAssert b.text == "日本語追記本文\n"
  eval("(org-footnote-insert)")
  b.insert("脚注の本文")
  doAssert $b.lines[b.cursor.line] == "[fn:1] 脚注の本文"
  b.cursor = (0, b.lines[0].len)
  eval("(org-footnote-insert)")
  doAssert ($b.lines[0]).endsWith("[fn:2]") and echoLine == "Footnote [fn:2]"
  b.insert("第二の脚注")
  doAssert b.text.contains("[fn:1] 脚注の本文\n\n[fn:2] 第二の脚注")
  let tmp = home / "saved.org"
  b.path = tmp
  b.save()
  doAssert loadBuffer(tmp).text == b.text

block navigation:
  let origin = openText("日本語 [fn:組合] と [fn:組合]\n\n* Footnotes\n[fn:組合] 日本語の本文\n続き\n")
  for col in [4, 11, 14]:  # on the first marker, just after it, on the second
    b.cursor = (0, col)
    let point = b.cursor
    eval("(org-footnote-jump)")
    doAssert b.cursor == (3, 8) and xrefStack.len == 1
    xrefBack()
    doAssert b == origin and b.cursor == point and xrefStack.len == 0
  b.cursor = (3, 0)
  eval("(org-footnote-jump)")
  doAssert b.cursor == (0, 4) and xrefStack.len == 1
  xrefBack()
  doAssert b.cursor == (3, 0)
  eval("(org-footnote-preview)")
  doAssert hoverActive and hoverBuf == b and hoverTop == 0
  doAssert hoverText[0] == "[fn:組合] (1)"
  doAssert hoverText.join("\n").contains("日本語の本文\n続き")
  b.cursor = (0, 4)
  eval("(org-footnote-preview)")
  doAssert hoverActive and hoverText[0].contains("組合")
  eval("(org-footnote-check)")
  doAssert echoLine == "Footnotes OK: 2 references, 1 definitions"

block consult:
  let origin = openText("日本語 [fn:missing] [fn:x]\n[fn:x] one\n[fn:x] two")
  b.cursor = (0, 0)
  eval("(org-footnote-check)")
  doAssert mode == "footnote-check" and targets.len == 2
  doAssert refRows[0].contains("undefined reference [fn:missing]")
  doAssert refRows[1].contains("duplicate definition [fn:x]")
  doAssert b.cursor == (0, 4)
  moveCandidate(1, true)
  doAssert b.cursor == (2, 0)
  abandonLine()
  doAssert mode == "" and b == origin and b.cursor == (0, 0)
  eval("(org-footnote-check)")
  moveCandidate(1, true)
  confirmMini()
  doAssert mode == "" and b.cursor == (2, 0) and xrefStack.len == 1
  xrefBack()
  doAssert b.cursor == (0, 0)

block settings:
  discard openText("本文\n")
  b.cursor = (0, 2)
  eval("(setq org-footnote-section \"脚注\")")
  eval("(setq org-footnote-auto-label \"note-\")")
  eval("(org-footnote-insert)")
  doAssert b.text.contains("本文[fn:note-1]") and b.text.contains("* 脚注")
  b.insert("説明")
  eval("(setq org-footnote-section nil)")
  b.cursor = (0, b.lines[0].len)
  eval("(org-footnote-insert)")
  doAssert b.text.contains("[fn:note-1] 説明\n\n[fn:note-2] ")
  eval("(setq org-footnote-auto-label nil)")
  b.cursor = (0, b.lines[0].len)
  let before = b.text
  eval("(org-footnote-insert)")
  doAssert mode == "footnote-label" and prompt == "Footnote label: "
  for invalid in ["", "bad label", "note-1"]:
    setMini(invalid)
    confirmMini()
    doAssert mode == "footnote-label" and b.text == before
    doAssert echoLine.len > 0
  setMini("組合")
  confirmMini()
  doAssert mode == "" and b.text.contains("[fn:組合]")
  doAssert b.cursor.col == 8
  eval("(undo)")
  doAssert b.text == before
  eval("(setq org-footnote-auto-label t)")
  eval("(setq org-footnote-section \"Footnotes\")")

block promptLifecycle:
  discard openText("本文")
  b.cursor = (0, 2)
  eval("(setq org-footnote-auto-label nil)")
  eval("(org-footnote-insert)")
  dispatch("C-g")
  doAssert mode == "" and b.text == "本文" and b.cursor == (0, 2)
  eval("(org-footnote-insert)")
  b.insert("変更")
  setMini("name")
  confirmMini()
  doAssert mode == "" and b.text == "本文変更"
  doAssert echoLine == "Buffer changed; run the footnote command again"
  eval("(setq org-footnote-auto-label \"bad prefix\")")
  eval("(org-footnote-insert)")
  doAssert b.text == "本文変更" and echoLine == "Invalid footnote label prefix"
  eval("(setq org-footnote-auto-label t)")

block actionAndErrors:
  discard openText("本文")
  b.cursor = (0, 2)
  eval("(press-key \"C-c C-x f\")")
  doAssert b.text.contains("本文[fn:1]")
  b.insert("body")
  b.cursor = (0, 2)
  eval("(org-footnote-action)")
  doAssert b.cursor == (4, 7)
  let before = b.text
  eval("(org-footnote-insert)")
  doAssert b.text == before and echoLine.contains("definition line")
  b.cursor = (0, 3)
  eval("(org-footnote-insert)")
  doAssert b.text == before and echoLine == "Already on a footnote"
  b.cursor = (0, 8)  # just after "[fn:1]": a second reference may follow, as in Emacs
  eval("(org-footnote-insert)")
  doAssert ($b.lines[0]).startsWith("本文[fn:1][fn:2]") and b.cursor == (6, 7)
  eval("(undo)")
  doAssert b.text == before
  discard openText("text [fn:missing]\n[fn:old] body\ntext [fn::匿名 [補足]]")
  for (point, message) in [((0, 6), "No definition for [fn:missing]"),
      ((1, 0), "No reference to [fn:old]"), ((0, 0), "No footnote at point"),
      ((2, 6), "Inline footnote has no separate definition")]:
    b.cursor = point
    eval("(org-footnote-jump)")
    doAssert echoLine == message and b.cursor == point and xrefStack.len == 0
  eval("(org-footnote-preview)")
  doAssert hoverText == @["匿名 [補足]"]
  b.cursor = (0, 6)
  eval("(org-footnote-preview)")
  doAssert echoLine == "No definition for [fn:missing]"
  discard openText("text [fn:名]\ntext [fn:名:本文]")
  b.cursor = (0, 6)
  eval("(org-footnote-preview)")
  doAssert hoverText == @["[fn:名] (1)", "本文"]
  eval("(org-footnote-jump)")
  doAssert b.cursor == (1, 11)

block notOrg:
  discard openText("text", "plain.txt")
  for command in ["insert", "jump", "action", "preview", "check"]:
    eval("(org-footnote-" & command & ")")
    doAssert echoLine == "Not an Org buffer" and b.text == "text"

echo "org footnote navigation, preview, consult, undo and save ok"
