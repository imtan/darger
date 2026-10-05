import std/[os, tempfiles, strutils, times]
import ../src/fetch

doAssert splitCommand("  curl -sSL  --max-time 30 ") == @["curl", "-sSL", "--max-time", "30"]
doAssert splitCommand("") == @[]
doAssert hostOf("https://example.com/a/b?c") == "example.com"
doAssert hostOf("example.org") == "example.org"

let dir = createTempDir("darger-fetch-test-", "")
writeFile(dir / "page.html", "<p>hello</p>")
let command = splitCommand(defaultFetchCommand)

proc wait(f: Fetch): Fetch =
  let deadline = epochTime() + 20
  while not f.poll():
    doAssert epochTime() < deadline, "fetch did not finish"
    sleep(10)
  f

var url = "file://" & dir.replace(DirSep, '/') & "/page.html"
when defined(windows): url = "file:///" & dir.replace(DirSep, '/') & "/page.html"
let ok = wait(startFetch(command, url, "web"))
doAssert ok.done and ok.error == "", ok.error
doAssert ok.body == "<p>hello</p>"
doAssert ok.tag == "web" and ok.url == url
doAssert ok.finalUrl.len > 0
doAssert ok.elapsedText().startsWith("0:")

let missing = wait(startFetch(command, url & ".missing", "x"))
doAssert missing.done and missing.error.len > 0, missing.error
doAssert missing.body == ""

var failed = false
try: discard startFetch(@[], "http://x", "")
except ValueError: failed = true
doAssert failed
failed = false
try: discard startFetch(command, "", "")
except ValueError: failed = true
doAssert failed
failed = false
try: discard startFetch(@["darger-no-such-command-xyz"], url, "")
except CatchableError: failed = true
doAssert failed

# cancelling a slow download ends it with an error
let slow = startFetch(command, "http://10.255.255.1:9/", "slow")
slow.cancel()
doAssert slow.done and slow.cancelled and slow.error == "cancelled"
doAssert slow.poll()
removeDir(dir)
echo "fetch ok"
