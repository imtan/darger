## Persistent file checkpoints; no editor state or worktree/index mutations.
import std/[os, osproc, strutils, tables, sequtils, algorithm, times, json, unicode, streams, sha1]
import project, fileio, review, branchdiff

type
  CheckFile* = object
    data*, mode*: string   # Git modes; an empty mode means absent.
  FileState* = Table[string, CheckFile]
  Checkpoint* = ref object
    root*, session*, prompt*, time*, revision*, storage*: string
    number*: int
    complete*: bool
    before*, after*: FileState
    changed*: seq[string]

proc checkpointDir*(): string = getHomeDir() / ".darger-checkpoints"

proc runGit(root, args: string): string =
  let process = startProcess("git -C " & quoteShell(root) &
    " -c user.name=darger -c user.email=darger@localhost " & args,
    options = {poUsePath, poEvalCommand, poStdErrToStdOut})
  try:
    process.inputStream.close()
    result = process.outputStream.readAll()
    if process.waitForExit() != 0:
      raise newException(IOError, "Checkpoint git: " & result.strip)
  finally: process.close()

proc safePath*(root, rel: string): string =
  if rel.len == 0 or rel.isAbsolute or '\0' in rel:
    raise newException(ValueError, "Invalid checkpoint path")
  for part in rel.replace('\\', '/').split('/'):
    if part in ["", ".", "..", ".git"]:
      raise newException(ValueError, "Invalid checkpoint path: " & rel)
  result = root / rel
  var parent = parentDir(result)
  while parent.len > root.len:
    if symlinkExists(parent): raise newException(IOError, "Symlink directory: " & parent)
    parent = parentDir(parent)

proc readCheckFile*(root, rel: string): CheckFile =
  let path = safePath(root, rel)
  if symlinkExists(path): return CheckFile(data: expandSymlink(path), mode: "120000")
  if dirExists(path): raise newException(IOError, "Directory in checkpoint: " & rel)
  if fileExists(path):
    result.data = readFile(path)
    result.mode = if fpUserExec in getFilePermissions(path): "100755" else: "100644"

proc fileState*(root: string): FileState =
  let paths = if dirExists(root / ".git") or fileExists(root / ".git"):
      runGit(root, "ls-files -co --exclude-standard -z").split('\0')
    else: projectFiles(root)
  for rel in paths:
    if rel.len == 0: continue
    if dirExists(root / rel) and not symlinkExists(root / rel): continue # submodule
    let f = readCheckFile(root, rel)
    if f.mode.len > 0: result[rel] = f

proc changedFiles*(before, after: FileState): seq[string] =
  for rel, f in before:
    if after.getOrDefault(rel) != f: result.add rel
  for rel in after.keys:
    if rel notin before: result.add rel
  result.sort()

proc refName*(cp: Checkpoint): string =
  "refs/darger/checkpoints/" & cp.session & "/" & $cp.number

proc stateJson(state: FileState): JsonNode =
  result = newJObject()
  for rel, f in state: result[rel] = %*{"data": f.data, "mode": f.mode}

proc readState(node: JsonNode): FileState =
  for rel, f in node: result[rel] = CheckFile(data: f["data"].getStr, mode: f["mode"].getStr)

proc saveCheckpoint(cp: Checkpoint) =
  var before = cp.before
  if cp.revision.len > 0:
    # Git may normalize CRLF or clean-filter contents. Keep raw-byte exceptions
    # beside untracked files so rewinding recreates the actual working tree.
    before = initTable[string, CheckFile]()
    var tracked: Table[string, tuple[mode, hash: string]]
    for entry in runGit(cp.root, "ls-tree -r -z " & quoteShell(cp.revision)).split('\0'):
      if entry.len == 0: continue
      let tab = entry.find('\t')
      let fields = entry[0..<tab].split(' ')
      tracked[entry[tab+1..^1]] = (fields[0], fields[2])
    for rel, f in cp.before:
      let blobHash = ($secureHash("blob " & $f.data.len & "\0" & f.data)).toLowerAscii
      if rel notin tracked or tracked[rel].hash != blobHash or tracked[rel].mode != f.mode:
        before[rel] = f
  atomicWrite(cp.storage, $(%*{"root": cp.root, "session": cp.session,
    "number": cp.number, "prompt": cp.prompt, "time": cp.time,
    "revision": cp.revision, "complete": cp.complete,
    "before": stateJson(before), "after": stateJson(cp.after), "changed": cp.changed}))

proc loadCheckpoint*(path: string): Checkpoint =
  let j = parseFile(path)
  result = Checkpoint(root: j["root"].getStr, session: j["session"].getStr,
    number: j["number"].getInt, prompt: j["prompt"].getStr, time: j["time"].getStr,
    revision: j["revision"].getStr, complete: j["complete"].getBool, storage: path,
    before: readState(j["before"]), after: readState(j["after"]))
  for rel in j["changed"]: result.changed.add rel.getStr
  if result.revision.len > 0:
    for entry in runGit(result.root, "ls-tree -r -z " & quoteShell(result.revision)).split('\0'):
      if entry.len == 0: continue
      let tab = entry.find('\t')
      let fields = entry[0..<tab].split(' ')
      if entry[tab+1..^1] in result.before: continue
      if fields[1] != "blob": continue  # submodules are separate worktrees
      result.before[entry[tab+1..^1]] = CheckFile(mode: fields[0],
        data: runGit(result.root, "cat-file blob " & quoteShell(fields[2])))

