import std/[strutils, tables, unicode]
import experimental/diff

type
  Decision* = enum pending, accepted, rejected
  Review* = object
    original, proposed: seq[string]
    hunks*: seq[Item]
    decisions*: seq[Decision]
  ReviewView* = object
    text*: string
    colors*: seq[int8] # 1/2: removed/added, 3/4: current removed/added
    bgs*: seq[seq[int8]] # per rune: 9/10 the changed part of a removed/added line, 11/12 in the current hunk
    starts*: seq[int]

proc lines(text: string): seq[string] =
  # Keep terminators in the diff so a missing final newline is a real change.
  for line in text.splitLines(keepEol = true):
    if line.len > 0: result.add line

proc newReview*(original, proposed: string): Review =
  result.original = lines(original)
  result.proposed = lines(proposed)
  var codes: Table[string, int]
  proc encode(lines: seq[string]): seq[int] =
    for line in lines:
      if line notin codes: codes[line] = codes.len
      result.add codes[line]
  let a = encode(result.original)
  let b = encode(result.proposed)
  result.hunks = diffInt(a, b)
  result.decisions = newSeq[Decision](result.hunks.len)

proc appliedText*(r: Review): string =
  var pos = 0
  for i, h in r.hunks:
    for n in pos..<h.startA: result.add r.original[n]
    if r.decisions[i] == accepted:
      for n in h.startB..<h.startB + h.insertedB: result.add r.proposed[n]
    else:
      for n in h.startA..<h.startA + h.deletedA: result.add r.original[n]
    pos = h.startA + h.deletedA
  for n in pos..<r.original.len: result.add r.original[n]

proc changedSpan*(a, b: seq[Rune]): tuple[a, b: Slice[int]] =
  ## The part of each line outside their common prefix and suffix: what a word-level
  ## refine highlights. Empty slices (a > b) when the lines are equal.
  var head = 0
  while head < a.len and head < b.len and a[head] == b[head]: inc head
  var tail = 0
  while tail < a.len - head and tail < b.len - head and a[^(tail+1)] == b[^(tail+1)]: inc tail
  (head ..< a.len - tail, head ..< b.len - tail)

proc proposedText*(r: Review): string = r.proposed.join("")
  ## The whole proposed text.

proc hunkText*(r: Review, i: int): tuple[removed, added: string] =
  ## The lines a hunk removes from the original and adds from the proposal.
  let h = r.hunks[i]
  (r.original[h.startA ..< h.startA + h.deletedA].join(""), r.proposed[h.startB ..< h.startB + h.insertedB].join(""))

proc stats*(r: Review, i: int): tuple[removed, added: int] =
  (r.hunks[i].deletedA, r.hunks[i].insertedB)

proc hunkLabel*(r: Review, i: int): string =
  ## For the hunk list: "3  -1 +2  first changed line", with the decision when made.
  let (removed, added) = r.stats(i)
  let h = r.hunks[i]
  let first = if h.insertedB > 0: r.proposed[h.startB] elif h.deletedA > 0: r.original[h.startA] else: ""
  result = $(i + 1) & "  -" & $removed & " +" & $added
  case r.decisions[i]
  of accepted: result.add "  [taken]"
  of rejected: result.add "  [kept]"
  of pending: discard
  result.add "  " & first.strip(leading = false, chars = {'\r', '\n'})

proc view*(r: Review, current: int): ReviewView =
  var rows: seq[string]
  var colors: seq[int8]
  var bgs: seq[seq[int8]]
  proc add(line: string, prefix: string, color: int8) =
    rows.add prefix & line.strip(leading = false, chars = {'\r', '\n'})
    colors.add color
    bgs.add @[]
  var pos = 0
  for i, h in r.hunks:
    for n in pos..<h.startA: add(r.original[n], "", 0)
    result.starts.add rows.len
    let highlight = if i == current: 2'i8 else: 0'i8
    let removedAt = rows.len
    if r.decisions[i] != accepted:
      for n in h.startA..<h.startA + h.deletedA: add(r.original[n], "-", 1 + highlight)
    let addedAt = rows.len
    if r.decisions[i] != rejected:
      for n in h.startB..<h.startB + h.insertedB: add(r.proposed[n], "+", 2 + highlight)
    # Refine: the k-th removed line against the k-th added one, when both are shown.
    if r.decisions[i] == pending:
      for k in 0..<min(h.deletedA, h.insertedB):
        let a = rows[removedAt + k].toRunes
        let b = rows[addedAt + k].toRunes
        let span = changedSpan(a[1..^1], b[1..^1])  # past the "-" / "+"
        if span.a.a > span.a.b and span.b.a > span.b.b: continue
        var ra = newSeq[int8](a.len)
        for c in span.a: ra[c + 1] = 9 + highlight
        var rb = newSeq[int8](b.len)
        for c in span.b: rb[c + 1] = 10 + highlight
        bgs[removedAt + k] = ra
        bgs[addedAt + k] = rb
    pos = h.startA + h.deletedA
  for n in pos..<r.original.len: add(r.original[n], "", 0)
  result.text = rows.join("\n")
  result.colors = colors
  result.bgs = bgs
