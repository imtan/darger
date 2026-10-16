## Terminal output as text with colours: what a process on a pty writes, with carriage
## returns, backspaces and escape sequences applied, and SGR foreground colours kept
## per rune (0 = the default colour, 1..8 = the eight ANSI colours), as a comint-style
## shell buffer shows it.
import std/[unicode, strutils]

type TermText* = object
  lines: seq[seq[Rune]]    ## the output; the last line is being written
  colors: seq[seq[int8]]   ## per rune, parallel to lines
  col: int                 ## where the next rune goes in the last line (a "\r" moves it to 0)
  color: int8              ## the current SGR foreground
  pending: string          ## an incomplete escape or UTF-8 sequence from the last chunk

proc init(t: var TermText) =
  if t.lines.len == 0:
    t.lines.add @[]
    t.colors.add @[]

proc shownLen(t: TermText): int =
  ## The last line as shown: spaces left of the cursor after a "\r" are not kept (zsh pads
  ## a line to the width and returns before printing the prompt), other text is.
  if t.lines.len == 0: return 0
  let line = t.lines[^1]
  result = line.len
  if t.col < line.len:
    for i in t.col..<line.len:
      if line[i] != Rune(' '): return
    result = t.col

proc text*(t: TermText): string =
  for i, l in t.lines:
    if i > 0: result.add "\n"
    if i == t.lines.high: result.add $l[0..<t.shownLen]
    else: result.add $l

proc faces*(t: TermText): seq[seq[int8]] =
  ## The colour of every rune, per line (0 = default, 1..8 = ANSI black .. white).
  result = t.colors
  if result.len > 0: result[^1] = result[^1][0..<t.shownLen]

proc commit(t: var TermText) =
  let keep = t.shownLen  # padding spaces right of the cursor go with the line end
  t.lines[^1].setLen(keep)
  t.colors[^1].setLen(keep)
  t.lines.add @[]
  t.colors.add @[]
  t.col = 0

proc put(t: var TermText, r: Rune) =
  t.init()
  if t.col < t.lines[^1].len:
    t.lines[^1][t.col] = r
    t.colors[^1][t.col] = t.color
  else:
    t.lines[^1].add r
    t.colors[^1].add t.color
  inc t.col

proc sgr(t: var TermText, params: string) =
  ## Select Graphic Rendition: foreground colours 30-37 / 90-97, 38;5;n for the first 16, 0 and 39 reset.
  var codes: seq[int]
  for part in params.split(';'):
    if part.len == 0: codes.add 0
    else:
      try: codes.add parseInt(part)
      except ValueError: return
  if codes.len == 0: codes.add 0
  var i = 0
  while i < codes.len:
    let c = codes[i]
    if c == 0 or c == 39: t.color = 0
    elif c in 30..37: t.color = int8(c - 30 + 1)
    elif c in 90..97: t.color = int8(c - 90 + 1)
    elif c == 38 and i + 2 < codes.len and codes[i+1] == 5:
      let n = codes[i+2]
      if n in 0..15: t.color = int8(n mod 8 + 1)
      i += 2
    elif c == 38 and i + 4 < codes.len and codes[i+1] == 2:  # true colour: shown in the default colour
      t.color = 0
      i += 4
    inc i

proc escapeLen(s: string, i: int): int =
  ## Bytes of the escape sequence at s[i] (an ESC); 0 when it is not complete yet.
  if i + 1 >= s.len: return 0
  case s[i+1]
  of '[':  # CSI: parameters and intermediates, then a final byte 0x40..0x7E
    var j = i + 2
    while j < s.len and s[j].ord notin 0x40..0x7E: inc j
    if j >= s.len: 0 else: j - i + 1
  of ']':  # OSC: until BEL or ESC \
    var j = i + 2
    while j < s.len:
      if s[j] == '\a': return j - i + 1
      if s[j] == '\x1b' and j + 1 < s.len and s[j+1] == '\\': return j - i + 2
      inc j
    0
  of '(', ')', '*', '+': (if i + 2 < s.len: 3 else: 0)  # charset designations
  else: 2

proc feed*(t: var TermText, data: string) =
  t.init()
  let s = t.pending & data
  t.pending = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\x1b':
      let n = escapeLen(s, i)
      if n == 0:
        t.pending = s[i..^1]
        return
      if s[i+1] == '[' and s[i+n-1] == 'm': t.sgr(s[i+2..<i+n-1])
      i += n
      continue
    if c.ord < 0x20 or c == '\x7f':
      case c
      of '\n': t.commit()
      of '\r': t.col = 0
      of '\b': t.col = max(0, t.col - 1)
      of '\t': t.put(Rune('\t'))
      else: discard  # bell and the rest
      inc i
      continue
    let need = runeLenAt(s, i)
    if i + need > s.len:  # an incomplete UTF-8 sequence at the end waits for the next chunk
      t.pending = s[i..^1]
      return
    t.put(runeAt(s, i))
    i += need

proc trim*(t: var TermText, keep: int) =
  ## Keeps about `keep` bytes of finished text, dropping whole old lines.
  var size = 0
  for l in t.lines: size += l.len * 3 + 1
  var drop = 0
  while size > keep and drop < t.lines.len - 1:
    size -= t.lines[drop].len * 3 + 1
    inc drop
  if drop > 0:
    t.lines = t.lines[drop..^1]
    t.colors = t.colors[drop..^1]
