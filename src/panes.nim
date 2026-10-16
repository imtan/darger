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
    ratio*: float          # a's share of the split (0 = half, until resized)
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

proc share(l: Layout, total, minimum: int): int =
  ## a's cells of `total`: half, or its ratio, never below the minimum on either side.
  let r = if l.ratio > 0: l.ratio else: 0.5
  clamp(int(float(total) * r), min(minimum, total div 2), max(total - minimum, total div 2))  # odd leftovers go to z

proc place*(l: Layout, x, y, w, h: int, bars: var seq[Bar]) =
  ## Assigns cells: a split below gives the top part its share of the height, a split
  ## right its share of the width with one separator column between the halves.
  if l.pane != nil:
    (l.pane.x, l.pane.y, l.pane.w, l.pane.h) = (x, y, w, h)
  elif l.below:
    let top = l.share(h, minRows)
    l.a.place(x, y, w, top, bars)
    l.z.place(x, y + top, w, h - top, bars)
  else:
    let left = l.share(w - 1, minCols)
    bars.add (x + left, y, h)
    l.a.place(x, y, left, h, bars)
    l.z.place(x + left + 1, y, w - left - 1, h, bars)

proc splitAbove(l: Layout, p: Pane, below: bool): tuple[node: Layout, inA: bool] =
  ## The nearest split in the given direction holding p, and whether p is in its a side.
  if l.pane != nil: return (nil, false)
  for (child, inA) in [(l.a, true), (l.z, false)]:
    if child.nodeOf(p) != nil:
      let inner = child.splitAbove(p, below)
      if inner.node != nil: return inner
      return (if l.below == below: (l, inA) else: (nil, false))

proc resize*(l: Layout, p: Pane, below: bool, delta: int): bool =
  ## Grows (delta > 0) or shrinks p by delta rows (below) or columns within the nearest
  ## split in that direction; false when there is none. place() applies the limits.
  let (node, inA) = l.splitAbove(p, below)
  if node == nil: return false
  # the split's current size in that direction, from its children's placed cells
  let first = node.a.leaves[0]
  let last = node.z.leaves[^1]
  let size = if below: last.y + last.h - first.y else: last.x + last.w - first.x - 1
  if size <= 0: return false
  let current = if below: node.a.leaves[^1].y + node.a.leaves[^1].h - first.y else: node.a.leaves[^1].x + node.a.leaves[^1].w - first.x
  let wanted = if inA: current + delta else: current - delta
  node.ratio = clamp(float(wanted) / float(size), 0.05, 0.95)
  true

proc countAlong(l: Layout, below: bool): int =
  ## Leaves in l counted along one direction: same-direction splits add up, others count 1.
  if l.pane != nil or l.below != below: 1 else: l.a.countAlong(below) + l.z.countAlong(below)

proc balance*(l: Layout) =
  ## Every split shares its space by the number of windows on each side, as balance-windows.
  if l.pane != nil: return
  let a = l.a.countAlong(l.below)
  let z = l.z.countAlong(l.below)
  l.ratio = float(a) / float(a + z)
  l.a.balance()
  l.z.balance()

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

proc neighbour*(l: Layout, p: Pane, dx, dy: int, rx, ry: int): Pane =
  ## The nearest pane in direction (dx, dy) from p that the line through the reference
  ## cell (rx, ry) crosses, as windmove picks the window next to point; nil when none.
  var best: Pane
  var distance = int.high
  for q in l.leaves:
    if q == p: continue
    if dx != 0:
      if ry < q.y or ry >= q.y + q.h: continue
      let d = if dx > 0: q.x - (p.x + p.w) else: p.x - (q.x + q.w)
      if d >= 0 and d < distance: (best = q; distance = d)
    else:
      if rx < q.x or rx >= q.x + q.w: continue
      let d = if dy > 0: q.y - (p.y + p.h) else: p.y - (q.y + q.h)
      if d >= 0 and d < distance: (best = q; distance = d)
  best
