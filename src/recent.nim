## Recently visited files, most recent first, kept in ~/.darger-recent.
import std/[os, strutils, unicode]
import fileio

const maxRecent* = 30

proc recentPath(): string = getHomeDir() / ".darger-recent"

proc loadRecent*(path = recentPath()): seq[string] =
  ## Missing or unreadable file = no entries.
  var text: string
  try: text = readFile(path)
  except CatchableError: return
  for line in text.splitLines:
    if result.len >= maxRecent: break
    if line.len == 0 or validateUtf8(line) != -1: continue
    var seen = false
    for f in result:
      if cmpPaths(f, line) == 0: seen = true
    if not seen: result.add line

proc saveRecent(files: seq[string], path = recentPath()) =
  try: atomicWrite(path, files.join("\n") & "\n")
  except CatchableError: discard

proc recordRecent*(file: string, path = recentPath()) =
  if file.len == 0 or '\n' in file or '\r' in file: return
  let file = normalizedPath(file)
  var files = @[file]
  for f in loadRecent(path):
    if files.len < maxRecent and cmpPaths(f, file) != 0: files.add f
  saveRecent(files, path)
