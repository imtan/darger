## Org structure as pure functions over rune lines: headlines, TODO keywords,
## checkboxes, list items, links and timestamps, for the editor's Org commands.
import std/[unicode, strutils, times]

type
  Headline* = object
    level*: int     # stars; 0 = not a headline
    todo*: string   # "" or the keyword
    title*: string  # after the keyword, before the tags
    tags*: string   # ":a:b:" or ""

const todoKeywords* = ["TODO", "DONE"]

proc stars(line: seq[Rune]): int =
  while result < line.len and line[result] == Rune('*'): inc result
  if result == 0 or result >= line.len or line[result] != Rune(' '): return 0

proc isHeadline*(line: seq[Rune]): bool = stars(line) > 0

proc headline*(line: seq[Rune]): Headline =
  result.level = stars(line)
  if result.level == 0: return
  var rest = strutils.strip($line[result.level+1..^1])
  for k in todoKeywords:
    if rest == k or rest.startsWith(k & " "):
      result.todo = k
      rest = strutils.strip(rest[k.len..^1])
      break
  let sp = rest.rfind(' ')
  let last = if sp >= 0: rest[sp+1..^1] else: rest
  if last.len >= 3 and last[0] == ':' and last[^1] == ':':
    result.tags = last
    rest = if sp >= 0: strutils.strip(rest[0..<sp]) else: ""
  result.title = rest

proc subtreeEnd*(lines: seq[seq[Rune]], n: int): int =
  ## The last line of the subtree headed at line n (n itself when it is no headline).
  result = n
  let level = stars(lines[n])
  if level == 0: return
  for i in n+1..lines.high:
    let l = stars(lines[i])
    if l > 0 and l <= level: break
    result = i

proc headlineAbove*(lines: seq[seq[Rune]], n: int): int =
  ## The headline at or above line n, -1 before the first one.
  result = n
  while result >= 0 and not isHeadline(lines[result]): dec result

proc cycleTodo*(line: seq[Rune]): seq[Rune] =
  ## none -> TODO -> DONE -> none, keeping the rest of the line as it is.
  let h = headline(line)
  if h.level == 0: return line
  let at = todoKeywords.find(h.todo)
  let next = if at < 0: todoKeywords[0] elif at == todoKeywords.high: "" else: todoKeywords[at+1]
  let s = $line
  var i = h.level + 1
  while i < s.len and s[i] == ' ': inc i
  var tail = if h.todo.len > 0: s[i + h.todo.len .. ^1] else: s[i .. ^1]
  if h.todo.len > 0 and tail.len > 0 and tail[0] == ' ': tail = tail[1..^1]
  (s[0..<i] & (if next.len > 0: next & (if tail.len > 0: " " else: "") else: "") & tail).toRunes

proc shiftLevel*(line: seq[Rune], delta: int): seq[Rune] =
  ## The headline promoted (delta < 0) or demoted; unchanged when not a headline or at level 1.
  let level = stars(line)
  if level == 0 or level + delta < 1: return line
  (repeat('*', level + delta) & $line[level..^1]).toRunes

proc itemStart(s: string): tuple[bullet: string, next: int] =
  ## A list item's bullet ("-", "+", "3." ...) and the index after the space following it.
  var i = 0
  while i < s.len and s[i] in {' ', '\t'}: inc i
  var j = i
  if j < s.len and s[j] in {'-', '+'}: inc j
  else:
    while j < s.len and s[j] in {'0'..'9'}: inc j
    if j == i or j >= s.len or s[j] notin {'.', ')'}: return ("", -1)
    inc j
  if j >= s.len or s[j] != ' ': return ("", -1)
  (s[i..<j], j + 1)

proc toggleCheckbox*(line: seq[Rune]): seq[Rune] =
  ## '- [ ] x' <-> '- [X] x' on a list item; the line unchanged without a checkbox.
  let s = $line
  let (bullet, j) = itemStart(s)
  if bullet.len == 0 or j + 2 >= s.len or s[j] != '[' or s[j+2] != ']' or
      s[j+1] notin {' ', 'X', 'x', '-'}: return line
  (s[0..<j] & (if s[j+1] == ' ': "[X]" else: "[ ]") & s[j+3..^1]).toRunes

