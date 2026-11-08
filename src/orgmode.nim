## Org structure as pure functions over rune lines: headlines, TODO keywords,
## checkboxes, list items, links and timestamps, for the editor's Org commands.
import std/[unicode, strutils, times, algorithm, os]

type
  Headline* = object
    level*: int     # stars; 0 = not a headline
    todo*: string   # "" or the keyword
    title*: string  # after the keyword, before the tags
    tags*: string   # ":a:b:" or ""
    priority*: char # A/B/C, or NUL when no cookie

var
  todoKeywords* = @["TODO", "DONE"]  ## the sequence C-c C-t cycles, active then done words
  doneKeywords* = @["DONE"]          ## the words after "|" in org-todo-keywords: finished
  todoKeys*: seq[(string, char)]     ## fast-selection keys, from "WORD(k)" in the spec

proc setTodoKeywords*(spec: seq[string]) =
  ## `("TODO(t)" "NEXT(n)" "WAITING(w)" "|" "DONE(d)")`: words before "|" are active,
  ## after it done (the last word when there is no "|"); "(k)" gives a selection key.
  var words, done: seq[string]
  var keys: seq[(string, char)]
  var afterBar = false
  for item in spec:
    if item == "|":
      afterBar = true
      continue
    var word = item
    let paren = item.find('(')
    if paren > 0 and item.endsWith(")") and item.len >= paren + 3:
      word = item[0..<paren]
      keys.add (word, item[paren+1])
    if word.len == 0: continue
    words.add word
    if afterBar: done.add word
  if words.len == 0: return
  if done.len == 0 and words.len > 1: done.add words[^1]
  todoKeywords = words
  doneKeywords = done
  todoKeys = keys

proc isDone*(todo: string): bool = todo in doneKeywords

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
  if rest.len >= 4 and rest[0..1] == "[#" and rest[2] in {'A'..'C'} and
      rest[3] == ']' and (rest.len == 4 or rest[4] == ' '):
    result.priority = rest[2]
    rest = strutils.strip(rest[4..^1])
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

proc withTodo*(line: seq[Rune], next: string): seq[Rune] =
  ## The headline with its TODO keyword replaced by `next` ("" removes it), the rest as it is.
  let h = headline(line)
  if h.level == 0: return line
  let s = $line
  var i = h.level + 1
  while i < s.len and s[i] == ' ': inc i
  var tail = if h.todo.len > 0: s[i + h.todo.len .. ^1] else: s[i .. ^1]
  if h.todo.len > 0 and tail.len > 0 and tail[0] == ' ': tail = tail[1..^1]
  (s[0..<i] & (if next.len > 0: next & (if tail.len > 0: " " else: "") else: "") & tail).toRunes

proc withPriority*(line: seq[Rune], priority: char): seq[Rune] =
  let h = headline(line)
  if h.level == 0: return line
  if priority notin {'A'..'C', '\0'}: raise newException(ValueError, "Priority must be A, B or C")
  var i = h.level + 1
  while i < line.len and line[i] == Rune(' '): inc i
  if h.todo.len > 0:
    i += h.todo.len
    while i < line.len and line[i] == Rune(' '): inc i
  var z = i
  if h.priority != '\0':
    z += 4
    if z < line.len and line[z] == Rune(' '): inc z
  var prefix = $line[0..<i]
  if priority != '\0' and prefix.len > 0 and prefix[^1] != ' ': prefix.add ' '
  (prefix & (if priority == '\0': "" else: "[#" & priority & "]" &
    (if z < line.len: " " else: "")) & $line[z..^1]).toRunes

proc cyclePriority*(line: seq[Rune], up: bool, repeated = false): seq[Rune] =
  let p = headline(line).priority
  # Org starts an absent cookie at the default B; cycling beyond either end removes it.
  let next = if p == '\0': (if repeated: (if up: 'C' else: 'A') else: 'B')
    elif up: (if p == 'A': '\0' else: pred(p))
    else: (if p == 'C': '\0' else: succ(p))
  withPriority(line, next)

