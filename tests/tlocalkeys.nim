{.define: headless.}
import std/[tables, sets, unicode]
import ../src/[core, buffer, buffers, lisp, render, skk, syntax]
import ../src/ext/agent

renderer = Renderer(frameCols: 100, frameRows: 40)
layoutPanes()
proc eval(s: string) = discard interp.evalString(s, "<test>")
eval(defaultBindings)
for source in defaults: eval(source)
eval("(setq understanding-ledger nil)")
let original = newBuffer("one\ntwo\nthree\n")
switchTo(original)

block keys:
  eval("(local-set-key \"n\" 'next-line)")
  eval("(type-string \"n\")")
  doAssert b.cursor.line == 1 and b.text == "one\ntwo\nthree\n"
  eval("(local-set-key \"C-z z\" (lambda () (message \"local prefix\")))")
  eval("(press-key \"C-z z\")")
  doAssert echoLine == "local prefix"
  eval("(local-set-key \"C-f\" 'backward)")
  b.cursor = (1, 1)
  eval("(press-key \"C-f\")")
  doAssert b.cursor == (1, 0)
  let other = newBuffer("other")
  switchTo(other)
  eval("(type-string \"n\")")
  doAssert b.text == "nother"
  switchTo(original)
  clearLocalKeys(original)

block readonly:
  eval("(buffer-read-only t)")
  let before = b.text
  for name in ["newline", "tab", "indent", "open-line", "delete", "backspace", "kill-line",
      "kill-word", "backward-kill-word", "kill-region", "yank", "yank-pop", "clipboard-yank",
      "undo", "transpose", "upcase", "downcase", "capitalize"]:
    eval("(" & name & ")")
    doAssert echoLine == "Buffer is read-only", name
    doAssert b.text == before, name
  eval("(type-string \"あz\")")
  doAssert b.text == before and echoLine == "Buffer is read-only"
  discard applySkk(SkkResult(text: "漢字", consumed: true))
  doAssert b.text == before and echoLine == "Buffer is read-only"
  eval("(press-key \"C-n\")")
  doAssert b.cursor.line == 2
  dispatch("C-s")
  eval("(type-string \"two\")")
  doAssert mini.text == "two" and b.text == before
  dispatch("C-g")
  eval("(buffer-read-only nil)")
  doAssert not b.isReadOnly

block reviewBuffer:
  renderer.top = 1
  beginReview("one\nTWO\nthree\n")
  let display = reviewBuf
  doAssert b == display and reviewTarget == original and display.path == ""
  doAssert reg.byName("*review*") == display and display.isReadOnly
  doAssert "review" notin modes
  doAssert facesOf(display).len > 0
  dispatch("C-n")
  let point = b.cursor
  doAssert currentHunk == 0
  let other = newBuffer("elsewhere")
  switchTo(other)
  eval("(review-take)")
  doAssert echoLine == "No review is open" and reviewOpen()
  switchTo(display)
  doAssert b.cursor == point
  dispatch("M-x")
  eval("(type-string \"review-take\")")
  eval("(exit-minibuffer)")
  doAssert reviewOpen()
  eval("(press-key \"enter\")")
  doAssert b == original and b.text == "one\nTWO\nthree\n"
  doAssert not reviewOpen() and display notin reg
  doAssert display notin localKeys and display notin readOnly

block cancelAndKill:
  beginReview("replacement")
  let display = reviewBuf
  eval("(press-key \"C-g\")")
  doAssert not reviewOpen() and b == original and display notin reg
  beginReview("replacement")
  killBuffer(reviewBuf)
  doAssert not reviewOpen() and b == original
  beginReview("replacement")
  killBuffer(original)
  doAssert not reviewOpen() and original notin reg

block sidesAndHunk:
  let target = newBuffer("before\n")
  switchTo(target)
  beginReview("after\n")
  let display = reviewBuf
  eval("(type-string \"|\")")
  doAssert b.isReadOnly and b != display and reviewCurrent()
  eval("(press-key \"C-x o\")")
  doAssert reviewCurrent()
  eval("(type-string \"|\")")
  doAssert b == display
  eval("(type-string \"e\")")
  doAssert reg.displayName(b) == "*hunk*" and not b.isReadOnly
  doAssert prefix.len == 0, prefix
  eval("(type-string \"edited \")")
  doAssert b.text == "edited after\n", repr(b.text)
  eval("(press-key \"C-c C-c\")")
  doAssert b == display
  eval("(type-string \"a\")")
  doAssert b == target and b.text == "edited after\n", repr(b.text) & " " & echoLine

echo "local keys, read-only input, review lifecycle, sides and hunk editing ok"

block promptsAndGlobalKeys:
  let target = newBuffer("before\n")
  switchTo(target)
  beginReview("after\n")
  let display = reviewBuf
  for chord in ["C-x b", "C-x C-f", "M-x"]:
    eval("(press-key \"" & chord & "\")")
    doAssert inMini()
    let initial = mini.text
    eval("(type-string \"npy\")")
    doAssert mini.text == initial & "npy" and reviewOpen()
    dispatch("C-g")
    doAssert b == display and reviewOpen()
  for key in ["X", "r", "l"]:
    dispatch(key)
    doAssert inMini() and prompts[mode].over == ""
    dispatch("C-g")
    doAssert reviewOpen()
  eval("(setq agent-command \"\")")
  dispatch("X")
  eval("(type-string \"why\")")
  eval("(exit-minibuffer)")
  doAssert echoLine == "agent-command is empty" and reviewOpen()
  dispatch("r")
  eval("(type-string \"revise\")")
  eval("(exit-minibuffer)")
  doAssert echoLine == "agent-command is empty" and reviewOpen()
  dispatch("l")
  eval("(exit-minibuffer)")
  doAssert b == display and mode == ""
  dispatch("C-g")

block prefixCleanup:
  let target = newBuffer()
  switchTo(target)
  eval("(local-set-key \"z z\" (lambda () (message \"typed prefix\")))")
  eval("(type-string \"zz\")")
  doAssert echoLine == "typed prefix" and b.text == ""
  clearLocalKeys(target)
  eval("(type-string \"z\")")
  doAssert b.text == "z"
  setReadOnly(target, true)
  killBuffer(target)
  doAssert target notin localKeys and not target.isReadOnly

echo "review prompts, global commands and local prefix cleanup ok"

block localHydraAndCancel:
  eval("(hydra \"f2\" \"test\")")
  eval("(local-set-key \"f2 z\" (lambda () (message \"local hydra\")))")
  eval("(press-key \"f2 z\")")
  doAssert prefix == "f2"
  dispatch("C-g")
  eval("(local-set-key \"C-z C-g\" (lambda () (message \"local cancel\")))")
  eval("(press-key \"C-z C-g\")")
  doAssert echoLine == "local cancel"
  clearLocalKeys(b)

block comparison:
  let target = newBuffer("after\n")
  switchTo(target)
  beginComparison("before\n", "test")
  let display = reviewBuf
  dispatch("y")
  doAssert b == display and target.text == "after\n"
  dispatch("q")
  doAssert b == target and not reviewOpen()

echo "local hydra/cancel chords and comparison ok"

block replacingReview:
  let first = newBuffer("first")
  switchTo(first)
  beginReview("FIRST")
  let old = reviewBuf
  let second = newBuffer("second")
  switchTo(second)
  var returned = false
  afterReview = proc() = returned = true
  beginComparison("SECOND", "test")
  doAssert reviewTarget == second and old notin reg and not returned
  dispatch("q")
  doAssert returned and b == second

echo "replacement review target and return hook ok"
