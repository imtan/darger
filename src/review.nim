import std/[strutils, tables]
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

proc view*(r: Review, current: int): ReviewView =
  var rows: seq[string]
  var colors: seq[int8]
  proc add(line: string, prefix: string, color: int8) =
    rows.add prefix & line.strip(leading = false, chars = {'\r', '\n'})
    colors.add color
  var pos = 0
  for i, h in r.hunks:
    for n in pos..<h.startA: add(r.original[n], "", 0)
    result.starts.add rows.len
    let highlight = if i == current: 2'i8 else: 0'i8
    if r.decisions[i] != accepted:
      for n in h.startA..<h.startA + h.deletedA: add(r.original[n], "-", 1 + highlight)
    if r.decisions[i] != rejected:
      for n in h.startB..<h.startB + h.insertedB: add(r.proposed[n], "+", 2 + highlight)
    pos = h.startA + h.deletedA
  for n in pos..<r.original.len: add(r.original[n], "", 0)
  result.text = rows.join("\n")
  result.colors = colors
