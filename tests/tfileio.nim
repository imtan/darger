when not defined(windows):
  import std/[os, posix, strutils, tempfiles]
  import ../src/fileio

  proc mode(path: string): Mode =
    var st: Stat
    doAssert stat(path.cstring, st) == 0
    st.st_mode and Mode(0o7777)

  let dir = createTempDir("darger-tfileio-", "")
  try:
    block:
      let p = dir / "script.sh"
      writeFile(p, "old")
      doAssert chmod(p.cstring, Mode(0o755)) == 0
      atomicWrite(p, "new")
      doAssert readFile(p) == "new" and mode(p) == Mode(0o755)
    block:
      let p = dir / "fresh.txt"
      let m = umask(0)
      discard umask(m)
      atomicWrite(p, "x")
      doAssert readFile(p) == "x" and mode(p) == (Mode(0o666) and not m)
    block:
      let real = dir / "real.txt"
      let link = dir / "link.txt"
      writeFile(real, "old")
      createSymlink("real.txt", link)
      atomicWrite(link, "new")
      doAssert symlinkExists(link) and expandSymlink(link) == "real.txt"
      doAssert readFile(real) == "new"
    block:
      createDir(dir / "sub")
      let link = dir / "sub" / "rel.txt"
      createSymlink("../target.txt", link)
      atomicWrite(link, "made")
      doAssert symlinkExists(link) and readFile(dir / "target.txt") == "made"
    block:  # relative ".." in a link reached through a symlinked directory
      createDir(dir / "real" / "sub")
      writeFile(dir / "real" / "target2.txt", "original")
      createSymlink("real/sub", dir / "alias")
      createSymlink("../target2.txt", dir / "real" / "sub" / "f")
      atomicWrite(dir / "alias" / "f", "edited")
      doAssert readFile(dir / "real" / "target2.txt") == "edited"
      doAssert not fileExists(dir / "target2.txt")
    block:
      createSymlink("b", dir / "a")
      createSymlink("a", dir / "b")
      var failed = false
      try: atomicWrite(dir / "a", "x")
      except IOError: failed = true
      doAssert failed and symlinkExists(dir / "a")
    if geteuid() != 0:  # root bypasses W_OK
      let p = dir / "ro.txt"
      writeFile(p, "keep")
      doAssert chmod(p.cstring, Mode(0o444)) == 0
      var failed = false
      try: atomicWrite(p, "lost")
      except IOError: failed = true
      doAssert failed and readFile(p) == "keep" and mode(p) == Mode(0o444)
    var stray = false
    for f in walkDir(dir):
      if f.path.extractFilename.startsWith(".darger-"): stray = true
    doAssert not stray
  finally:
    removeDir(dir)
  echo "All fileio checks passed"
