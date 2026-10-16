## Monkey and fuzz tests: random input into the pure modules, checking invariants and
## that nothing raises anything but the module's own errors.
##   nim r tests/tmonkey.nim [seeds] [steps]   (defaults 100 seeds x 600 steps: a few seconds)
import std/[random, unicode, strutils, os, tables]
import ../src/[termtext, termscreen, panes]
import ../src/[buffer, skk]

let seeds = if paramCount() >= 1: parseInt(paramStr(1)) else: 100
let steps = if paramCount() >= 2: parseInt(paramStr(2)) else: 600

const bufferCommands = ["forward", "backward", "next-line", "previous-line", "bol", "eol",
  "bob", "eob", "indent", "forward-word", "backward-word", "newline", "tab", "open-line",
  "delete", "backspace", "kill-line", "kill-word", "backward-kill-word", "mark", "exchange",
  "whole", "kill-region", "copy-region", "yank", "yank-pop", "undo", "transpose",
  "upcase", "downcase", "capitalize", "quit"]
const alphabet = ["a", "b", " ", "\n", "é", "界", "😀", "(", ")", "「", "\t", "x", "Z", "1"]

proc check(b: Buffer, trace: seq[string]) =
  doAssert b.lines.len >= 1, "no lines"
  doAssert b.cursor.line in 0..b.lines.high, "cursor line out of range: " & $b.cursor & " / " & $b.lines.len
  doAssert b.cursor.col in 0..b.lines[b.cursor.line].len, "cursor col out of range: " & $b.cursor
  if b.markSet:
    doAssert b.mark.line in 0..b.lines.high, "mark line out of range: " & $b.mark
    doAssert b.mark.col in 0..b.lines[b.mark.line].len, "mark col out of range: " & $b.mark
  doAssert b.offset(b.cursor) <= b.text.runeLen, "offset beyond text"
  doAssert b.point(b.offset(b.cursor)) == b.cursor, "offset/point roundtrip: " & $b.cursor

proc bufferMonkey(seed: int, steps: int) =
  var rng = initRand(seed)
  let b = newBuffer(if rng.rand(1.0) < 0.5: "" else: "hello world\nsecond line\n\n界é")
  let original = b.text
  var trace: seq[string]
  var edits = 0
  for i in 0..<steps:
    let op = rng.rand(1.0)
    if op < 0.3:
      let s = rng.sample(alphabet)
      trace.add "insert " & s.escape
      b.insert(s, selfInsert = rng.rand(1.0) < 0.5)
      inc edits
    else:
      let cmd = rng.sample(bufferCommands)
      trace.add cmd
      discard b.command(cmd, clipboard = "clip")
    try: b.check(trace)
    except AssertionDefect as e:
      echo "seed ", seed, " step ", i, ": ", e.msg
      echo "trace tail: ", trace[max(0, trace.len - 15)..^1].join(" | ")
      quit 1

proc skkMonkey(seed: int, steps: int) =
  var rng = initRand(seed)
  var dict: Dictionary
  dict["にほんご"] = @["日本語", "二本後"]
  dict["おくr"] = @["送", "贈"]
  dict["かんじ"] = @["漢字", "幹事", "感じ", "監事", "寛治", "莞爾", "完治", "官寺", "寒時"]
  let s = newSkk(dict)
  s.loaded = true
  discard s.toggle()
  let runes = "abcdefghijklmnopqrstuvwxyzNKOASDFJLQXZ;-~!?.,[]()/ 0".toRunes
  let keys = [skSpace, skEnter, skBackspace, skCtrlJ, skCtrlG, skTab]
  var trace: seq[string]
  for i in 0..<steps:
    var res: SkkResult
    let op = rng.rand(1.0)
    if op < 0.75:
      let r = rng.sample(runes)
      trace.add $r
      res = s.feed(r, Rune(')'))
    elif op < 0.97:
      let k = rng.sample(keys)
      trace.add $k
      res = s.feed(k)
    else:
      trace.add "toggle"
      res = s.toggle()
    try:
      doAssert res.move <= 0 and res.move >= -res.text.runeLen, "move out of inserted text: " & $res.move
      if s.stage == Choosing:
        doAssert s.candidates.len > 0, "choosing with no candidates"
        doAssert s.index in 0..<s.candidates.len, "index " & $s.index & " of " & $s.candidates.len
      if s.stage == Direct:
        doAssert s.reading.len == 0 and s.okuri.len == 0, "direct stage with reading left"
      if not s.enabled:
        doAssert s.stage == Direct and s.preedit.len == 0, "disabled but something pending"
      discard s.preedit; discard s.page; discard s.tag
    except AssertionDefect as e:
      echo "skk seed ", seed, " step ", i, ": ", e.msg
      echo "trace tail: ", trace[max(0, trace.len - 25)..^1].join(" ")
      quit 1

