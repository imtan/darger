## A places list, as Emacs' grep-mode buffers: lines of `path:line: note` among
## headings and notes, with an optional first-line cookie
## `-*- mode: grep; default-directory: "/dir/" -*-` naming the directory relative
## paths are under. Agents (Claude Code) write these to lay a trail through a project.
import std/[os, strutils]
import grep

type Place* = object
  row*: int        ## the line of the list the place is on
  path*: string    ## absolute
  line*, col*: int ## 0-based
  note*: string

proc cookieDirectory*(firstLine: string): string =
  ## The default-directory of a `-*- ... -*-` cookie, "" when none.
  let a = firstLine.find("default-directory:")
  if a < 0 or "-*-" notin firstLine: return ""
  var rest = firstLine[a + 18 ..^ 1].strip
  if rest.startsWith("\""):
    let z = rest.find('"', 1)
    if z > 0: return rest[1..<z]
  let z = rest.find({';', ' ', '-'})
  if z > 0: rest[0..<z] else: rest

proc isPlacesText*(firstLine: string): bool =
  "-*-" in firstLine and "mode: grep" in firstLine

proc parsePlacesList*(text, fallbackDir: string): seq[Place] =
  ## Every `path:line: note` line that names an existing file, with its row.
  let lines = text.splitLines
  let dir = if lines.len > 0 and cookieDirectory(lines[0]).len > 0: expandTilde(cookieDirectory(lines[0])) else: fallbackDir
  for i, l in lines:
    if l.strip.startsWith("==") or l.strip.startsWith("-*-") or l.strip.len == 0: continue
    let hits = parsePlaces(l, dir)
    if hits.len == 1: result.add Place(row: i, path: hits[0].path, line: hits[0].line, col: hits[0].col, note: hits[0].text)

proc placeRows*(places: seq[Place]): seq[int] =
  for p in places: result.add p.row

proc nextPlace*(places: seq[Place], row, direction: int): int =
  ## The index of the first place after (or before) row; -1 when none.
  if direction > 0:
    for i, p in places:
      if p.row > row: return i
  else:
    for i in countdown(places.high, 0):
      if places[i].row < row: return i
  -1

proc placeAt*(places: seq[Place], row: int): int =
  for i, p in places:
    if p.row == row: return i
  -1