proc cycleTodo*(line: seq[Rune]): seq[Rune] =
  ## none -> the first keyword -> ... -> the last -> none, as C-c C-t cycles.
  let h = headline(line)
  if h.level == 0: return line
  let at = todoKeywords.find(h.todo)
  withTodo(line, if at < 0: todoKeywords[0] elif at == todoKeywords.high: "" else: todoKeywords[at+1])

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
    of 'A': result.add (if japanese: weekdaysJa[(ord(t.weekday) + 1) mod 7] else: t.format("dddd"))
    of 'a': result.add (if japanese: weekdaysShortJa[(ord(t.weekday) + 1) mod 7] else: t.format("ddd"))
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

const imageExtensions* = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]

proc imageLink*(line: seq[Rune]): string =
  ## The file an inline image link on the line points to: the first `[[file:PATH]]` or
  ## `[[file:PATH][description]]` whose PATH has an image extension; "" when none.
  let s = $line
  var i = 0
  while true:
    let a = s.find("[[file:", i)
    if a < 0: return ""
    let z = s.find("]", a)
    if z < 0: return ""
    let path = s[a + 7 ..< z]
    let (_, _, ext) = splitFile(path)
    if ext.len > 1 and ext[1..^1].toLowerAscii in imageExtensions: return path
    i = z + 1

proc clipboardImageName*(t: DateTime): string =
  ## Where a pasted image goes, relative to the Org file: img/YYYY-mm-dd-HH-MM-SS.png,
  ## as the user's Emacs command names them.
  "img/" & t.format("yyyy-MM-dd-HH-mm-ss") & ".png"

proc newJournalText*(header, dateLine, dayTemplate: string, id = ""): string =
  ## A new journal file as org-journal makes it: an ID drawer when asked (org-roam's
  ## node), the file header, the date headline, then the day's template under it.
  if id.len > 0: result.add ":PROPERTIES:\n:ID:       " & id & "\n:END:\n"
  result = appendedText(result & header, dateLine & "\n")
  if dayTemplate.len > 0: result = appendedText(result, dayTemplate)

proc conditionMark*(n: int): string =
  ## The 体調 stars the user's journal hook puts after the time: " ★★★ " for 3, "" outside 1..5.
  if n in 1..5: " " & "★".repeat(n) & " " else: ""

proc withDateLine*(text, dateLine: string): string =
  ## text with the day's date headline added at the end when no line is it yet. A
  ## journal file has one top-level headline, so one written by another tool in its
  ## own date format counts and no second one is added.
  for l in text.split('\n'):
    if l == dateLine or l.startsWith("* "): return text
  appendedText(text, dateLine & "\n")

proc withId*(text, id: string): string =
  ## text with an ID property drawer first when it has none at the top, so the day is
  ## an org-roam node; id is the one to give it. A drawer already there is kept.
  if id.len == 0: return text
  var i = 0
  let lines = text.split('\n')
  while i < lines.len and lines[i].len == 0: inc i
  if i < lines.len and lines[i].strip.toUpperAscii == ":PROPERTIES:":
    for l in lines[i + 1 .. ^1]:
      if l.strip.toUpperAscii == ":END:": break
      if l.strip.toUpperAscii.startsWith(":ID:"): return text
  ":PROPERTIES:\n:ID:       " & id & "\n:END:\n" & text

proc withHeader*(text, header: string): string =
  ## text with org-journal-file-header (date-expanded) put first when the file lacks it:
  ## a `#+key:` line is looked for by its key, any other first line as it is.
  if header.len == 0: return text
  var first = ""
  for l in header.split('\n'):
    if l.len > 0:
      first = l
      break
  if first.len == 0: return text
  let key = if first.startsWith("#+") and first.contains(':'): first[0..first.find(':')].toLowerAscii else: ""
  for l in text.split('\n'):
    if (key.len > 0 and l.toLowerAscii.startsWith(key)) or (key.len == 0 and l == first): return text
  result = header
  if not result.endsWith('\n'): result.add '\n'
  result.add text

