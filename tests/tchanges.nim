import std/[os, times, tables]
import ../src/changes

let dir = getTempDir() / "darger-tchanges"
removeDir(dir)
createDir(dir / "src")
writeFile(dir / "a.txt", "a")
writeFile(dir / "src" / "b.txt", "b")
writeFile(dir / "gone.txt", "x")
let before = snapshot(dir)
doAssert before.len == 3
doAssert changedSince(before, dir) == @[]
sleep(20)
writeFile(dir / "a.txt", "aa")                 # modified (size differs even on coarse clocks)
writeFile(dir / "src" / "new.txt", "n")        # added
removeFile(dir / "gone.txt")                   # deleted
doAssert changedSince(before, dir) == @["a.txt", "gone.txt", "src/new.txt"]
removeDir(dir)
echo "changes ok"
