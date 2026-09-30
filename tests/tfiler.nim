import std/[os, tempfiles, times, strutils]
import ../src/filer

block:
  let dir = createTempDir("darger-filer-", "")
  defer: removeDir(dir)
  makeDirectory(dir / "zDir")
  makeDirectory(dir / "ADir")
  doAssert readDirectory(dir / "ADir").len == 0
  writeFile(dir / "z.txt", "z")
  writeFile(dir / "B.txt", "b")
  writeFile(dir / ".hidden", "")
  let entries = readDirectory(dir)
  var names: seq[string]
  for entry in entries: names.add entry.name
  doAssert names == @["ADir", "zDir", ".hidden", "B.txt", "z.txt"]
  doAssert entries[0].isDir and entries[1].isDir
  doAssert humanSize(0) == "0"
  doAssert humanSize(512) == "512"
  doAssert humanSize(1024) == "1K"
  doAssert humanSize(1229) == "1.2K"
  doAssert humanSize(34 * 1024 * 1024) == "34M"
  let stamp = dateTime(2026, mSep, 29, 12, 34, 0, zone = local()).toTime
  doAssert formatRow(Entry(name: "日本語.txt", kind: pcFile, size: 512, modified: stamp)) ==
    "-    512 2026-09-29 12:34 日本語.txt"
  doAssert formatRow(Entry(name: "資料", kind: pcDir, modified: stamp)) ==
    "d        2026-09-29 12:34 資料/"
  doAssert formatRow(Entry(name: "link", kind: pcLinkToDir, modified: stamp)).startsWith("l ")
  doAssert formatRow(Entry(name: "a\nb", modified: stamp)).endsWith("a\\nb")
  # an entry whose size and time could not be read, and the column the name starts at
  doAssert formatRow(Entry(name: "locked", kind: pcFile)) == "-      0" & ' '.repeat(18) & "locked"
  doAssert formatRow(Entry(name: "x", modified: stamp)).len == nameCol + 1
  var refused = false
  try: renameEntry(dir / "z.txt", dir / "B.txt")
  except IOError: refused = true
  doAssert refused
  doAssert readFile(dir / "z.txt") == "z" and readFile(dir / "B.txt") == "b"
  renameEntry(dir / "z.txt", dir / "renamed.txt")
  doAssert not fileExists(dir / "z.txt") and readFile(dir / "renamed.txt") == "z"
  renameEntry(dir / "zDir", dir / "renamedDir")
  doAssert dirExists(dir / "renamedDir") and not dirExists(dir / "zDir")
  makeDirectory(dir / "new" / "nested")
  doAssert dirExists(dir / "new" / "nested")
  var failed = false
  try: discard readDirectory(dir / "missing")
  except OSError: failed = true
  doAssert failed
  echo "filer ok"
