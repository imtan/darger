## Picture files the renderer cannot decode itself (WebP: Eagle's thumbnails are WebP
## behind a .png name) are converted to PNG with the system's converter, macOS sips,
## into a cache named by the source path and modification time.
import std/[os, osproc, strutils, hashes, times]

proc cacheDir*(): string = getCacheDir() / "darger" / "pictures"

proc convertedPath*(path: string, stamp: times.Time, dir = cacheDir()): string =
  ## Where the PNG conversion of path (as of stamp) lives.
  dir / (toHex(hash(path) and 0x7fffffff, 8) & "-" & $stamp.toUnix & ".png")

proc convertToPng*(path: string, dir = cacheDir()): string =
  ## The converted file, made when missing; "" when there is no converter or it failed.
  var stamp: times.Time
  try: stamp = getLastModificationTime(path)
  except CatchableError: return ""
  result = convertedPath(path, stamp, dir)
  if fileExists(result): return
  when defined(macosx):
    try:
      createDir(dir)
      let (_, code) = execCmdEx("sips -s format png " & quoteShell(path) & " --out " & quoteShell(result),
        options = {poUsePath})
      if code != 0 or not fileExists(result): return ""
    except CatchableError: return ""
  else:
    return ""
