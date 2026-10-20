import std/[os, tempfiles, times]
import ../src/vcline

let tree = createTempDir("darger-vcline-test-", "")
try:
  var cache: BranchCache
  let root = tree / "repo"
  createDir(root / ".git")
  createDir(root / "src")
  let head = root / ".git" / "HEAD"
  writeFile(head, "ref: refs/heads/main\n")
  let stamp = getLastModificationTime(head)
  doAssert cache.branchFor("", 0) == ""
  doAssert cache.branchFor(tree / "outside.txt", 0) == ""
  doAssert cache.branchFor(root / "src" / "a.nim", 0) == "main"
  writeFile(head, "ref: refs/heads/topic\n")
  setLastModificationTime(head, stamp + initDuration(seconds = 2))
  doAssert cache.branchFor(root / "b.nim", 0.5) == "main"
  doAssert cache.branchFor(root / "src" / "a.nim", 1) == "topic"
  writeFile(head, "ref: refs/heads/unchanged-time\n")
  setLastModificationTime(head, stamp + initDuration(seconds = 2))
  doAssert cache.branchFor(root / "b.nim", 2) == "topic"
  writeFile(head, "0123456789abcdef\n")
  setLastModificationTime(head, stamp + initDuration(seconds = 3))
  doAssert cache.branchFor(root / "b.nim", 3) == "0123456"
  let work = tree / "work"
  createDir(work)
  writeFile(work / ".git", "gitdir: ../repo/.git\n")
  doAssert cache.branchFor(work / "file", 3) == "0123456"
  writeFile(head, "ref: refs/heads/worktree\n")
  setLastModificationTime(head, stamp + initDuration(seconds = 4))
  doAssert cache.branchFor(work / "file", 3.9) == "0123456"
  doAssert cache.branchFor(work / "file", 4) == "worktree"
  writeFile(work / ".git", "gitdir: /nonexistent/darger-git\n")
  doAssert cache.branchFor(work / "file", 5) == ""
  writeFile(work / ".git", "gitdir: " & root / ".git" & "\n")
  doAssert cache.branchFor(work / "file", 6) == "worktree"
finally:
  removeDir(tree)
echo "vcline ok"