proc quickEntry*(stamp, text: string, bodyBelow = false): string =
  ## A quick-add entry: the time stamp and the text's first line as the headline, the
  ## other lines as its body (text trimmed first), as yuruorg's 日報クイック追記. With
  ## bodyBelow (an org-journal-time-format ending in a newline, as Emacs lays entries
  ## out) the whole text goes under the time headline instead.
  let parts = unicode.strip(text).replace("\r\n", "\n").replace('\r', '\n').split('\n')
  if bodyBelow:
    result = stamp
    for l in parts:
      if l.len > 0 or result != stamp: result.add "\n" & l
    return
  result = if parts[0].len == 0: stamp else: stamp & " " & parts[0]
  for l in parts[1..^1]: result.add "\n" & l

proc appendQuickEntry*(text, headline, entry: string): string =
  ## entry (one or more lines) added to a journal as yuruorg's appendQuickEntry does: at
  ## the end of the section of the line `headline` (before the next headline of its level
  ## or higher, and before the section's trailing blank lines), the headline added after a
  ## blank line at the end when missing; at the very end of the file when headline is "".
  ## Line ends come back as "\n"; a final newline stays as it was (an empty text gets one).
  let normalized = text.replace("\r\n", "\n").replace('\r', '\n')
  let newline = normalized.len == 0 or normalized.endsWith('\n')
  var lines = normalized.split('\n')
  if newline: lines.setLen(lines.len - 1)
  let entryLines = entry.split('\n')
  var head = -1
  if headline.len > 0:
    for n, l in lines:
      if strutils.strip(l, leading = false) == headline:
        head = n
        break
  if headline.len == 0: lines.add entryLines
  elif head < 0:
    while lines.len > 0 and strutils.strip(lines[^1]).len == 0: lines.setLen(lines.len - 1)
    if lines.len > 0: lines.add ""
    lines.add headline
    lines.add entryLines
  else:
    var level = stars(headline.toRunes)
    if level == 0: level = int.high  # a plain line: its section runs to the next headline
    var z = head + 1
    while z < lines.len and not (stars(lines[z].toRunes) in 1..level): inc z
    while z > head + 1 and strutils.strip(lines[z - 1]).len == 0: dec z
    lines = lines[0 ..< z] & entryLines & lines[z .. ^1]
  lines.join("\n") & (if newline: "\n" else: "")

# ---- Agenda: dated and TODO items across the agenda files, for today

type
  AgendaKind* = enum akScheduled, akDeadline, akTimestamp, akTodo
  AgendaItem* = object
    path*: string
    line*: int        ## the headline
    kind*: AgendaKind
    days*: int        ## the date relative to today (negative = past); 0 for plain TODOs
    text*: string     ## the headline without stars
    todo*, tags*: string
    priority*: char
    scheduledToday*: bool

proc parseDate*(s: string, at: int): tuple[ok: bool, date: DateTime] =
  ## The yyyy-mm-dd starting at s[at] (the day name, time and repeater after it are ignored).
  if at + 10 > s.len or s[at+4] != '-' or s[at+7] != '-': return
  try:
    let year = parseInt(s[at..at+3])
    let month = parseInt(s[at+5..at+6])
    let day = parseInt(s[at+8..at+9])
    if month notin 1..12 or day < 1 or day > getDaysInMonth(Month(month), year): return
    result.date = dateTime(year, Month(month), day)
    result.ok = true
  except ValueError, RangeDefect: discard

proc activeDates*(s: string): seq[DateTime] =
  ## Every active timestamp <yyyy-mm-dd ...> in s.
  var i = 0
  while i < s.len:
    if s[i] == '<':
      let (ok, date) = parseDate(s, i + 1)
      if ok: result.add date
    inc i

proc planning*(line: string, key: string): seq[DateTime] =
  ## The timestamps after `SCHEDULED:` or `DEADLINE:` in a planning line.
  let at = line.find(key & ":")
  if at < 0: return
  var rest = line[at + key.len + 1 .. ^1]
  let stop = max(rest.find("SCHEDULED:"), rest.find("DEADLINE:"))
  if stop >= 0: rest = rest[0..<stop]
  activeDates(rest)

proc daysBetween(a, b: DateTime): int = int((b - a).inDays)

