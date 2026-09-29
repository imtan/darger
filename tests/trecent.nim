import std/[os, tempfiles]
import ../src/recent

let dir = createTempDir("darger-recent-", "")
let path = dir / "recent"
doAssert loadRecent(path).len == 0
recordRecent("/a", path)
recordRecent("/b", path)
recordRecent("/a", path)
doAssert loadRecent(path) == @["/a", "/b"]
doAssert readFile(path) == "/a\n/b\n"
recordRecent("", path)
doAssert loadRecent(path) == @["/a", "/b"]
for i in 0..<40: recordRecent("/f" & $i, path)
let files = loadRecent(path)
doAssert files.len == maxRecent and files[0] == "/f39"
writeFile(path, "/x\r\n/x\n\n/y\n")
doAssert loadRecent(path) == @["/x", "/y"]
removeDir(dir)
echo "recent ok"
