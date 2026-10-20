## Grep mode: a grep-mode-like list that is an ordinary buffer, so it stays in its
## window while C-x o, splits and buffer switching work as usual. In a grep buffer
## n / p move between the `path:line: note` lines while the other window follows to
## that spot (both lines highlighted), Enter goes there, o toggles editing (the list
## is read-only otherwise), g re-reads the list, q leaves it. A file with the
## `-*- mode: grep ... -*-` cookie, or one that reads like grep output, becomes one
## when visited; M-x grep-mode makes the current buffer one; M-x rgrep and the
## agent's answers (C-c l) open as one.
import std/[os, strutils, unicode, tables]
import ../[core, buffer, buffers, lisp, syntax, chat, places]

type PlacesInfo = object
  places: seq[Place]
  dir, title: string
  editing: bool

var
  placesOf: Table[Buffer, PlacesInfo]
  followed: Buffer       # the buffer the other window shows for the current place
  followedLine = -1

proc info(buf: Buffer): PlacesInfo = placesOf.getOrDefault(buf)

proc reparse(buf: Buffer) =
  if buf in placesOf: placesOf[buf].places = parsePlacesList(buf.text, placesOf[buf].dir)

proc currentPlace(buf: Buffer): int = placeAt(info(buf).places, buf.cursor.line)

proc follow(buf: Buffer) =
  ## The other window shows the place on the cursor row; the list keeps the selection.
  let i = currentPlace(buf)
  if i < 0: return
  let p = info(buf).places[i]
  let keep = pane
  let other = otherPaneFor()
  if other == nil or other == pane: return
  selectPane(other)
  try:
    visit(p.path)
    b.cursor = (min(p.line, b.lines.high), min(p.col, b.lines[min(p.line, b.lines.high)].len))
    renderer.top = max(0, b.cursor.line - max(1, renderer.rows) div 2)
    followed = b
    followedLine = b.cursor.line
  except CatchableError as e: echoLine = e.msg
  selectPane(keep)
  echoLine = shortPath(p.path, 50) & ":" & $(p.line + 1) & (if p.note.len > 0: "  " & p.note else: "")

proc moveTo(buf: Buffer, i: int) =
  if i < 0:
    echoLine = "No more places"
    return
  buf.cursor = (info(buf).places[i].row, 0)
  buf.goal = -1
  follow(buf)

proc goThere(buf: Buffer) =
  ## Enter: the place in the other window, which becomes the selected one (as RET in grep).
  let i = currentPlace(buf)
  if i < 0:
    echoLine = "Not a place: n / p move to one"
    return
  let p = info(buf).places[i]
  let other = otherPaneFor()
  if other != nil and other != pane: selectPane(other)
  try:
    visit(p.path)
    b.cursor = (min(p.line, b.lines.high), min(p.col, b.lines[min(p.line, b.lines.high)].len))
  except CatchableError as e: echoLine = e.msg

proc makePlaces*(buf: Buffer, dir, title: string) =
  ## buf becomes a places list (read-only, its lines parsed); the first place is followed.
  placesOf[buf] = PlacesInfo(dir: dir, title: title)
  reparse(buf)
  if buf == b:
    if info(buf).places.len == 0: echoLine = "No places (path:line lines naming existing files) in " & title
    else: moveTo(buf, 0)

proc openPlacesText*(text, dir, title: string) =
  ## A fresh *places* buffer with the text, shown in the selected window.
  let buf = newBuffer(text)
  reg.add(buf, "*grep*")
  switchTo(buf)
  buf.modified = false
  makePlaces(buf, dir, title)

proc placesDir*(buf: Buffer): string =
  ## The directory relative paths resolve under: the cookie's when there is one, else
  ## whichever of the file's directory, its project root and the working directory
  ## makes the most lines into places (grep output is usually relative to the project).
  if buf.lines.len > 0 and cookieDirectory($buf.lines[0]).len > 0: return expandTilde(cookieDirectory($buf.lines[0]))
  var candidates: seq[string]
  if buf.path.len > 0 and not buf.path.startsWith("*"):
    candidates.add parentDir(buf.path)
    candidates.add rootFromDir(parentDir(buf.path))
  candidates.add getCurrentDir()
  candidates.add rootFromDir(getCurrentDir())
  result = candidates[0]
  var best = -1
  for dir in candidates:
    let n = parsePlacesList(buf.text, dir).len
    if n > best:
      best = n
      result = dir

proc placesFromBuffer*(buf: Buffer) =
  makePlaces(buf, placesDir(buf), (if buf.path.len > 0: extractFilename(buf.path) else: "grep"))

