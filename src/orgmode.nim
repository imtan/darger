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