proc listCheckpoints*(root: string, directory = checkpointDir()): seq[Checkpoint] =
  if not dirExists(directory): return
  for path in walkFiles(directory / "*.json"):
    let j = parseFile(path)
    if j["root"].getStr == root:
      # Listing metadata does not need to read every Git blob.
      var cp = Checkpoint(root: root, session: j["session"].getStr,
        number: j["number"].getInt, prompt: j["prompt"].getStr, time: j["time"].getStr,
        revision: j["revision"].getStr, storage: path, complete: j["complete"].getBool)
      for rel in j["changed"]: cp.changed.add rel.getStr
      result.add cp
  result.sort(proc(a, b: Checkpoint): int =
    if a.session == b.session: cmp(a.number, b.number) else: cmp(a.time, b.time))

proc createCheckpoint*(root, session, prompt: string, directory = checkpointDir(), extraPaths: seq[string] = @[]): Checkpoint =
  if session.len == 0 or session.anyIt(it notin {'a'..'z', 'A'..'Z', '0'..'9', '-'}):
    raise newException(ValueError, "Invalid checkpoint session")
  createDir(directory)
  let previous = listCheckpoints(root, directory)
  var number = 1
  for cp in previous:
    if cp.session == session: number = max(number, cp.number + 1)
  result = Checkpoint(root: root, session: session, number: number, prompt: prompt.replace('\n', ' ').replace('\r', ' ').runeSubStr(0, 120),
    time: now().format("yyyy-MM-dd HH:mm:ss"), storage: directory / (session & "-" & $number & ".json"))
  result.before = fileState(root)
  for rel in extraPaths:
    let f = readCheckFile(root, rel)
    if f.mode.len > 0: result.before[rel] = f
  if dirExists(root / ".git") or fileExists(root / ".git"):
    try: result.revision = runGit(root, "stash create").strip
    except IOError:
      # stash create needs HEAD. In an unborn repository pin an empty tree and
      # store every pre-turn file alongside it; never create a branch commit.
      let head = execCmdEx("git -C " & quoteShell(root) & " rev-parse --verify HEAD", options = {poUsePath, poStdErrToStdOut})
      if head.exitCode == 0: raise
      let tree = runGit(root, "mktree").strip
      result.revision = runGit(root, "commit-tree " & tree & " -m 'darger checkpoint before first commit'").strip
    if result.revision.len == 0: result.revision = runGit(root, "rev-parse HEAD").strip
    discard runGit(root, "update-ref " & quoteShell(result.refName) & " " & quoteShell(result.revision))
  saveCheckpoint(result)
  var same: seq[Checkpoint]
  for cp in previous:
    if cp.session == session: same.add cp
  # Keep the newest fifty, including this checkpoint (also pre-rewind backups).
  for i in 0..<max(0, same.len - 49):
    if same[i].revision.len > 0: discard runGit(root, "update-ref -d " & quoteShell(same[i].refName))
    removeFile(same[i].storage)

proc finishCheckpoint*(cp: Checkpoint, detected: seq[string] = @[]) =
  if cp == nil: return
  let current = fileState(cp.root)
  cp.changed = changedFiles(cp.before, current)
  # Content comparison also catches same-size edits with unchanged timestamps.
  for rel in detected:
    if rel notin cp.changed: cp.changed.add rel
  cp.changed.sort()
  cp.after.clear()
  for rel in cp.changed: cp.after[rel] = current.getOrDefault(rel)
  cp.complete = true
  saveCheckpoint(cp)

proc checkpointDiff*(cp: Checkpoint): seq[DiffFile] =
  ## The completed turn, frozen at completion; a running turn uses current files.
  let after = if cp.complete: cp.after else: fileState(cp.root)
  let paths = if cp.complete: cp.changed else: changedFiles(cp.before, after)
  for rel in paths:
    let a = cp.before.getOrDefault(rel)
    let b = after.getOrDefault(rel)
    var f = DiffFile(path: rel, oldPath: rel, isNew: a.mode.len == 0, deleted: b.mode.len == 0)
    if '\0' in a.data or '\0' in b.data or validateUtf8(a.data) != -1 or validateUtf8(b.data) != -1:
      f.binary = true
    else:
      let review = newReview(a.data, b.data)
      for i, h in review.hunks:
        var dh = DiffHunk(header: "@@ -" & $(h.startA + 1) & "," & $h.deletedA &
          " +" & $(h.startB + 1) & "," & $h.insertedB & " @@", newStart: h.startB + 1, newCount: h.insertedB)
        let (removed, added) = review.hunkText(i)
        for line in removed.splitLines(keepEol = true):
          if line.len > 0: dh.lines.add DiffLine(text: "-" & line.strip(chars = {'\r', '\n'}), kind: dkRemoved, newLine: h.startB + 1)
        var n = h.startB + 1
        for line in added.splitLines(keepEol = true):
          if line.len > 0:
            dh.lines.add DiffLine(text: "+" & line.strip(chars = {'\r', '\n'}), kind: dkAdded, newLine: n)
            inc n
        f.added += h.insertedB
        f.removed += h.deletedA
        f.hunks.add dh
      if a.mode != b.mode:
        f.hunks.add DiffHunk(header: "mode " & a.mode & " → " & b.mode)
    result.add f
