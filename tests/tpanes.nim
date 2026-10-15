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

block tooSmall:
  let p = pane()
  let l = newLayout(p)
  var bars: seq[Bar]
  l.place(0, 0, 20, 5, bars)
  doAssert not p.canSplit(true) and not p.canSplit(false)
  l.place(0, 0, 21, 6, bars)
  doAssert p.canSplit(true) and p.canSplit(false)

echo "panes ok"