proc agendaItems*(path: string, lines: seq[seq[Rune]], today: DateTime,
                  deadlineWarning = 14): seq[AgendaItem] =
  ## What today's agenda shows from one file: TODO headlines scheduled today or earlier,
  ## deadlines due within deadlineWarning days or overdue, headlines dated today, and
  ## the undated TODO headlines.
  let day = dateTime(today.year, today.month, today.monthday)
  for n, l in lines:
    if not isHeadline(l): continue
    let h = headline(l)
    let text = ($l)[h.level + 1 .. ^1].strip
    let next = if n + 1 < lines.len: $lines[n+1] else: ""
    # A headline with any planning or timestamp is dated: it shows on its day, not among the undated TODOs.
    var dated = planning(next, "SCHEDULED").len + planning(next, "DEADLINE").len + activeDates($l).len > 0
    if h.todo.len > 0 and not isDone(h.todo):
      for d in planning(next, "SCHEDULED"):
        let days = daysBetween(day, d)
        if days <= 0: result.add AgendaItem(path: path, line: n, kind: akScheduled, days: days, text: text)
      for d in planning(next, "DEADLINE"):
        let days = daysBetween(day, d)
        if days <= deadlineWarning: result.add AgendaItem(path: path, line: n, kind: akDeadline, days: days, text: text)
    for d in activeDates($l):
      if daysBetween(day, d) == 0:
        result.add AgendaItem(path: path, line: n, kind: akTimestamp, days: 0, text: text)
    if not dated and h.todo.len > 0 and not isDone(h.todo):
      result.add AgendaItem(path: path, line: n, kind: akTodo, text: text)

  for item in result.mitems:
    let h = headline(lines[item.line])
    item.todo = h.todo
    item.tags = h.tags
    item.priority = h.priority
    if item.line + 1 < lines.len:
      for d in planning($lines[item.line+1], "SCHEDULED"):
        if daysBetween(day, d) == 0: item.scheduledToday = true

proc agendaLabel*(it: AgendaItem): string =
  ## The agenda's prefix, as Emacs words it: Scheduled: / Sched. 3x: / Deadline: / In 3 d.: / 3 d. ago:
  case it.kind
  of akScheduled: (if it.days == 0: "Scheduled:" else: "Sched. " & $(-it.days) & "x:")
  of akDeadline:
    if it.days == 0: "Deadline:"
    elif it.days > 0: "In " & $it.days & " d.:"
    else: $(-it.days) & " d. ago:"
  of akTimestamp: ""
  of akTodo: "TODO:"

proc agendaOrder*(items: seq[AgendaItem]): seq[AgendaItem] =
  ## Overdue first (oldest first), then today's, then upcoming deadlines, then undated TODOs.
  result = items
  result.sort(proc(a, b: AgendaItem): int =
    proc rank(it: AgendaItem): int =
      if it.kind == akTodo: 3
      elif it.days < 0: 0
      elif it.days == 0: 1
      else: 2
    result = cmp(rank(a), rank(b))
    if result == 0: result = cmp(a.days, b.days)
    if result == 0: result = cmp(a.line, b.line))

proc agendaRow*(it: AgendaItem, width = 12): string =
  ## `  Scheduled:   TODO title` with the file's name first.
  alignLeft(extractFilename(it.path).changeFileExt("") & ":", 10) & " " & alignLeft(agendaLabel(it), width) & " " & it.text

# ---- Refiling: outline paths and subtree moves, independent of buffers and files

type RefileTarget* = object
  line*, level*: int
  path*: string

proc orgText*(lines: seq[seq[Rune]]): string =
  for i, line in lines:
    if i > 0: result.add '\n'
    result.add $line

proc orgLines*(text: string): seq[seq[Rune]] =
  for line in text.split('\n'): result.add line.toRunes