for seed in 1..seeds:
  try:
    bufferMonkey(seed, steps)
  except CatchableError, Defect:
    echo "buffer seed ", seed, " crashed: ", getCurrentExceptionMsg()
    quit 1
  try:
    skkMonkey(seed, steps)
  except CatchableError, Defect:
    echo "skk seed ", seed, " crashed: ", getCurrentExceptionMsg()
    quit 1
echo "ok: ", seeds, " seeds x ", steps, " steps for buffer and skk"

# Undo roundtrip: fewer than 200 edits, then undo until stable must restore the start.
proc undoMonkey(seed: int) =
  var rng = initRand(seed)
  let b = newBuffer("hello world\nsecond line\n\n界é")
  let original = b.text
  var trace: seq[string]
  for i in 0..<rng.rand(1..150):
    let op = rng.rand(1.0)
    if op < 0.4:
      let s = rng.sample(alphabet)
      trace.add "insert " & s.escape
      b.insert(s, selfInsert = rng.rand(1.0) < 0.5)
    else:
      let cmd = rng.sample(bufferCommands)
      if cmd == "undo": continue
      trace.add cmd
      discard b.command(cmd, clipboard = "clip")
  var rounds = 0
  while b.command("undo") != "No further undo information" and rounds < 400: inc rounds
  if b.text != original:
    echo "undo seed ", seed, ": text differs after full undo"
    echo "trace: ", trace.join(" | ")
    echo "got: ", b.text.escape
    quit 1

for seed in 1..seeds: undoMonkey(seed)
echo "ok: undo roundtrip for ", seeds, " seeds"

# Real dictionary: parse the user's SKK-JISYO.L and roundtrip the serializer.
let big = getHomeDir() / ".emacs.d/skk-get-jisyo/SKK-JISYO.L"
if fileExists(big):
  let d = parseDictionary(decodeDictionary(readFile(big)))
  let again = parseDictionary(serializeDictionary(d))
  doAssert d.len == again.len, "dictionary roundtrip lost entries: " & $d.len & " -> " & $again.len
  echo "ok: SKK-JISYO.L ", d.len, " entries roundtrip"

import ../src/[lisp, html]

var rng = initRand(7)
let lispTokens = ["(", ")", "'", "\"", "\\", "setq", "defun", "lambda", "let", "if", "cond",
  "while", "progn", "quote", "car", "cdr", "cons", "list", "nth", "length", "concat",
  "equal", "eq", "and", "or", "not", "message", "number-to-string", "x", "y", "f", "1", "2.5",
  "-3", "nil", "t", " ", "\n", ";comment\n", "界", "\"str", "((", "))"]
var lispErrors, lispOk: int
for seed in 1..max(seeds, 500):
  var src = ""
  for i in 0..<rng.rand(1..40): src.add rng.sample(lispTokens) & (if rng.rand(1.0) < 0.5: " " else: "")
  let interp = newInterp()
  try:
    discard interp.evalString(src, "<fuzz>")
    inc lispOk
  except LispError:
    inc lispErrors
  except CatchableError, Defect:
    echo "lisp seed ", seed, " crashed with ", getCurrentException().name, ": ", getCurrentExceptionMsg()
    echo src.escape
    quit 1
echo "ok: lisp ", lispOk + lispErrors, " programs (", lispOk, " evaluated, ", lispErrors, " LispError)"

