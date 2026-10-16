import std/unicode
import ../src/[panes, buffer]

proc pane(): Pane = Pane(buf: newBuffer())

block single:
  let p = pane()
  let l = newLayout(p)
  var bars: seq[Bar]
  l.place(0, 0, 80, 24, bars)
  doAssert (p.x, p.y, p.w, p.h) == (0, 0, 80, 24) and bars.len == 0
  doAssert l.leaves == @[p] and l.remove(p) == nil and l.next(p, 1) == p

block below:
  let p = pane()
  let q = pane()
  let l = newLayout(p)
  doAssert p.canSplit(true) == false  # not placed yet: h = 0
  var bars: seq[Bar]
  l.place(0, 0, 80, 25, bars)
  doAssert p.canSplit(true)
  l.split(p, true, q)
  l.place(0, 0, 80, 25, bars)
  doAssert (p.y, p.h) == (0, 12) and (q.y, q.h) == (12, 13) and p.w == 80 and q.w == 80
  doAssert l.leaves == @[p, q] and l.next(p, 1) == q and l.next(q, 1) == p and l.next(p, -1) == q
  doAssert l.paneAt(5, 11) == p and l.paneAt(5, 12) == q
  doAssert l.remove(q) == p
  l.place(0, 0, 80, 25, bars)
  doAssert l.leaves == @[p] and p.h == 25

block right:
  let p = pane()
  let q = pane()
  let l = newLayout(p)
  var bars: seq[Bar]
  l.place(0, 0, 80, 24, bars)
  l.split(p, false, q)
  bars = @[]
  l.place(0, 0, 80, 24, bars)
  doAssert (p.x, p.w) == (0, 39) and (q.x, q.w) == (40, 40) and bars == @[(x: 39, y: 0, h: 24)]
  doAssert l.paneAt(39, 3) == nil and l.paneAt(40, 3) == q
  # a third pane below q, then removing p hands the whole width to that pair
  let r = pane()
  l.split(q, true, r)
  bars = @[]
  l.place(0, 0, 80, 24, bars)
  doAssert l.leaves == @[p, q, r] and (q.y, q.h) == (0, 12) and (r.y, r.h) == (12, 12) and q.x == 40
  doAssert l.remove(p) == q
  bars = @[]
  l.place(0, 0, 80, 24, bars)
  doAssert l.leaves == @[q, r] and q.w == 80 and r.w == 80 and bars.len == 0
  l.keepOnly(r)
  l.place(0, 0, 80, 24, bars)
  doAssert l.leaves == @[r] and (r.x, r.y, r.w, r.h) == (0, 0, 80, 24)

block resizing:
  let p = pane()
  let q = pane()
  let l = newLayout(p)
  var bars: seq[Bar]
  l.place(0, 0, 80, 24, bars)
  l.split(p, true, q)
  l.place(0, 0, 80, 24, bars)
  doAssert p.h == 12 and q.h == 12
  doAssert l.resize(p, true, 4)                      # C-x ^: four more rows for the top pane
  l.place(0, 0, 80, 24, bars)
  doAssert p.h == 16 and q.h == 8 and q.y == 16
  doAssert l.resize(q, true, 2)                      # growing the bottom pane shrinks the top
  l.place(0, 0, 80, 24, bars)
  doAssert p.h == 14 and q.h == 10
  doAssert not l.resize(p, false, 3)                 # no side-by-side split holds p
  doAssert l.resize(p, true, 100)                    # limits: the other pane keeps its minimum
  l.place(0, 0, 80, 24, bars)
  doAssert q.h >= minRows and p.h + q.h == 24
  let r = pane()
  l.split(p, false, r)
  bars = @[]
  l.place(0, 0, 80, 24, bars)
  doAssert l.resize(r, false, 10)                    # C-x }: the right pane widens
  bars = @[]
  l.place(0, 0, 80, 24, bars)
  doAssert r.w > p.w and p.w + r.w + 1 == 80
  l.balance()                                        # C-x +: equal again
  bars = @[]
  l.place(0, 0, 80, 24, bars)
  doAssert abs(p.w - r.w) <= 1 and abs(p.h - q.h) <= 1

block balanceThree:  # three side-by-side panes get equal widths, not 1/2 1/4 1/4
  let p = pane()
  let q = pane()
  let r = pane()
  let l = newLayout(p)
  var bars: seq[Bar]
  l.place(0, 0, 92, 24, bars)
  l.split(p, false, q)
  l.place(0, 0, 92, 24, bars)
  l.split(q, false, r)
  l.balance()
  bars = @[]
  l.place(0, 0, 92, 24, bars)
  doAssert p.w == 30 and q.w == 30 and r.w == 30, $(p.w, q.w, r.w)