proc refileTargets*(lines: seq[seq[Rune]], maxlevel = 3): seq[RefileTarget] =
  var parents: seq[RefileTarget]
  for n, line in lines:
    let h = headline(line)
    if h.level == 0: continue
    while parents.len > 0 and parents[^1].level >= h.level: parents.setLen(parents.len - 1)
    let path = (if parents.len > 0: parents[^1].path & "/" else: "") & h.title
    let target = RefileTarget(line: n, level: h.level, path: path)
    parents.add target
    if h.level <= maxlevel: result.add target

proc removeSubtree*(lines: seq[seq[Rune]], n: int): seq[seq[Rune]] =
  if n notin 0..lines.high or not isHeadline(lines[n]):
    raise newException(ValueError, "Not on a headline")
  let z = subtreeEnd(lines, n)
  result = lines[0..<n] & lines[z+1..^1]
  if result.len == 0: result = @[newSeq[Rune]()]
  elif lines[^1].len == 0 and result[^1].len != 0: result.add @[]

proc insertSubtree*(lines, subtree: seq[seq[Rune]], parent: int): seq[seq[Rune]] =
  ## Append a child, or a level-one subtree at the file root (parent = -1).
  if parent < -1 or parent > lines.high or (parent >= 0 and not isHeadline(lines[parent])):
    raise newException(ValueError, "Invalid refile parent")
  let level = if parent < 0: 1 else: headline(lines[parent]).level + 1
  let delta = level - headline(subtree[0]).level
  var moved: seq[seq[Rune]]
  for line in subtree: moved.add shiftLevel(line, delta)
  # The final empty line represents the terminating newline, not an extra body line.
  if moved.len > 1 and moved[^1].len == 0: moved.setLen(moved.len - 1)
  var at = if parent < 0: lines.len else: subtreeEnd(lines, parent) + 1
  if at == lines.len and lines[^1].len == 0: dec at
  result = lines[0..<at] & moved & lines[at..^1]
  if result[^1].len != 0: result.add @[]

proc refileSubtree*(source, target: seq[seq[Rune]], n, parent: int,
                    sameFile = false): tuple[source, target: seq[seq[Rune]]] =
  if n notin 0..source.high or not isHeadline(source[n]):
    raise newException(ValueError, "Not on a headline")
  let z = subtreeEnd(source, n)
  if sameFile and parent in n..z:
    raise newException(ValueError, "Cannot refile a subtree into itself")
  result.source = removeSubtree(source, n)
  var dest = target
  var p = parent
  if sameFile:
    dest = result.source
    if p > z: p -= z - n + 1
  result.target = insertSubtree(dest, source[n..z], p)
  if sameFile: result.source = result.target

proc ensureRefileParent*(lines: seq[seq[Rune]], path: string): tuple[lines: seq[seq[Rune]], line: int] =
  ## Create the missing suffix of an outline path; callers must ask before applying it.
  result = (lines, -1)
  var prefix = ""
  for title in path.split('/'):
    if title.strip.len == 0: raise newException(ValueError, "Empty parent headline")
    prefix.add (if prefix.len > 0: "/" else: "") & title
    var found = -1
    for t in refileTargets(result.lines, int.high):
      if t.path == prefix:
        if found >= 0: raise newException(ValueError, "Ambiguous parent headline: " & prefix)
        found = t.line
    if found < 0:
      let level = if result.line < 0: 1 else: headline(result.lines[result.line]).level + 1
      result.lines = insertSubtree(result.lines, @[(repeat('*', level) & " " & title).toRunes], result.line)
      for t in refileTargets(result.lines, int.high):
        if t.path == prefix: found = t.line
    result.line = found

# ---- Super-agenda: the first matching group claims an item, keeping agenda order.
type
  AgendaGroup* = object
    name*, todo*, tag*: string
    priority*: char
    scheduledToday*: bool
  AgendaSection* = object
    name*: string
    items*: seq[AgendaItem]

proc groupAgenda*(items: seq[AgendaItem], groups: seq[AgendaGroup]): seq[AgendaSection] =
  var sections: seq[AgendaSection]
  for g in groups: sections.add AgendaSection(name: g.name)
  sections.add AgendaSection(name: "その他")
  for item in items:
    var at = groups.len
    for i, g in groups:
      let priority = if item.priority == '\0': 'B' else: item.priority
      if (g.priority != '\0' and priority == g.priority) or
          (g.todo.len > 0 and item.todo == g.todo) or
          (g.tag.len > 0 and (":" & g.tag & ":") in item.tags) or
          (g.scheduledToday and item.scheduledToday):
        at = i
        break
    sections[at].items.add item
  for section in sections:
    if section.items.len > 0: result.add section