proc newItemPrefix*(line: seq[Rune]): string =
  ## What M-RET starts the next line with after `line`: a headline's stars, a list
  ## item's indentation and bullet (numbers advance, a checkbox comes empty), or "".
  let level = stars(line)
  if level > 0: return repeat('*', level) & " "
  let s = $line
  let (bullet, j) = itemStart(s)
  if bullet.len == 0: return ""
  var i = 0
  while i < s.len and s[i] in {' ', '\t'}: inc i
  var next = bullet
  if bullet[0] in {'0'..'9'}: next = $(parseInt(bullet[0..^2]) + 1) & bullet[^1]
  result = s[0..<i] & next & " "
  if j + 2 < s.len and s[j] == '[' and s[j+2] == ']': result.add "[ ] "

proc linkAt*(line: seq[Rune], col: int): tuple[target, desc: string] =
  ## The [[target][desc]] or [[target]] link around column col, else ("", "").
  var i = 0
  while i + 1 < line.len:
    if line[i] == Rune('[') and line[i+1] == Rune('['):
      var j = i + 2
      while j + 1 < line.len and not (line[j] == Rune(']') and line[j+1] == Rune(']')): inc j
      if j + 1 >= line.len: return
      if col >= i and col <= j + 1:
        let inner = $line[i+2..<j]
        let sep = inner.find("][")
        return if sep >= 0: (inner[0..<sep], inner[sep+2..^1]) else: (inner, "")
      i = j + 2
    else: inc i

proc timestamp*(t: DateTime, active = true): string =
  ## <2026-10-07 Tue>, or [2026-10-07 Tue] when inactive.
  let s = t.format("yyyy-MM-dd ddd")
  if active: "<" & s & ">" else: "[" & s & "]"

proc outline*(lines: seq[seq[Rune]]): seq[tuple[line: int, text: string]] =
  for n, l in lines:
    if stars(l) > 0: result.add (n, $l)

proc keyword*(lines: seq[seq[Rune]], key: string): string =
  ## The value of the first '#+key: value' line (key in any case), "" when absent.
  for l in lines:
    let s = $l
    if s.len > key.len + 2 and s.startsWith("#+") and s[2..<2+key.len].toLowerAscii == key.toLowerAscii and
        s[2+key.len] == ':':
      return strutils.strip(s[3+key.len..^1])

proc property*(lines: seq[seq[Rune]], key: string): string =
  ## ':KEY: value' from the property drawer at the top of the file, "" when absent.
  var i = 0
  while i < lines.len and lines[i].len == 0: inc i
  if i >= lines.len or ($lines[i]).strip.toUpperAscii != ":PROPERTIES:": return
  for n in i+1..lines.high:
    let s = ($lines[n]).strip
    if s.toUpperAscii == ":END:": return
    let tag = ":" & key.toUpperAscii & ":"
    if s.toUpperAscii.startsWith(tag): return strutils.strip(s[tag.len..^1])

# ---- Folding: which lines a set of folded headlines hides

type
  FoldKind* = enum fkSubtree, fkBody  ## hide the whole subtree / only the text before the next headline
  Fold* = object
    line*: int
    kind*: FoldKind
    text*: seq[Rune]  ## the headline when folded, to find it again after edits

proc fold*(lines: seq[seq[Rune]], n: int, kind = fkSubtree): Fold =
  Fold(line: n, kind: kind, text: lines[n])

proc bodyEnd*(lines: seq[seq[Rune]], n: int): int =
  ## The last line before the next headline of any level.
  result = n
  for i in n+1..lines.high:
    if isHeadline(lines[i]): break
    result = i

proc foldEnd*(lines: seq[seq[Rune]], f: Fold): int =
  if f.kind == fkSubtree: subtreeEnd(lines, f.line) else: bodyEnd(lines, f.line)

proc children*(lines: seq[seq[Rune]], n: int): seq[int] =
  ## The direct child headlines of the headline at n (a skipped level still counts).
  var childLevel = 0
  for i in n+1..subtreeEnd(lines, n):
    let l = stars(lines[i])
    if l == 0: continue
    if childLevel == 0 or l <= childLevel:
      childLevel = l
      result.add i

