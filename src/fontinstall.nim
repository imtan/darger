## Verified archive members, staged privately before replacing installed files.
import std/[os, tempfiles]
import fetch, sha256, fontcatalog
import zippy/ziparchives

type FontInstall* = ref object
  font*: CatalogFont
  dir*: string
  done*: bool
  error*: string
  download: Fetch
  body, tempRoot, tempDir: string
  reader: ZipArchiveReader
  stage, member: int
  temps, added: seq[string]
  backups: seq[(string, string)]
  madeDir: bool

proc cleanup(i: FontInstall) =
  if i.download != nil:
    try: i.download.cancel()
    except CatchableError as e: i.error.add "; " & e.msg
    i.download = nil
  if i.reader != nil:
    try: i.reader.close()
    except CatchableError as e: i.error = e.msg
    i.reader = nil
  if i.error.len > 0:
    for path in i.added:
      try: removeFile(path)
      except CatchableError as e: i.error.add "; " & e.msg
    for pair in i.backups:
      try: moveFile(pair[1], pair[0])
      except CatchableError as e: i.error.add "; " & e.msg
  for path in i.temps:
    try: removeFile(path)
    except CatchableError as e: i.error.add "; " & e.msg
  if i.tempDir.len > 0:
    try: removeDir(i.tempDir)
    except CatchableError as e: i.error = e.msg
  if i.madeDir and i.error.len > 0:
    try:
      var empty = true
      for kind, path in walkDir(i.dir): empty = false
      if empty: removeDir(i.dir)
    except CatchableError: discard
  i.body = ""
  i.done = true

proc startFromArchive*(font: CatalogFont, dir: string, archive: string, tempRoot = ""): FontInstall =
  result = FontInstall(font: font, dir: dir, body: archive, tempRoot: tempRoot, stage: 1)
  result.error = checkEntry(font)
  if result.error.len > 0: result.cleanup()

proc startInstall*(font: CatalogFont, dir: string, command: seq[string]): FontInstall =
  result = startFromArchive(font, dir, "")
  if result.done: return
  try:
    result.download = startFetch(command & @["--max-time", "600", "--proto", "=https",
      "--proto-redir", "=https"], font.url, "font")
    result.stage = 0
  except CatchableError as e:
    result.error = "download failed: " & e.msg
    result.cleanup()

proc step*(i: FontInstall): bool =
  ## One download poll, archive check, member, or commit per tick; never raises.
  if i.done: return true
  try:
    case i.stage
    of 0:
      if not i.download.poll(): return false
      if i.download.error.len > 0:
        raise newException(IOError, "download failed: " & i.download.error)
      i.body = move(i.download.body)
      i.download = nil
      i.stage = 1
    of 1:
      if sha256Hex(i.body) != i.font.sha256: raise newException(IOError, "archive hash mismatch")
      i.tempDir = createTempDir("darger-font-", "", i.tempRoot)
      createDir(i.tempDir / "download")
      let path = i.tempDir / "download/archive.zip"
      writeFile(path, i.body)
      i.body = ""
      i.reader = openZipArchive(path)
      i.stage = 2
    of 2:
      let file = i.font.files[i.member]
      let body = i.reader.extractFile(file.member)
      if sha256Hex(body) != file.sha256: raise newException(IOError, file.name & ": hash mismatch")
      writeFile(i.tempDir / file.name, body)
      inc i.member
      if i.member == i.font.files.len:
        i.reader.close()
        i.reader = nil
        i.stage = 3
    else:
      i.madeDir = not dirExists(i.dir) and not fileExists(i.dir)
      createDir(i.dir)
      for file in i.font.files:
        let (handle, path) = createTempFile(".darger-font-", ".tmp", i.dir)
        i.temps.add path
        try:
          handle.write(readFile(i.tempDir / file.name))
          setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
        finally: handle.close()
      for n, file in i.font.files:
        let path = i.dir / file.name
        if dirExists(path) and not symlinkExists(path): raise newException(IOError, path & ": is a directory")
        if fileExists(path) or symlinkExists(path):
          let (handle, backup) = createTempFile(".darger-font-", ".tmp", i.dir)
          i.temps.add backup
          handle.close()
          moveFile(path, backup)
          i.backups.add (path, backup)
        moveFile(i.temps[n], path)
        i.added.add path
      i.cleanup()
  except CatchableError as e:
    i.error = e.msg
    i.cleanup()
  i.done

proc cancel*(i: FontInstall) =
  if i.done: return
  try:
    if i.download != nil: i.download.cancel()
  except CatchableError: discard
  i.error = "cancelled"
  i.cleanup()