block windmove:
  let p = pane()
  let q = pane()
  let r = pane()
  let l = newLayout(p)
  var bars: seq[Bar]
  l.place(0, 0, 80, 24, bars)
  l.split(p, false, q)            # p | q
  l.place(0, 0, 80, 24, bars)
  l.split(q, true, r)             # q above r on the right
  bars = @[]
  l.place(0, 0, 80, 24, bars)
  doAssert l.neighbour(p, 1, 0, 5, 3) == q and l.neighbour(p, 1, 0, 5, 20) == r   # the row decides
  doAssert l.neighbour(q, -1, 0, 50, 3) == p and l.neighbour(r, -1, 0, 50, 20) == p
  doAssert l.neighbour(q, 0, 1, 50, 3) == r and l.neighbour(r, 0, -1, 50, 20) == q
  doAssert l.neighbour(p, -1, 0, 5, 3) == nil and l.neighbour(p, 0, 1, 5, 3) == nil
  doAssert l.neighbour(q, 1, 0, 50, 3) == nil

block tooSmall:
  let p = pane()
  let l = newLayout(p)
  var bars: seq[Bar]
  l.place(0, 0, 20, 5, bars)
  doAssert not p.canSplit(true) and not p.canSplit(false)
  l.place(0, 0, 21, 6, bars)
  doAssert p.canSplit(true) and p.canSplit(false)

echo "panes ok"

block rows:
  let fold: seq[int8] = @[0'i8, 1, 1, 0, 0, 0]          # lines 1 and 2 hidden
  doAssert shownLine(fold, 6, 1, 1) == 3 and shownLine(fold, 6, 2, -1) == 0 and shownLine(fold, 3, 1, 1) == -1
  doAssert stepShown(fold, 6, 0, 2) == 4 and stepShown(fold, 6, 4, -1) == 3 and stepShown(fold, 6, 3, -5) == 0
  doAssert shownBetween(fold, 0, 6) == 4
  let extra = @[0, 0, 0, 3, 0, 0]                         # line 3 has a 3-row picture under it
  doAssert shownBetween(fold, 0, 6, extra) == 7
  doAssert stepShown(fold, 6, 0, 2, extra) == 3           # 0 -> 3 costs 1 row, leaving 3 would cost 4 more
  doAssert stepShown(fold, 6, 0, 5, extra) == 4           # 1 + 4 = 5 rows
  doAssert stepShown(fold, 6, 3, 1, extra) == 4           # a tall picture still scrolls one line
  doAssert stepShown(fold, 6, 5, -1, extra) == 4 and stepShown(fold, 6, 5, -2, extra) == 4  # entering 3 costs 4
  doAssert stepShown(fold, 6, 5, -5, extra) == 3 and stepShown(fold, 6, 5, -6, extra) == 0

block pointAt:
  proc rs(s: string): seq[Rune] = s.toRunes
  let lines = @[rs"line one", rs"second", rs"third", rs"fourth", rs"last"]
  doAssert gutterWidth(5) == 5 and gutterWidth(1000) == 6
  doAssert pointAt(lines, @[], 0, 0, 5, 5, 0) == (0, 0)      # the gutter's cells map to column 0
  doAssert pointAt(lines, @[], 0, 0, 5, 8, 1) == (1, 3)      # cell 8 - gutter 5 = column 3
  # image rows under line 0: rows 1-2 belong to it (its end); line 1 is on row 3
  doAssert pointAt(lines, @[], 0, 0, 5, 8, 1, extra = @[2]) == (0, lines[0].len)
  doAssert pointAt(lines, @[], 0, 0, 5, 8, 2, extra = @[2]) == (0, lines[0].len)
  doAssert pointAt(lines, @[], 0, 0, 5, 8, 3, extra = @[2]) == (1, 3)
  doAssert pointAt(lines, @[], 0, 0, 5, 40, 2) == (2, 5)     # past the end: the line's end
  doAssert pointAt(lines, @[], 2, 0, 5, 5, 1) == (3, 0)      # scrolled: row 1 is line 3
  doAssert pointAt(lines, @[], 0, 0, 5, 5, 9) == (4, 0)      # below the text: the last line
  let fold = @[0'i8, 1, 1, 0, 0]                            # lines 1-2 hidden
  doAssert pointAt(lines, fold, 0, 0, 5, 5, 1) == (3, 0)     # row 1 skips the fold
  doAssert pointAt(lines, fold, 0, 3, 5, 6, 0) == (0, 4)     # horizontal scroll adds to the column
  let wide = @[rs"日本語テキスト"]
  doAssert pointAt(wide, @[], 0, 0, 0, 3, 0) == (0, 1)       # wide runes take two cells