# ---- Display-only Org modern spans. Rune positions never move, including hidden syntax.
type
  OrgDecorationKind* = enum odTodo, odBlock, odCheckbox, odBullet
  OrgDecoration* = object
    first*, last*: int       # rune range [first, last)
    text*: seq[Rune]         # same number of rune slots, keeping mouse/region positions
    kind*: OrgDecorationKind
    keyword*: string

proc modernDecorations*(lines: seq[seq[Rune]]): seq[seq[OrgDecoration]] =
  result = newSeq[seq[OrgDecoration]](lines.len)
  var ending = ""
  for n, line in lines:
    var ind = 0
    while ind < line.len and line[ind] in [Rune(' '), Rune('\t')]: inc ind
    let text = $line[ind..^1]
    let tokens = strutils.splitWhitespace(text)
    let token = if tokens.len > 0: tokens[0].toLowerAscii else: ""
    if ending.len > 0:
      if token != ending: continue
      ending = ""
      if token != "#+end_src": continue
    elif token.startsWith("#+begin_"):
      ending = "#+end_" & token[8..^1]
      if token != "#+begin_src": continue
    if token in ["#+begin_src", "#+end_src"]:
      let language = if token == "#+begin_src" and tokens.len > 1: tokens[1] else: ""
      var shown = ("─" & (if language.len > 0: " " & language & " " else: "")).toRunes
      while shown.len < line.len - ind: shown.add Rune(0x2500)
      shown.setLen(line.len - ind)
      result[n].add OrgDecoration(first: ind, last: line.len, text: shown, kind: odBlock)
      continue
    let h = headline(line)
    if h.todo.len > 0:
      var start = h.level + 1
      while start < line.len and line[start] == Rune(' '): inc start
      result[n].add OrgDecoration(first: start, last: start + h.todo.runeLen,
        text: h.todo.toRunes, kind: odTodo, keyword: h.todo)
    let (bullet, after) = itemStart(text)
    if bullet.len == 0: continue
    if bullet in ["-", "+"]:
      result[n].add OrgDecoration(first: ind, last: ind+1, text: "•".toRunes, kind: odBullet)
    let at = ind + after
    if at+2 < line.len and line[at] == Rune('[') and line[at+2] == Rune(']'):
      let symbol = case line[at+1].int
        of ord(' '): "□"
        of ord('X'), ord('x'): "✓"
        of ord('-'): "■"
        else: ""
      if symbol.len > 0:
        result[n].add OrgDecoration(first: at, last: at+3, text: (symbol & "  ").toRunes, kind: odCheckbox)

# ---- Planning and archival metadata

proc readOrgDate*(input: string, today: DateTime): DateTime =
  let value = input.strip.toLowerAscii
  let day = dateTime(today.year, today.month, today.monthday, zone = today.timezone)
  if value.len == 0: return day
  if value.len > 1 and value[0] in {'+', '-'}:
    try: return day + initTimeInterval(days = parseInt(value))
    except ValueError: discard
  const weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
  let weekday = weekdays.find(value)
  if weekday >= 0:
    return day + initTimeInterval(days = (weekday - ord(day.weekday) + 7) mod 7)
  if value.len == 10:
    let parsed = parseDate(value, 0)
    if parsed.ok: return dateTime(parsed.date.year, parsed.date.month, parsed.date.monthday, zone = today.timezone)
  raise newException(ValueError, "Use YYYY-MM-DD, +days, mon..sun, or empty for today")

proc isPlanning(line: seq[Rune]): bool =
  let s = ($line).strip
  s.startsWith("SCHEDULED:") or s.startsWith("DEADLINE:") or s.startsWith("CLOSED:")

