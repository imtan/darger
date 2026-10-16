## Terminal output as plain text: what a process on a pty writes, with carriage returns,
## backspaces and escape sequences applied, as a comint-style shell buffer shows it.
import std/[unicode, strutils]

type TermText* = object
  done: string      ## finished lines, each ending in "\n"
  line: seq[Rune]   ## the line being written
  col: int          ## where the next rune goes in `line` (a "\r" moves it to 0)
  pending: string   ## an incomplete escape or UTF-8 sequence from the last chunk

proc text*(t: TermText): string = t.done & $t.line

proc commit(t: var TermText) =
  t.done.add $t.line & "\n"
  t.line = @[]
  t.col = 0

proc put(t: var TermText, r: Rune) =
  if t.col < t.line.len: t.line[t.col] = r else: t.line.add r
  inc t.col

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
  if t.done.len <= keep: return
  let cut = t.done.find('\n', t.done.len - keep)
  if cut >= 0: t.done = t.done[cut+1..^1]
