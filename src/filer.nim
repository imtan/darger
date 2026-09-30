import std/[os, strutils, times, algorithm, unicode]

type Entry* = object
  name*: string
  kind*: PathComponent
  size*: BiggestInt
  modified*: Time

const nameCol* = 26  ## where formatRow puts the name

proc isDir*(entry: Entry): bool = entry.kind in {pcDir, pcLinkToDir}

proc readDirectory*(path: string): seq[Entry] =
  for kind, name in walkDir(path, relative = true, checkDir = true):
    var entry = Entry(name: name, kind: kind)
    try:
      let info = getFileInfo(path / name, followSymlink = false)
      entry.size = info.size
      entry.modified = info.lastWriteTime
    except OSError: discard  # locked or protected (pagefile.sys, another user's home): no size or time
    result.add entry
  result.sort(proc(a, b: Entry): int =
    result = cmp(not a.isDir, not b.isDir)
    if result == 0: result = cmp(unicode.toLower(a.name), unicode.toLower(b.name))
    if result == 0: result = cmp(a.name, b.name))

proc humanSize*(size: BiggestInt): string =
  if size < 1024: return $size
  var value = size.float
  var unit = 0
  while value >= 1024 and unit < 6:
    value /= 1024
    inc unit
  result = formatFloat(value, ffDecimal, if value < 10: 1 else: 0)
  if result.endsWith(".0"): result.setLen(result.len - 2)
  if result.endsWith("."): result.setLen(result.len - 1)
  result.add " KMGTPE"[unit]

proc formatRow*(entry: Entry): string =
  let tag = if entry.kind in {pcLinkToFile, pcLinkToDir}: 'l'
            elif entry.isDir: 'd' else: '-'
  $tag & " " & align(if entry.isDir: "" else: humanSize(entry.size), 6) & " " &
    (if entry.modified == Time(): ' '.repeat(16) else: entry.modified.local.format("yyyy-MM-dd HH:mm")) &
    " " &
    entry.name.replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t") &
    (if entry.isDir: "/" else: "")

proc renameEntry*(source, target: string) =
  if target.len == 0: raise newException(ValueError, "Expected a destination name")
  if fileExists(target) or dirExists(target) or symlinkExists(target):
    raise newException(IOError, "Target already exists: " & target)
  if dirExists(source) and not symlinkExists(source): moveDir(source, target)
  else: moveFile(source, target)

proc makeDirectory*(path: string) =
  if path.len == 0: raise newException(ValueError, "Expected a directory name")
  createDir(path)

when defined(windows):
  import std/winlean
  type FileOperation {.bycopy.} = object
    hwnd: Handle
    operation: uint32
    source, target: WideCString
    flags: uint16
    aborted: WINBOOL
    mappings: pointer
    title: WideCString
  proc shFileOperation(op: ptr FileOperation): cint
    {.stdcall, importc: "SHFileOperationW", dynlib: "shell32".}
elif defined(linux):
  import std/osproc

proc trashEntry*(path: string) =
  if '\0' in path: raise newException(ValueError, "Invalid path")
  when defined(windows):
    let paths = newWideCString(absolutePath(path) & "\0")
    var op = FileOperation(operation: 3, source: paths,
      # ALLOWUNDO, NOCONFIRMATION, SILENT, NOERRORUI; WANTNUKEWARNING makes Windows ask
      # before destroying what the Recycle Bin cannot hold, which NOCONFIRMATION would skip
      flags: 0x0040'u16 or 0x0010'u16 or 0x0004'u16 or 0x0400'u16 or 0x4000'u16)
    let code = shFileOperation(addr op)
    if code != 0 or op.aborted != 0:
      raise newException(IOError, "Trash failed (" & $code & "): " & path)
  elif defined(linux):
    let process = startProcess("gio", args = @["trash", "--", absolutePath(path)],
      options = {poUsePath, poStdErrToStdOut})
    defer: process.close()
    let (output, code) = process.readLines()
    if code != 0: raise newException(IOError, "Trash failed: " & output.join("\n"))
  else:
    # ponytail: trash supports Windows/Linux only; add a native API for other platforms.
    raise newException(IOError, "Trash is not supported here")
