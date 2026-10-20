## Display-cell wrapping for agent prose; source text stays with the caller.
import std/[unicode, strutils]
import buffer

proc closing(r: Rune): bool = r in "、。」』）】".toRunes
proc opening(r: Rune): bool = r in "「『（【".toRunes
proc cjk(r: Rune): bool =
  runeWidth(r) == 2 and (int(r) < 0x1F000 or int(r) >= 0x20000)

proc legal(rs: seq[Rune], at: int): bool =
  at == rs.len or (not opening(rs[at - 1]) and not closing(rs[at]) and
    runeWidth(rs[at]) != 0)

proc markerWidth(rs: seq[Rune]): int =
  if rs.len >= 2 and rs[0] in [Rune('-'), Rune('*')] and rs[1] == Rune(' '):
    return 2
  var n = 0
  while n < rs.len and int(rs[n]) in ord('0')..ord('9'): inc n
  if n > 0 and n + 1 < rs.len and rs[n] == Rune('.') and rs[n + 1] == Rune(' '):
    return n + 2

proc wrapLine(line: string, width: int): string =
  let rs = line.toRunes
  var cells = 0
  for r in rs: cells += runeWidth(r)
  if cells <= width or strutils.strip(line).len == 0: return line
  let marker = markerWidth(rs)
  if marker == rs.len: return line
  # Leave room for text even with a marker wider than a very narrow request.
  let indent = if marker + 2 <= width: marker else: 0
  var start = marker
  var prefix = $rs[0..<marker]
  while start < rs.len:
    var stop = start
    cells = prefix.len
    while stop < rs.len and cells + runeWidth(rs[stop]) <= width:
      cells += runeWidth(rs[stop])
      inc stop
    if stop < rs.len:
      var preferred = 0
      for at in start + 1..stop:
        if legal(rs, at) and (rs[at] == Rune(' ') or rs[at - 1] == Rune(' ') or
            cjk(rs[at - 1]) or cjk(rs[at])):
          preferred = at
      if preferred > start:
        stop = preferred
      else:
        # Split overlong words, but keep combining marks and punctuation attached.
        while stop > start and not legal(rs, stop): dec stop
        if stop == start:
          stop = start + 1
          while stop < rs.len and not legal(rs, stop): inc stop
    var finish = stop
    if stop < rs.len:
      while finish > start and rs[finish - 1] == Rune(' '): dec finish
    result.add prefix & $rs[start..<finish]
    start = stop
    while start < rs.len and rs[start] == Rune(' '): inc start
    if start < rs.len: result.add '\n'
    prefix = repeat(' ', indent)

proc wrapText*(text: string, width: int): string =
  ## Preserve existing line/paragraph boundaries and lines that fit. Nonpositive
  ## widths disable wrapping. An indivisible rune/punctuation group may overflow
  ## a width too small to hold it, rather than violate kinsoku or lose text.
  let lines = text.split('\n')
  for i, line in lines:
    if i > 0: result.add '\n'
    result.add(if width <= 0: line else: wrapLine(line, width))
