## Window layout: a binary tree of panes split below or side by side, like Emacs
## windows. A pane shows one buffer with its own scroll and point; place() gives
## every pane its cells in the frame, and the editor draws them.
import std/unicode
import buffer

type
  Pane* = ref object
    buf*: Buffer
    top*, left*: int       # scroll
    cursor*: Point         # the point in buf while the pane is not selected
    x*, y*, w*, h*: int    # cells from the last place(); h includes the mode line row
  Layout* = ref object
    pane*: Pane            # a leaf; else a split:
    below*: bool           # a above z, else a left of z
    a*, z*: Layout
  Bar* = tuple[x, y, h: int]  # a vertical separator column between side-by-side panes

const
  minRows* = 3   # a pane: at least 2 text rows and its mode line
  minCols* = 10

proc newLayout*(p: Pane): Layout = Layout(pane: p)

proc leaves*(l: Layout): seq[Pane] =
  ## The panes left to right, top to bottom.
  if l.pane != nil: @[l.pane] else: l.a.leaves & l.z.leaves

proc nodeOf(l: Layout, p: Pane): Layout =
  if l.pane == p: return l
  if l.pane != nil: return nil
  result = l.a.nodeOf(p)
  if result == nil: result = l.z.nodeOf(p)

proc parentOf(l: Layout, p: Pane): Layout =
  if l.pane != nil: return nil
  if l.a.pane == p or l.z.pane == p: return l
  result = l.a.parentOf(p)
  if result == nil: result = l.z.parentOf(p)

proc canSplit*(p: Pane, below: bool): bool =
  ## Whether both halves would keep the minimum size (a separator column goes between side-by-side halves).
  if below: p.h >= 2 * minRows else: p.w >= 2 * minCols + 1

proc split*(l: Layout, p: Pane, below: bool, fresh: Pane) =
  ## p's leaf becomes a split holding p and, below or right of it, fresh.
  let node = l.nodeOf(p)
  node.below = below
  node.a = Layout(pane: p)
  node.z = Layout(pane: fresh)
  node.pane = nil

proc remove*(l: Layout, p: Pane): Pane =
  ## Deletes p's pane; its sibling takes the space. Returns the pane to select next
  ## (the sibling's first leaf), or nil when p is the only pane.
  let parent = l.parentOf(p)
  if parent == nil: return nil
  let sibling = if parent.a.pane == p: parent.z else: parent.a
  parent[] = sibling[]
  parent.leaves[0]

proc keepOnly*(l: Layout, p: Pane) =
  ## Every pane but p goes away.
  l[] = Layout(pane: p)[]

proc place*(l: Layout, x, y, w, h: int, bars: var seq[Bar]) =
  ## Assigns cells: a split below gives the top half the smaller share of an odd
  ## height, a split right leaves one separator column between the halves.
  if l.pane != nil:
    (l.pane.x, l.pane.y, l.pane.w, l.pane.h) = (x, y, w, h)
  elif l.below:
    let top = h div 2
    l.a.place(x, y, w, top, bars)
    l.z.place(x, y + top, w, h - top, bars)
  else:
    let left = (w - 1) div 2
    bars.add (x + left, y, h)
    l.a.place(x, y, left, h, bars)
    l.z.place(x + left + 1, y, w - left - 1, h, bars)

proc next*(l: Layout, p: Pane, delta: int): Pane =
  ## The pane delta steps from p in leaves order, wrapping.
  let all = l.leaves
  let i = all.find(p)
  if i < 0: return p
  all[((i + delta) mod all.len + all.len) mod all.len]

proc paneAt*(l: Layout, x, y: int): Pane =
  ## The pane holding cell (x, y), nil between panes.
  for p in l.leaves:
    if x >= p.x and x < p.x + p.w and y >= p.y and y < p.y + p.h: return p

proc gutterWidth*(lineCount: int): int =
  ## The line-number gutter: right-aligned numbers at least 3 digits wide, then 2 cells.
  max(3, len($lineCount)) + 2

proc pointAt*(lines: seq[seq[Rune]], fold: seq[int8], top, left, gutter, cx, cy: int): Point =
  ## The buffer point under text cell (cx, cy) of a pane scrolled to (top, left), skipping
  ## hidden (folded) lines; below the last line, the end of the last shown line.
  var line = max(0, min(top, lines.high))
  var row = 0
  var last = line
  while line <= lines.high:
    let hidden = line < fold.len and fold[line] == 1
    if not hidden:
      last = line
      if row == cy: break
      inc row
    inc line
  if line > lines.high: line = last
  let cell = max(0, left + cx - gutter)
  (line, min(runeCol(lines[line], cell), lines[line].len))