proc withPlanning*(lines: seq[seq[Rune]], n: int, key: string, date: DateTime): seq[seq[Rune]] =
  if n notin 0..lines.high or not isHeadline(lines[n]):
    raise newException(ValueError, "Not on a headline")
  if key notin ["SCHEDULED", "DEADLINE"]: raise newException(ValueError, "Unknown planning keyword")
  result = lines
  let entry = key & ": " & timestamp(date)
  if n+1 > lines.high or not isPlanning(lines[n+1]):
    result.insert(entry.toRunes, n+1)
    return
  let line = $lines[n+1]
  let at = line.find(key & ":")
  if at < 0:
    result[n+1] = (line & " " & entry).toRunes
    return
  var first = at + key.len + 1
  while first < line.len and line[first] == ' ': inc first
  if first >= line.len or line[first] != '<':
    raise newException(ValueError, "Malformed planning timestamp")
  let last = line.find('>', first)
  if last < 0: raise newException(ValueError, "Unclosed planning timestamp")
  result[n+1] = (line[0..<at] & entry & line[last+1..^1]).toRunes

proc archiveSubtree*(lines: seq[seq[Rune]], n: int, file: string, time: DateTime): seq[seq[Rune]] =
  if n notin 0..lines.high or not isHeadline(lines[n]):
    raise newException(ValueError, "Not on a headline")
  let h = headline(lines[n])
  var parents: seq[tuple[level: int, title: string]]
  for i in 0..<n:
    let heading = headline(lines[i])
    if heading.level == 0: continue
    while parents.len > 0 and parents[^1].level >= heading.level: parents.setLen(parents.len-1)
    parents.add (heading.level, heading.title)
  while parents.len > 0 and parents[^1].level >= h.level: parents.setLen(parents.len-1)
  var path: seq[string]
  for parent in parents: path.add parent.title
  for line in lines[n..subtreeEnd(lines, n)]: result.add shiftLevel(line, 1-h.level)
  var drawer = 1
  if drawer < result.len and isPlanning(result[drawer]): inc drawer
  var ending = drawer
  if drawer < result.len and ($result[drawer]).strip.toUpperAscii == ":PROPERTIES:":
    inc ending
    while ending < result.len and ($result[ending]).strip.toUpperAscii != ":END:":
      if isHeadline(result[ending]): break
      inc ending
    if ending >= result.len or ($result[ending]).strip.toUpperAscii != ":END:":
      raise newException(ValueError, "Unclosed property drawer")
  else:
    result.insert(":PROPERTIES:".toRunes, drawer)
    result.insert(":END:".toRunes, drawer+1)
    ending = drawer+1
  for (key, value) in [("ARCHIVE_TIME", time.format("yyyy-MM-dd ddd HH:mm")),
      ("ARCHIVE_FILE", file), ("ARCHIVE_OLPATH", path.join("/")), ("ARCHIVE_TODO", h.todo)]:
    let prefix = ":" & key & ":"
    let property = (prefix & " " & value).toRunes
    var found = false
    for i in drawer+1..<ending:
      if ($result[i]).strip.toUpperAscii.startsWith(prefix):
        result[i] = property
        found = true
        break
    if not found:
      result.insert(property, ending)
      inc ending

proc doneSubtrees*(lines: seq[seq[Rune]]): seq[int] =
  var n = 0
  while n < lines.len:
    let h = headline(lines[n])
    if h.level > 0 and isDone(h.todo):
      result.add n
      n = subtreeEnd(lines, n) + 1
    else: inc n

proc archiveTrees*(source, destination: seq[seq[Rune]], headings: seq[int], file: string,
                   time: DateTime): tuple[source, archive: seq[seq[Rune]], count: int] =
  var selected = headings
  selected.sort()
  var roots: seq[int]
  var covered = -1
  result = (source, destination, 0)
  for n in selected:
    if n <= covered: continue
    let archived = archiveSubtree(source, n, file, time)
    result.archive = insertSubtree(result.archive, archived, -1)
    roots.add n
    covered = subtreeEnd(source, n)
    inc result.count
  for i in countdown(roots.high, 0): result.source = removeSubtree(result.source, roots[i])