proc leave(buf: Buffer) =
  ## q: the other window when there is one, else the previous buffer.
  let other = otherPaneFor()
  if other != nil and other != pane: selectPane(other)
  else: discard interp.evalString("(previous-buffer)", "<places>")

proc placesKey(c: string): bool =
  # The list's keys, only while the list is current, read-only, and no prefix is pending.
  # Named keys arrive through keyFilters, typed letters through runeFilters (below).
  if mode.len > 0 or prefix.len > 0 or b notin placesOf or placesOf[b].editing: return false
  case c
  of "n": moveTo(b, nextPlace(info(b).places, b.cursor.line, 1))
  of "p": moveTo(b, nextPlace(info(b).places, b.cursor.line, -1))
  of "enter", "C-m", "C-j", "f": goThere(b)
  of "o":
    placesOf[b].editing = true
    echoLine = "Editing the list (o again, or g, returns to the places keys)"
  of "g":
    reparse(b)
    echoLine = $info(b).places.len & " places"
  of "q": leave(b)
  of "?": echoLine = "n / p: next / previous place (the other window follows)   Enter: go there   o: edit   g: re-read   q: leave"
  else: return false
  true
keyFilters.add placesKey
runeFilters.add proc(r: Rune): bool =
  # Typed letters are the list's keys; anything else is swallowed (read-only; o edits).
  if mode.len > 0 or prefix.len > 0 or b notin placesOf or placesOf[b].editing: return false
  if placesKey($r): return true
  echoLine = "The grep buffer is read-only (o to edit)"
  true

faceProviders.add proc(buf: Buffer): seq[seq[Face]] =
  if buf notin placesOf: return
  var rows: seq[int]
  for p in placesOf[buf].places: rows.add p.row
  for i, line in buf.lines:
    var f = newSeq[Face](line.len)
    let s = $line
    if i == 0 and isPlacesText(s): (for k in 0..<f.len: f[k] = fComment)
    elif s.strip.startsWith("=="): (for k in 0..<f.len: f[k] = fKeyword)
    elif i in rows:
      let colon = s.find(": ")
      let upTo = if colon > 0: s[0..colon].runeLen else: f.len
      for k in 0..<min(upTo, f.len): f[k] = fConstant
    result.add f

bandProviders.add proc(buf: Buffer): seq[int8] =
  # The current place's row in the list; the followed line in the other window.
  if buf in placesOf:
    if currentPlace(buf) >= 0:
      result = newSeq[int8](buf.lines.len)
      result[buf.cursor.line] = 5
  elif buf == followed and followedLine >= 0 and followedLine < buf.lines.len and b in placesOf:
    result = newSeq[int8](buf.lines.len)
    result[followedLine] = 5

killHooks.add proc(buf: Buffer) =
  placesOf.del buf
  if buf == followed: followed = nil

modeNameProviders.add proc(buf: Buffer): string = (if buf in placesOf: "Grep" else: "")

for name in ["grep-mode", "places"]:
  interp.defPrimitive(name, proc(args: seq[Value]): Value =
    ## M-x grep-mode: the current buffer as a grep buffer; in one already, toggles editing.
    args.arity(0, 0)
    if b in placesOf:
      placesOf[b].editing = not placesOf[b].editing
      if not placesOf[b].editing: reparse(b)
      echoLine = if placesOf[b].editing: "Editing the list" else: "Grep keys: n / p / Enter / q"
    else: placesFromBuffer(b)
    nilValue())
for (name, direction) in [("grep-next", 1), ("grep-previous", -1), ("places-next", 1), ("places-previous", -1)]:
  closureScope:
    let direction = direction
    interp.defPrimitive(name, proc(args: seq[Value]): Value =
      args.arity(0, 0)
      if b notin placesOf: echoLine = "Not a grep buffer"
      else: moveTo(b, nextPlace(info(b).places, b.cursor.line, direction))
      nilValue())

proc autoOpen(): bool =
  let v = interp.env.values.getOrDefault("grep-auto-open")
  let old = interp.env.values.getOrDefault("places-auto-open")
  (v == nil or v.kind != vNil) and (old == nil or old.kind != vNil)

visitHooks.add proc() =
  # A file written as a grep-mode buffer (the cookie), or one that reads like grep
  # output (rg / grep -n saved, an agent's trail), is a grep buffer from the start.
  if b notin placesOf and b.lines.len > 0 and autoOpen():
    if isPlacesText($b.lines[0]) or (b.lines.len <= 5000 and looksLikeGrep(b.text, placesDir(b))): placesFromBuffer(b)

defaults.add """
(setq grep-auto-open t)
"""
