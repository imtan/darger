import std/[os, osproc, tempfiles, tables, strutils, sequtils]
import ../src/[checkpoints, branchdiff]

let home = createTempDir("darger-checkpoints-", "")
putEnv("HOME", home)
let root = home / "repo"
createDir(root)
proc git(args: string): string =
  let r = execCmdEx("git -C " & quoteShell(root) & " -c commit.gpgsign=false " & args)
  doAssert r.exitCode == 0, r.output
  r.output

discard git("init -b main")
discard git("config user.name Test")
discard git("config user.email test@example.invalid")
writeFile(root / "a", "base\n")
writeFile(root / "deleted", "original\n")
discard git("add .")
discard git("commit -m initial")
writeFile(root / "a", "staged\n")
discard git("add a")
writeFile(root / "a", "unstaged\n")
writeFile(root / "untracked space", "before\n")
writeFile(root / "empty", "")
let index = git("write-tree")
let status = git("status --porcelain=v1 -z")
let cp = createCheckpoint(root, "test-session", "first prompt\nmore")
doAssert git("write-tree") == index and git("status --porcelain=v1 -z") == status
doAssert git("rev-parse " & cp.refName).strip == cp.revision
doAssert git("show " & cp.revision & ":a") == "unstaged\n"
doAssert git("show " & cp.revision & "^2:a") == "staged\n"
writeFile(root / "a", "after\n")
writeFile(root / "untracked space", "changed\n")
writeFile(root / "added", "new\n")
removeFile(root / "deleted")
removeFile(root / "empty")
finishCheckpoint(cp)
let loaded = loadCheckpoint(cp.storage)
doAssert loaded.before == cp.before
doAssert loaded.changed == @["a", "added", "deleted", "empty", "untracked space"]
doAssert listCheckpoints(root).len == 1
let diff = checkpointDiff(loaded)
doAssert diff.len == 5 and diff[0].added == 1 and diff[0].removed == 1
doAssert diff[1].isNew and diff[2].deleted and diff[3].deleted
doAssert "+after" in diffView(diff, "turn", "before").text
writeFile(root / "a", "later\n")
doAssert "+later" notin diffView(checkpointDiff(loaded), "turn", "before").text
# Detached HEAD / clean worktree still pins a useful checkpoint.
discard git("reset --hard HEAD")
let clean = createCheckpoint(root, "clean", "clean turn")
doAssert clean.revision == git("rev-parse HEAD").strip
# Retention deletes only this session's oldest refs, preserving another session.
for i in 2..52: discard createCheckpoint(root, "test-session", $i)
let all = listCheckpoints(root)
let kept = all.filterIt(it.session == "test-session")
doAssert kept.len == 50 and kept[0].number == 3 and kept[^1].number == 52
doAssert all.anyIt(it.session == "clean")
doAssert git("for-each-ref --format='%(refname)' refs/darger/checkpoints/test-session").splitLines.filterIt(it.len > 0).len == 50
doAssert not fileExists(cp.storage)
# Non-Git snapshots survive process/session reload, including deleted files.
let plain = home / "plain"
createDir(plain)
writeFile(plain / "old", "original\n")
let nongit = createCheckpoint(plain, "plain-session", "plain")
writeFile(plain / "old", "modified\n")
writeFile(plain / "new", "new\n")
finishCheckpoint(nongit)
let again = loadCheckpoint(nongit.storage)
doAssert again.revision.len == 0 and again.before["old"].data == "original\n"
doAssert checkpointDiff(again).len == 2
# Unborn Git repositories are usable without creating HEAD or changing the index.
let unborn = home / "unborn"
createDir(unborn)
let init = execCmdEx("git init -q " & quoteShell(unborn))
doAssert init.exitCode == 0
writeFile(unborn / "new", "no final newline")
let first = createCheckpoint(unborn, "unborn", "first")
doAssert loadCheckpoint(first.storage).before["new"].data == "no final newline"
doAssert execCmdEx("git -C " & quoteShell(unborn) & " rev-parse --verify HEAD").exitCode != 0
# Raw blob bytes and names must survive without an added final newline.
writeFile(root / "日本語 name", "no final newline")
discard git("add .")
discard git("commit -m bytes")
let raw = createCheckpoint(root, "raw-session", "bytes")
doAssert loadCheckpoint(raw.storage).before["日本語 name"].data == "no final newline"
# Git's clean representation is not always the original worktree bytes.
writeFile(root / ".gitattributes", "crlf text\n")
writeFile(root / "crlf", "before\r\n")
discard git("add .")
discard git("commit -m endings")
let endings = createCheckpoint(root, "endings", "preserve CRLF")
doAssert loadCheckpoint(endings.storage).before["crlf"].data == "before\r\n"
# Never follow directory symlinks while capturing or restoring.
createDir(home / "outside")
writeFile(home / "outside/private", "private")
createSymlink(home / "outside", plain / "link")
var rejected = false
try: discard readCheckFile(plain, "link/private")
except IOError: rejected = true
doAssert rejected
for rel in ["../escape", "/absolute", ".git/config"]:
  rejected = false
  try: discard safePath(plain, rel)
  except ValueError: rejected = true
  doAssert rejected

echo "checkpoint capture, persistence, frozen diffs, untracked files, retention and non-Git ok"