let htmlTokens = ["<p>", "</p>", "<a href=\"", "<a href='x", "\">", "<pre>", "</pre>", "<ul>", "<li>",
  "</li>", "<ol start=3>", "<table><tr><td>", "</td>", "<br>", "<hr>", "<img alt=\"i\">", "<h1>",
  "</h1>", "<script>", "</script>", "<style>", "<!--", "-->", "<!DOCTYPE", "&amp;", "&#x", "&#1234567;",
  "&nbsp;", "&", "<", ">", "=", "\"", "'", "text", "日本語の文", "😀", "\xff\xfe", "\xc3", " ", "\n", "\t",
  "<base href=\"//h/", "<blockquote>", "</blockquote>", "<", "</", "<a", "</a>", "<title>", "<body"]
for seed in 1..max(seeds, 500):
  var src = ""
  for i in 0..<rng.rand(1..80): src.add rng.sample(htmlTokens)
  let width = rng.rand(1..120)
  try:
    let page = layout(src, "https://example.com/a/b", width)
    for line in page.lines:
      discard line
    discard feedLinks(src, "https://example.com/")
    discard looksLikeFeed(src, "text/html")
    discard charsetOf(src, "text/html")
    discard decodeDocument(src, "text/html; charset=shift_jis")
    discard decodeEntities(src)
    discard sanitizeUtf8(src)
  except CatchableError, Defect:
    echo "html seed ", seed, " width ", width, " crashed with ", getCurrentException().name, ": ", getCurrentExceptionMsg()
    echo src.escape
    quit 1
echo "ok: html ", max(seeds, 500), " documents"

# Terminal text and screen: random bytes, escapes and runes never raise, the cursor stays inside.
block terminals:
  var rng = initRand(11)
  let pieces = ["\x1b[", "\x1b]", "\x1b", "m", "H", "J", "K", "A", "B", "C", "D", "L", "M", "@", "P",
    "X", "r", "S", "T", "d", "G", "s", "u", ";", "?", "1049h", "1049l", "0", "3", "7", "31", "99",
    "255", "\r", "\n", "\b", "\t", "\a", "a", "Z", " ", "日", "\xe6", "\x97", "\xff", "\x7f", "\x1b7", "\x1b8", "\x1bM", "\x1bc"]
  for seed in 1..seeds:
    var t: TermText
    var s = initScreen(rng.rand(1..40), rng.rand(1..12))
    for i in 0..<steps:
      let chunk = rng.sample(pieces) & (if rng.rand(1.0) < 0.3: rng.sample(pieces) else: "")
      try:
        t.feed(chunk)
        s.feed(chunk)
        if rng.rand(1.0) < 0.02: s.resize(rng.rand(1..40), rng.rand(1..12))
        doAssert s.row in 0..<s.rows and s.col in 0..<s.cols, "screen cursor out of range"
        doAssert s.lines.len == s.rows and s.colors.len == s.rows, "screen rows mismatch"
        discard t.text; discard t.faces; discard s.text
      except CatchableError, Defect:
        echo "terminal seed ", seed, " step ", i, " crashed on ", chunk.escape, ": ", getCurrentExceptionMsg()
        echo "  screen ", s.cols, "x", s.rows, " cursor ", s.row, ",", s.col
        echo getCurrentException().getStackTrace()
        quit 1
  echo "ok: terminal text and screen, ", seeds, " seeds x ", steps, " steps"

# Window cells: any cell maps to a point inside the buffer.
block cells:
  var rng = initRand(12)
  for seed in 1..seeds:
    var lines: seq[seq[Rune]]
    for i in 0..<rng.rand(1..30): lines.add rng.sample(["", "short", "日本語テキスト", "a much longer line of text to scroll"]).toRunes
    var fold = newSeq[int8](lines.len)
    for i in 0..<fold.len: fold[i] = int8(rng.rand(0..2))
    fold[0] = 0
    for i in 0..<steps div 10:
      let p = pointAt(lines, fold, rng.rand(0..lines.high), rng.rand(0..20), rng.rand(0..6), rng.rand(0..60), rng.rand(0..40))
      doAssert p.line in 0..lines.high and p.col in 0..lines[p.line].len, "pointAt out of range: " & $p
  echo "ok: pointAt, ", seeds, " seeds"
