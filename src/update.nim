## Self-update: compares darger's own git checkout with GitHub in the background and,
## when it is behind, fast-forwards and rebuilds. One step runs at a time, each a
## child process whose output goes to a file, polled from the main loop like downloads.
import std/[os, osproc, strutils, times, tempfiles]
when not defined(windows): import std/posix

type
  Step* = enum stFetch, stCount, stHash, stMerge, stBuild
  Update* = ref object
    dir*: string           ## the checkout being updated
    buildCommand*: string
    step*: Step
    process: Process
    tmp: string            ## holds the current step's output
    startedAt*: float
    done*, cancelled*, upToDate*: bool
    ahead*, behind*: int   ## local-only commits, and commits GitHub has that we lack
    revision*: string      ## short hash of the upstream head
    log*: string           ## every step's command and output, for *darger update*
    error*: string         ## "" on success
    parked: string         ## Windows: the running exe moved aside for the build

const defaultBuildCommand* = "nimble -y build -d:release"

proc sourceDirectory*(configured: string): string =
  ## The checkout to update: darger-source-directory, else the directory holding
  ## the running executable. It must be a git checkout with darger.nimble.
  let dir = if configured.len > 0: normalizedPath(absolutePath(expandTilde(configured)))
            else: getAppDir()
  if not (dirExists(dir / ".git") or fileExists(dir / ".git")) or not fileExists(dir / "darger.nimble"):
    raise newException(ValueError, "No darger git checkout at " & dir &
      (if configured.len > 0: "" else: " (set darger-source-directory)"))
  dir

proc stepText*(u: Update): string =
  if u.cancelled: return "cancelling"
  case u.step
  of stFetch, stCount, stHash: "checking GitHub"
  of stMerge: "pulling"
  of stBuild: "building"

proc elapsedText*(u: Update): string =
  let s = max(0, int(epochTime() - u.startedAt))
  $(s div 60) & ":" & align($(s mod 60), 2, '0')

proc firstLine(text: string): string =
  for line in text.splitLines:
    let s = strutils.strip(line)
    if s.len > 0: return s

proc run(u: Update, command: string, git = false) =
  ## Starts command in the checkout with its output redirected to a file. Git never
  ## waits on a credential prompt nobody could answer.
  let output = u.tmp / "out"
  try: removeFile(output)
  except OSError: discard
  u.log.add "$ " & command & "\n"
  when defined(windows):
    let line = (if git: "set GIT_TERMINAL_PROMPT=0& " else: "") & command &
      " > " & quoteShell(output) & " 2>&1"
    # poDaemon: no console window (the editor is a GUI program).
    u.process = startProcess("cmd /d /s /c \"" & line & "\"", workingDir = u.dir,
      options = {poEvalCommand, poUsePath, poDaemon})
  else:
    let line = (if git: "export GIT_TERMINAL_PROMPT=0; " else: "") & "{ " & command & "; } > " &
      quoteShell(output) & " 2>&1"
    # setsid puts the step's children in one group so cancellation stops them too.
    let setsid = findExe("setsid")
    let shell = if setsid.len > 0: "exec " & quoteShell(setsid) & " /bin/sh -c " & quoteShell(line)
                else: line
    u.process = startProcess("/bin/sh", workingDir = u.dir, args = ["-c", shell], options = {poUsePath})

proc upstream(): string = quoteShell("@{u}")

proc exePath(u: Update): string =
  ## The running executable when the build will overwrite it, else "".
  let exe = getAppFilename()
  if parentDir(exe) == u.dir: exe else: ""

proc restoreExe(u: Update) =
  ## Windows: a failed build leaves the editor runnable from the checkout.
  if u.parked.len == 0: return
  let exe = u.parked[0..^(".old.exe".len + 1)] & ".exe"
  if not fileExists(exe):
    try: moveFile(u.parked, exe)
    except OSError: discard
  u.parked = ""

