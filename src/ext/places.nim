## *places*: a grep-mode-like list. n / p move between the `path:line: note` lines
## while the other window follows to that spot, Enter jumps there, q closes. It
## opens for a file with the `-*- mode: grep ... -*-` cookie, for the current
## buffer with M-x places, and for the agent's answers (C-c l).
import std/[os, strutils, unicode, tables]
import ../[core, buffer, buffers, lisp, syntax, chat, places, panes]
import web

var
  pbuf: Buffer         # the list shown
  pfaces: seq[seq[Face]]
  pplaces: seq[Place]
  psource: Buffer      # the buffer the list came from (o edits it); nil for agent answers
  ptitle: string

proc buildPlaces(text, dir: string) =
  pplaces = parsePlacesList(text, dir)
  pbuf = newBuffer(text)
  pbuf.path = "*places*"
  pfaces = @[]
  var rows: seq[int]
  for p in pplaces: rows.add p.row
  for i, line in pbuf.lines:
    var f = newSeq[Face](line.len)
    let s = $line
    if i == 0 and isPlacesText(s): (for k in 0..<f.len: f[k] = fComment)
    elif s.strip.startsWith("=="): (for k in 0..<f.len: f[k] = fKeyword)
    elif i in rows:
      let colon = s.find(": ")
      let upTo = if colon > 0: s[0..colon].runeLen else: f.len
      for k in 0..<min(upTo, f.len): f[k] = fConstant
    pfaces.add f

proc follow() =
  ## The other window shows the place on the cursor row (only when the row is one).
  let i = placeAt(pplaces, pbuf.cursor.line)
  if i < 0: return
  let p = pplaces[i]
  let keep = pane
  let other = otherPaneFor()
  if other == nil or other == pane: return
  selectPane(other)
  try:
    visit(p.path)
    b.cursor = (min(p.line, b.lines.high), min(p.col, b.lines[min(p.line, b.lines.high)].len))
    renderer.top = max(0, b.cursor.line - max(1, renderer.rows) div 2)
  except CatchableError as e: echoLine = e.msg
  selectPane(keep)
  echoLine = shortPath(p.path, 50) & ":" & $(p.line + 1) & (if p.note.len > 0: "  " & p.note else: "")

proc moveTo(i: int) =
  if i < 0:
    echoLine = "No more places"
    return
  pbuf.cursor = (pplaces[i].row, 0)
  follow()

proc finishPlaces() =
  finishOverlay()
  pbuf = nil

proc openPlacesText*(text, dir, title: string, source: Buffer = nil) =
  ## The list over the editor; the first place is followed at once.
  if mode notin ["", "eval", "execute"]: closeOverlay()
  beginOverlay("places")
  ptitle = title
  psource = source
  buildPlaces(text, dir)
  if pplaces.len == 0: echoLine = "No places (path:line lines naming existing files) in " & title
  else: moveTo(0)

proc dispatchPlaces(c: string) =
  if c in ["q", "C-g", "escape"]:
    finishPlaces()
    return
  let full = overlayKey(c)
  if full.len == 0: return
  let command = keymap.getOrDefault(full).symName
  if full != "C-l": recenterCycle = 0
  case full
  of "n", "M-n", "C-n", "down": moveTo(nextPlace(pplaces, pbuf.cursor.line, 1))
  of "p", "M-p", "C-p", "up": moveTo(nextPlace(pplaces, pbuf.cursor.line, -1))
  of "enter", "C-m", "C-j", "f":
    let i = placeAt(pplaces, pbuf.cursor.line)
    if i < 0: echoLine = "Not a place: n / p move to one"
    else:
      let p = pplaces[i]
      finishPlaces()
      try:
        visit(p.path)
        b.cursor = (min(p.line, b.lines.high), min(p.col, b.lines[min(p.line, b.lines.high)].len))
      except CatchableError as e: echoLine = e.msg
  of "o":
    if psource == nil: echoLine = "This list came from the agent; it has no file"
    else:
      finishPlaces()
      switchTo(psource)
  of "?": echoLine = "n / p: next / previous place (the other window follows)   Enter: go there   o: edit the list's file   q: close"
  of "f1":
    finishPlaces()
    dispatch(full)
  of "C-x C-c": quitEditor()
  else:
    if command == "places": finishPlaces()
    elif overlayMove(pbuf, full, command): discard
    else: echoLine = full & " is undefined"

defineMode(Mode(name: "places", modeName: "Places", buffer: proc(): Buffer = pbuf,
  faces: proc(): seq[seq[Face]] = pfaces,
  message: proc(): string = (if echoLine.len > 0: echoLine else: ptitle & "  n/p:move Enter:go o:edit q:close ?:help"),
  onKey: dispatchPlaces, onClose: finishPlaces))

proc placesFromBuffer*(buf: Buffer) =
  let dir = if buf.path.len > 0 and not buf.path.startsWith("*"): parentDir(buf.path)
            else: rootFromDir(getCurrentDir())
  openPlacesText(buf.text, dir, (if buf.path.len > 0: extractFilename(buf.path) else: "places"), buf)

interp.defPrimitive("places", proc(args: seq[Value]): Value =
  ## M-x places: the current buffer as a places list; inside the list, closes it.
  args.arity(0, 0)
  if mode == "places": finishPlaces()
  elif mode in ["", "eval", "execute"]: placesFromBuffer(b)
  else: echoLine = "places is unavailable here"
  nilValue())

for (name, direction) in [("places-next", 1), ("places-previous", -1)]:
  closureScope:
    let direction = direction
    interp.defPrimitive(name, proc(args: seq[Value]): Value =
      ## n / p as commands, for scripts and agents walking the list.
      args.arity(0, 0)
      if mode != "places": echoLine = "No places list is open"
      else: moveTo(nextPlace(pplaces, pbuf.cursor.line, direction))
      nilValue())

visitHooks.add proc() =
  # A file written as a grep-mode buffer opens as a places list over itself.
  if b.lines.len > 0 and isPlacesText($b.lines[0]) and mode == "" and
      interp.env.values["places-auto-open"].kind != vNil: placesFromBuffer(b)

defaults.add """
(setq places-auto-open t)
"""
