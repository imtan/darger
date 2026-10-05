## HTTP downloads through curl, started in the background and polled from the main
## loop: the body goes to a file so neither side blocks, like the agent's output.
import std/[os, osproc, strutils, tempfiles, times, streams, unicode]

type Fetch* = ref object
  url*, tag*: string       ## tag: what the owner wanted it for
  process: Process
  dir: string
  startedAt*: float
  done*, cancelled*: bool
  status*: int             ## HTTP status, 0 when the request never got an answer
  body*, contentType*, finalUrl*, error*: string

const defaultFetchCommand* = "curl -sSL --max-time 30 --max-redirs 10 --compressed -A darger/0.1"

proc splitCommand*(command: string): seq[string] =
  ## The configured command split on whitespace; "" when empty.
  strutils.splitWhitespace(command)

proc startFetch*(command: seq[string], url, tag: string): Fetch =
  ## Spawns the download; the result's done is set by poll.
  if command.len == 0: raise newException(ValueError, "fetch-command is empty")
  if url.len == 0 or '\0' in url or '\n' in url: raise newException(ValueError, "Expected a URL")
  result = Fetch(url: url, tag: tag, startedAt: epochTime())
  result.dir = createTempDir("darger-fetch-", "")
  let args = command[1..^1] & @["--max-filesize", "20000000", "-o", result.dir / "body",
    "--stderr", result.dir / "err", "-w", "%{http_code}\n%{content_type}\n%{url_effective}", "--", url]
  try:
    # poDaemon: no console window on Windows (the editor is a GUI program).
    result.process = startProcess(command[0], args = args, options = {poUsePath, poDaemon})
  except CatchableError:
    removeDir(result.dir)
    raise

proc finish(f: Fetch, code: int) =
  f.done = true
  var info: seq[string]
  try: info = f.process.outputStream.readAll().splitLines
  except CatchableError: discard
  f.process.close()
  f.process = nil
  if info.len > 0 and info[0].len > 0:
    try: f.status = parseInt(strutils.strip(info[0]))
    except ValueError: discard
  if info.len > 1: f.contentType = strutils.strip(info[1])
  if info.len > 2: f.finalUrl = strutils.strip(info[2])
  if f.finalUrl.len == 0: f.finalUrl = f.url
  try: f.body = readFile(f.dir / "body")
  except CatchableError: discard
  if f.cancelled: f.error = "cancelled"
  elif code != 0:
    var errors: string
    try: errors = readFile(f.dir / "err")
    except CatchableError: discard
    f.error = ""
    for line in errors.splitLines:
      let s = strutils.strip(line)
      if s.len > 0:
        f.error = s.replace("curl: ", "")
        break
    if f.error.len == 0: f.error = "exit code " & $code
    if validateUtf8(f.error) != -1: f.error = "exit code " & $code
  elif f.status >= 400: f.error = "HTTP " & $f.status
  try: removeDir(f.dir)
  except CatchableError: discard

proc poll*(f: Fetch): bool =
  ## True once the download has finished (successfully or not); reads its results then.
  if f.done: return true
  let code = f.process.peekExitCode()
  if code == -1: return false
  f.finish(code)
  true

proc cancel*(f: Fetch) =
  if f.done: return
  f.cancelled = true
  try: f.process.kill()
  except CatchableError: discard
  discard f.process.waitForExit(2000)
  f.finish(-1)

proc elapsedText*(f: Fetch): string =
  let s = max(0, int(epochTime() - f.startedAt))
  $(s div 60) & ":" & align($(s mod 60), 2, '0')

proc hostOf*(url: string): string =
  ## "example.com" for display.
  var s = url
  let scheme = s.find("://")
  if scheme >= 0: s = s[scheme + 3..^1]
  let stop = s.find({'/', '?', '#'})
  if stop >= 0: s = s[0..<stop]
  s
