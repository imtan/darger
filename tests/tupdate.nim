## Self-update against a local bare "GitHub" (needs git on PATH).
import std/[os, osproc, strutils, tempfiles, times]
import ../src/update

let root = createTempDir("darger-update-test-", "")
let origin = root / "origin.git"
let work = root / "work"      # where new commits are made and pushed
let clone = root / "clone"    # the "installed" checkout that updates itself

proc git(dir: string, args: varargs[string]): string =
  var cmd = @["git", "-c", "user.name=t", "-c", "user.email=t@example.com",
    "-c", "commit.gpgsign=false"] & @args
  let (output, code) = execCmdEx(cmd.join(" "), workingDir = dir)
  doAssert code == 0, cmd.join(" ") & ": " & output
  strutils.strip(output)

proc commit(message: string) =
  writeFile(work / "README.md", message & "\n")
  discard git(work, "add", "README.md")
  discard git(work, "commit", "-q", "-m", message)
  discard git(work, "push", "-q", "origin", "HEAD")

proc wait(u: Update): Update =
  let deadline = epochTime() + 60
  while not u.poll():
    doAssert epochTime() < deadline, "update did not finish"
    sleep(10)
  u

discard git(root, "init", "-q", "--bare", origin)
createDir(work)
discard git(work, "init", "-q")
writeFile(work / "darger.nimble", "version = \"0.1.0\"\n")
discard git(work, "add", "darger.nimble")
discard git(work, "commit", "-q", "-m", "first")
discard git(work, "remote", "add", "origin", origin)
discard git(work, "push", "-q", "-u", "origin", "HEAD")
discard git(root, "clone", "-q", origin, clone)

# The checkout must be a git clone holding darger.nimble.
doAssert sourceDirectory(clone) == normalizedPath(absolutePath(clone))
var failed = false
try: discard sourceDirectory(root)
except ValueError: failed = true
doAssert failed
failed = false
try: discard startUpdate(clone, "  ")
except ValueError: failed = true
doAssert failed

let build = "echo built > built.txt"
let same = wait(startUpdate(clone, build))
doAssert same.done and same.error == "", same.error
doAssert same.upToDate and same.behind == 0 and same.ahead == 0
doAssert not fileExists(clone / "built.txt"), "no build when up to date"
doAssert same.log.startsWith("$ git fetch"), same.log
doAssert same.elapsedText().startsWith("0:")

commit("second")
commit("third")
let expected = git(work, "rev-parse", "--short", "HEAD")
let updated = wait(startUpdate(clone, build))
doAssert updated.done and updated.error == "", updated.error
doAssert not updated.upToDate and updated.behind == 2, $updated.behind
doAssert updated.revision == expected, updated.revision
doAssert git(clone, "rev-parse", "--short", "HEAD") == expected
doAssert fileExists(clone / "built.txt"), "built after pulling"
doAssert "$ " & build in updated.log, updated.log
removeFile(clone / "built.txt")

# A failing build reports its first output line and leaves the checkout updated.
commit("fourth")
let broken = wait(startUpdate(clone, "echo no compiler && exit 3"))
doAssert broken.done and broken.error.startsWith("build failed: no compiler"), broken.error
doAssert broken.behind == 1
doAssert git(clone, "rev-parse", "--short", "HEAD") == git(work, "rev-parse", "--short", "HEAD")

# Local commits that GitHub lacks are never merged over.
writeFile(clone / "local.txt", "mine\n")
discard git(clone, "add", "local.txt")
discard git(clone, "commit", "-q", "-m", "local")
let ahead = wait(startUpdate(clone, build))
doAssert ahead.done and ahead.error == "" and ahead.upToDate and ahead.ahead == 1, ahead.error
commit("fifth")
let diverged = wait(startUpdate(clone, build))
doAssert diverged.done and "diverge" in diverged.error, diverged.error
doAssert diverged.ahead == 1 and diverged.behind == 1
doAssert not fileExists(clone / "built.txt")

# Cancellation stops the running step.
let slow = startUpdate(clone, build)
slow.cancel()
doAssert slow.done and slow.cancelled and slow.error == "cancelled"
doAssert slow.stepText == "cancelling"

removeStaleExe()
removeDir(root)
echo "tupdate ok"