proc foldMap*(lines: seq[seq[Rune]], folds: seq[Fold]): seq[int8] =
  ## Per line: 0 shown, 1 hidden, 2 a shown headline with hidden lines after it.
  result = newSeq[int8](lines.len)
  for f in folds:
    if f.line notin 0..lines.high or not isHeadline(lines[f.line]): continue
    let z = foldEnd(lines, f)
    if z == f.line: continue
    if result[f.line] == 0: result[f.line] = 2
    for i in f.line+1..z: result[i] = 1

proc remapFolds*(folds: seq[Fold], lines: seq[seq[Rune]], delta: int): seq[Fold] =
  ## After an edit that changed the line count by delta, finds every fold's headline
  ## again: in place, moved by delta, or (with the count unchanged) edited in place.
  ## A fold whose headline cannot be found is dropped, so its text shows.
  var seen: seq[int]
  for f in folds:
    var g = f
    if f.line in 0..lines.high and lines[f.line] == f.text: discard
    elif f.line + delta in 0..lines.high and lines[f.line + delta] == f.text: g.line = f.line + delta
    elif delta == 0 and f.line in 0..lines.high and isHeadline(lines[f.line]): g.text = lines[f.line]
    else: continue
    if g.line in seen: continue
    seen.add g.line
    result.add g

proc foldState*(lines: seq[seq[Rune]], folds: seq[Fold], n: int): string =
  ## What TAB on headline n shows now: FOLDED, CHILDREN (something below is hidden) or SUBTREE.
  let z = subtreeEnd(lines, n)
  for f in folds:
    if f.line == n and f.kind == fkSubtree: return "FOLDED"
  for f in folds:
    if f.line in n..z and foldEnd(lines, f) > f.line: return "CHILDREN"
  "SUBTREE"

proc cycleFold*(lines: seq[seq[Rune]], folds: seq[Fold], n: int): tuple[folds: seq[Fold], state: string] =
  ## Like org-cycle on headline n: FOLDED -> CHILDREN -> SUBTREE -> FOLDED, where
  ## CHILDREN shows the entry's text and its child headlines folded. A headline
  ## without children goes FOLDED -> SUBTREE. State "" means there is nothing to fold.
  let z = subtreeEnd(lines, n)
  if z == n: return (folds, "")
  for f in folds:
    if f.line notin n..z: result.folds.add f
  let kids = children(lines, n)
  case foldState(lines, folds, n)
  of "FOLDED":
    if kids.len == 0: result.state = "SUBTREE"
    else:
      for c in kids: result.folds.add fold(lines, c)
      result.state = "CHILDREN"
  of "CHILDREN": result.state = "SUBTREE"
  else:
    result.folds.add fold(lines, n)
    result.state = "FOLDED"

proc globalFolds*(lines: seq[seq[Rune]], state: string): seq[Fold] =
  ## Like org-shifttab: OVERVIEW folds every top-level headline, CONTENTS hides the
  ## text under every headline, "SHOW ALL" folds nothing.
  case state
  of "OVERVIEW":
    var level = 0
    for n, l in lines:
      let s = stars(l)
      if s == 0: continue
      if level == 0 or s < level:  # the first headline sets the top level; a shallower one takes over
        level = s
        result = @[]
      if s == level: result.add fold(lines, n)
  of "CONTENTS":
    for n, l in lines:
      if isHeadline(l): result.add fold(lines, n, fkBody)
  else: discard

proc startupState*(lines: seq[seq[Rune]]): string =
  ## The global state '#+startup:' asks for: OVERVIEW (folded / overview), CONTENTS
  ## (content / contents), else "SHOW ALL".
  for word in keyword(lines, "startup").toLowerAscii.split:
    case word
    of "folded", "overview": return "OVERVIEW"
    of "content", "contents": return "CONTENTS"
    of "showall", "showeverything", "nofold": return "SHOW ALL"
  "SHOW ALL"

proc openTowards(lines: seq[seq[Rune]], n, line: int, result: var seq[Fold]) =
  # Opens the subtree at n just enough to show `line`: the other children stay folded.
  for c in children(lines, n):
    if line > c and line <= subtreeEnd(lines, c): openTowards(lines, c, line, result)
    else: result.add fold(lines, c)

