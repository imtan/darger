import std/[os, strutils, osproc, sequtils]
import ../src/project

let dir = getTempDir() / "darger-tproject"
removeDir(dir)
createDir(dir / "src")
createDir(dir / "node_modules" / "x")
createDir(dir / ".hidden")
writeFile(dir / "src" / "a.nim", "")
writeFile(dir / "README.md", "")
writeFile(dir / "node_modules" / "x" / "junk.js", "")
writeFile(dir / ".hidden" / "secret", "")
let walked = projectFiles(dir)
doAssert walked == @["README.md", "src/a.nim"], $walked   # build and hidden directories skipped, sorted

discard execCmdEx("git -C " & quoteShell(dir) & " init -q && git -C " & quoteShell(dir) & " add README.md")
writeFile(dir / ".gitignore", "ignored.txt\n")
writeFile(dir / "ignored.txt", "")
writeFile(dir / "untracked.txt", "")
let listed = projectFiles(dir)
doAssert ".gitignore" in listed and "untracked.txt" in listed and "src/a.nim" in listed, $listed
doAssert "ignored.txt" notin listed and not listed.anyIt(it.startsWith(".git/")), $listed

let store = dir / "projects"
recordProject("/p/one", store)
recordProject("/p/two", store)
recordProject("/p/one", store)
doAssert loadProjects(store) == @["/p/one", "/p/two"]
removeDir(dir)
echo "project ok"
