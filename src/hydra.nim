## Hydra hints: the heads of a defhydra laid out as `[key] hint` columns, as
## Emacs' hydra shows its docstring while the body is active.
import std/[strutils, unicode]
import buffer

type Head* = object
  key*, command*, hint*: string
  exit*: bool

proc cells(s: string): int =
  for r in s.runes: result += runeWidth(r)

proc hintLines*(title: string, heads: seq[Head], width = 58): seq[string] =
  ## The title (when any), then the heads in columns of equal width, as many per
  ## row as fit in `width` cells; the last line says which keys run and leave.
  if title.len > 0: result.add title
  var items: seq[string]
  for h in heads: items.add "[" & h.key & "] " & h.hint
  if items.len == 0: return
  var colWidth = 0
  for i in items: colWidth = max(colWidth, cells(i))
  let perRow = max(1, (width + 2) div (colWidth + 2))
  var row = ""
  for i, item in items:
    if i mod perRow == 0 and row.len > 0:
      result.add row.strip(leading = false)
      row = ""
    row.add item & repeat(' ', max(0, colWidth - cells(item)) + 2)
  if row.len > 0: result.add row.strip(leading = false)
  var exits: seq[string]
  for h in heads:
    if h.exit: exits.add h.key
  result.add(if exits.len > 0: "other keys leave; " & exits.join(" ") & " run and leave" else: "other keys leave")

proc summary*(title: string, heads: seq[Head]): string =
  ## The one-line hint for the echo line: `title  g:in  l:out`.
  result = title
  for h in heads: result.add "  " & h.key & ":" & h.hint
  result = result.strip