proc start(u: Update, step: Step) =
  u.step = step
  case step
  of stFetch: u.run("git fetch --quiet", git = true)
  of stCount: u.run("git rev-list --count --left-right HEAD..." & upstream(), git = true)
  of stHash: u.run("git rev-parse --short " & upstream(), git = true)
  of stMerge: u.run("git merge --ff-only --quiet " & upstream(), git = true)
  of stBuild:
    when defined(windows):
      # A running exe cannot be overwritten, but it can be renamed out of the way.
      let exe = u.exePath
      if exe.len > 0 and fileExists(exe):
        u.parked = exe[0..^5] & ".old.exe"
        moveFile(exe, u.parked)
    u.run(u.buildCommand)

proc startUpdate*(dir, buildCommand: string): Update =
  if strutils.strip(buildCommand).len == 0: raise newException(ValueError, "darger-build-command is empty")
  result = Update(dir: dir, buildCommand: buildCommand, startedAt: epochTime())
  result.tmp = createTempDir("darger-update-", "")
  try: result.start(stFetch)
  except CatchableError:
    removeDir(result.tmp)
    raise

proc finish(u: Update, error: string) =
  u.done = true
  u.error = error
  if error.len > 0: u.log.add "=> " & error & "\n"
  u.restoreExe()
  try: removeDir(u.tmp)
  except CatchableError: discard

proc stepDone(u: Update, code: int) =
  ## Reads the finished step's output and starts the next one, or ends the update.
  var output: string
  try: output = readFile(u.tmp / "out").replace("\r\n", "\n")
  except CatchableError: discard
  u.log.add output
  if output.len > 0 and not output.endsWith("\n"): u.log.add "\n"
  u.process.close()
  u.process = nil
  if u.cancelled:
    u.finish("cancelled")
    return
  if code != 0:
    let detail = firstLine(output)
    u.finish((if u.step == stBuild: "build failed: " else: "git: ") &
      (if detail.len > 0: detail else: "exit code " & $code))
    return
  try:
    case u.step
    of stFetch: u.start(stCount)
    of stCount:
      let parts = firstLine(output).split('\t')
      if parts.len != 2: raise newException(ValueError, "git: unexpected rev-list output")
      u.ahead = parseInt(parts[0])
      u.behind = parseInt(parts[1])
      if u.behind == 0:
        u.upToDate = true
        u.finish("")
      elif u.ahead > 0:
        u.finish("local commits diverge from GitHub (" & $u.ahead & " ahead, " & $u.behind & " behind)")
      else: u.start(stHash)
    of stHash:
      u.revision = firstLine(output)
      u.start(stMerge)
    of stMerge: u.start(stBuild)
    of stBuild: u.finish("")
  except CatchableError as e:
    u.finish(e.msg)

proc poll*(u: Update): bool =
  ## True once the update has ended (updated, up to date, failed or cancelled).
  if u.done: return true
  let code = u.process.peekExitCode()
  if code == -1: return false
  u.stepDone(code)
  u.done

proc cancel*(u: Update) =
  if u.done or u.cancelled: return
  u.cancelled = true
  when defined(windows):
    # Killing cmd.exe alone would leave git or the compiler running.
    try:
      let killer = startProcess("taskkill", args = ["/T", "/F", "/PID", $u.process.processID],
        options = {poUsePath, poDaemon})
      discard killer.waitForExit(5000)
      killer.close()
    except CatchableError: discard
    if u.process.waitForExit(2000) == -1: u.process.kill()
  else:
    let pid = Pid(u.process.processID)
    if posix.kill(-pid, SIGTERM) != 0: discard posix.kill(pid, SIGTERM)
    if u.process.waitForExit(2000) == -1:
      discard posix.kill(-pid, SIGKILL)
      u.process.kill()
  discard u.process.waitForExit(2000)
  u.stepDone(-1)

proc removeStaleExe*() =
  ## Windows: deletes the exe a previous update moved aside (ignored while it still runs).
  when defined(windows):
    let exe = getAppFilename()
    if exe.endsWith(".exe"):
      try: removeFile(exe[0..^5] & ".old.exe")
      except OSError: discard