proc revealFolds*(lines: seq[seq[Rune]], folds: seq[Fold], line: int): seq[Fold] =
  ## The folds with `line` shown, like org-show-context: a subtree hiding it opens
  ## down to it with the sibling subtrees on the way still folded.
  for f in folds:
    if line > f.line and line <= foldEnd(lines, f):
      if f.kind == fkSubtree: openTowards(lines, f.line, line, result)
    else: result.add f

# ---- Journal and capture: strftime for org-journal's formats, and where captured text goes

const
  weekdaysJa = ["日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日"]
  weekdaysShortJa = ["日", "月", "火", "水", "木", "金", "土"]

proc strftime*(fmt: string, t: DateTime, japanese = false): string =
  ## The strftime subset org-journal formats use: %Y %y %m %d %e %H %M %S %R %A %a %B
  ## %b %j %%. With `japanese`, %A/%a are 火曜日/火 and %B/%b 10月, as Emacs gives
  ## under a Japanese locale. Anything else stays as typed.
  var i = 0
  while i < fmt.len:
    if fmt[i] != '%' or i + 1 >= fmt.len:
      result.add fmt[i]
      inc i
      continue
    let c = fmt[i+1]
    i += 2
    case c
    of 'Y': result.add t.format("yyyy")
    of 'y': result.add t.format("yy")
    of 'm': result.add t.format("MM")
    of 'd': result.add t.format("dd")
    of 'e': result.add align($t.monthday, 2)
    of 'H': result.add t.format("HH")
    of 'M': result.add t.format("mm")
    of 'S': result.add t.format("ss")
    of 'R': result.add t.format("HH:mm")
    of 'j': result.add align($(t.yearday + 1), 3, '0')  # yearday counts from 0
    of 'A': result.add (if japanese: weekdaysJa[ord(t.weekday) + 1 mod 7] else: t.format("dddd"))
    of 'a': result.add (if japanese: weekdaysShortJa[ord(t.weekday) + 1 mod 7] else: t.format("ddd"))
    of 'B', 'b': result.add (if japanese: $ord(t.month) & "月" elif c == 'B': t.format("MMMM") else: t.format("MMM"))
    of '%': result.add '%'
    else: result.add '%' & c

proc appendedText*(text, entry: string): string =
  ## text with entry on a line of its own at the end.
  result = text
  if result.len > 0 and result[^1] != '\n': result.add '\n'
  result.add entry

proc insertUnder*(text, title, entry: string): tuple[text: string, at: int] =
  ## entry added at the end of the subtree of the headline titled `title` (created at
  ## the end of the file when missing), or at the end of the file when title is "".
  ## `at` is the byte offset where entry begins.
  var lines: seq[seq[Rune]]
  for l in text.split('\n'): lines.add l.toRunes
  if text.len > 0 and text[^1] == '\n': lines.setLen(lines.len - 1)
  var head = -1
  if title.len > 0:
    for n, l in lines:
      if isHeadline(l) and headline(l).title == title:
        head = n
        break
    if head < 0:
      let base = appendedText(text, "* " & title & "\n")
      return (base & entry, base.len)
  let last = if head < 0: lines.high else: subtreeEnd(lines, head)
  var before = ""
  for n in 0..last: before.add $lines[n] & "\n"
  var after = ""
  for n in last+1..lines.high: after.add $lines[n] & "\n"
  if text.len > 0 and text[^1] != '\n' and after.len > 0: after.setLen(after.len - 1)
  if text.len > 0 and text[^1] != '\n' and after.len == 0: before.setLen(before.len - 1); before.add "\n"
  (before & entry & after, before.len)

proc fillTemplate*(tmpl, text: string, t: DateTime): string =
  ## org-capture's %? takes the typed text; %t / %u are today's active / inactive
  ## timestamp, %T / %U with the time; %% a percent sign.
  var i = 0
  while i < tmpl.len:
    if tmpl[i] != '%' or i + 1 >= tmpl.len:
      result.add tmpl[i]
      inc i
      continue
    let c = tmpl[i+1]
    i += 2
    case c
    of '?': result.add text
    of 't': result.add timestamp(t)
    of 'u': result.add timestamp(t, active = false)
    of 'T': result.add "<" & t.format("yyyy-MM-dd ddd HH:mm") & ">"
    of 'U': result.add "[" & t.format("yyyy-MM-dd ddd HH:mm") & "]"
    of '%': result.add '%'
    else: result.add '%' & c
