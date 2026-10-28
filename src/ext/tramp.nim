## SSH transport. Authentication is delegated to ssh-agent / ~/.ssh/config.
import std/[os, osproc, strutils, tables, sets, times, tempfiles, algorithm]
import ../[remote, core, buffer, filer, lisp]

var
  hosts: HashSet[string]
  listings: Table[string, tuple[checked: float, entries: seq[RemoteEntry]]]

defaults.add """
(setq tramp-ssh-options "")
"""

proc commandArgs(host, command: string): seq[string] =
  result = sshArgs(host, command)
  if "tramp-ssh-options" in interp.env.values:
    let extra = parseCmdLine(interp.env.values["tramp-ssh-options"].asString)
    result = result[0..^3] & extra & result[^2..^1]

proc runSsh(host, command: string, input = ""): string =
  hosts.incl host
  var temporary: seq[string]
  defer:
    for path in temporary: discard tryRemoveFile(path)
  try:
    for suffix in [".in", ".out", ".err"]:
      let (file, path) = createTempFile("darger-ssh-", suffix)
      file.close()
      temporary.add path
    writeFile(temporary[0], input)
    # execCmdEx reads lines and adds newlines. Redirect bytes to files instead;
    # this also avoids pipe deadlocks and broken-pipe writes on failed connections.
    let (_, code) = execCmdEx(quoteShellCommand(commandArgs(host, command)) &
      " < " & quoteShell(temporary[0]) & " > " & quoteShell(temporary[1]) &
      " 2> " & quoteShell(temporary[2]), options = {poUsePath})
    if code != 0:
      let stderr = readFile(temporary[2]).strip
      let message = if stderr.len > 0: stderr.splitLines[0] else: "ssh exited with code " & $code
      raise newException(IOError, message)
    result = readFile(temporary[1])
  except CatchableError as e:
    echoLine = e.msg.splitLines[0]
    raise

remoteExists = proc(path: string): tuple[exists, isDir: bool] =
  let r = parseRemote(path).get
  let status = runSsh(r.host, statCommand(r.path)).strip
  if status notin ["dir", "file", "none"]: raise newException(IOError, "Invalid SSH file status")
  (status != "none", status == "dir")

remoteLoad = proc(path: string): Buffer =
  let r = parseRemote(path).get
  let status = remoteExists(path)
  if status.isDir: raise newException(IOError, "Is a directory: " & path)
  bufferFromBytes((if status.exists: runSsh(r.host, catCommand(r.path)) else: ""), path)

remoteMakeDir = proc(path: string) =
  let r = parseRemote(path).get
  discard runSsh(r.host, mkdirCommand(r.path))
  listings.clear()

remoteSave = proc(buf: Buffer, path: string): bool =
  let r = parseRemote(path).get
  discard runSsh(r.host, writeCommand(r.path), buf.fileBytes)
  listings.clear()
  true

proc listing(dir: string, cached: bool): seq[RemoteEntry] =
  if cached and dir in listings and epochTime() - listings[dir].checked < 3:
    return listings[dir].entries
  let r = parseRemote(dir).get
  result = parseLsLines(runSsh(r.host, listCommand(r.path)))
  listings[dir] = (epochTime(), result)

remoteList = proc(dir: string): seq[string] =
  try:
    for e in listing(dir, true): result.add e.name & (if e.isDir: "/" else: "")
  except CatchableError as e: echoLine = e.msg

remoteDirectory = proc(path: string): seq[Entry] =
  for e in listing(path, false):
    result.add Entry(name: e.name, kind: (if e.isDir: pcDir else: pcFile),
      size: e.size, remoteTime: e.time)
  result.sort(proc(a, b: Entry): int =
    result = cmp(not a.isDir, not b.isDir)
    if result == 0: result = cmp(a.name.toLowerAscii, b.name.toLowerAscii))

let previous = modeLineHook
modeLineHook = proc(): string =
  result = if previous != nil: previous() else: ""
  let r = parseRemote(b.path)
  if r.isSome: result.add " ssh:" & r.get.host

interp.defPrimitive("tramp-cleanup", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  var failed = false
  let known = hosts
  for host in known:
    try:
      var argv = commandArgs(host, "")
      argv.setLen(argv.len - 1)
      argv = argv[0..^2] & @["-O", "exit", argv[^1]]
      let (output, code) = execCmdEx(quoteShellCommand(argv))
      if code != 0:
        failed = true
        echoLine = if output.strip.len > 0: output.strip.splitLines[0] else: "SSH cleanup failed"
    except CatchableError as e:
      failed = true
      echoLine = e.msg
  listings.clear()
  if not failed:
    hosts.clear()
    echoLine = "SSH control masters closed"
  nilValue())
