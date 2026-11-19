## Per-turn checkpoints and human-reviewed, file-only rewind.
import std/[os, strutils, tables, unicode]
import ../[core, buffer, buffers, lisp, checkpoints, fileio, remote]
import agent, branchdiff

var
  checkpointBuf: Buffer
  checkpointRoot: string
  rows: seq[Checkpoint]
  rewindActive = false
  rewindDraft: Buffer
  rewindCancelled: bool
  rewindTaken: int

proc rebuildCheckpoints() =
  rows = listCheckpoints(checkpointRoot)
  var text = "Agent checkpoints — " & checkpointRoot & "\n" &
    "Enter: turn diff  r: review rewind  q: close (files only; conversation stays)\n\n"
  for cp in rows:
    text.add $cp.number & " [" & cp.session.runeSubStr(0, 8) & "]  " & cp.time & "  " & $cp.changed.len & " files" &
      (if cp.complete: "  " else: " (in progress/interrupted)  ") &
      cp.prompt.replace('\n', ' ').replace('\r', ' ').runeSubStr(0, 72) & "\n"
  if rows.len == 0: text.add "No checkpoints yet.\n"
  let line = checkpointBuf.cursor.line
  checkpointBuf.splice(0, checkpointBuf.text.runeLen, text)
  checkpointBuf.modified = false
  checkpointBuf.cursor = (clamp(line, 0, checkpointBuf.lines.high), 0)

proc openCheckpoints*() =
  if b != checkpointBuf or checkpointBuf == nil: checkpointRoot = currentChatRoot()
  if isRemote(checkpointRoot): raise newException(ValueError, "Checkpoints require a local project")
  if checkpointBuf == nil or checkpointBuf notin reg:
    checkpointBuf = newBuffer()
    reg.add(checkpointBuf, "*agent-checkpoints*")
    setReadOnly(checkpointBuf, true)
    for key in ["enter", "C-m", "C-j", "r", "q"]:
      setLocalKey(checkpointBuf, key,
        interp.evalString("(lambda () (agent-checkpoints-key \"" & key & "\"))", "<checkpoints>"))
  rebuildCheckpoints()
  switchTo(checkpointBuf)

reviewFinishedHooks.add proc(target: Buffer, cancelled: bool, taken: int) =
  if target == rewindDraft and rewindDraft != nil:
    rewindCancelled = cancelled
    rewindTaken = taken
    if cancelled: rewindActive = false

proc reviewCheckpoint*(cp: Checkpoint) =
  if agentProcess != nil: raise newException(ValueError, "Wait for the agent turn to finish")
  if reviewOpen() or rewindActive: raise newException(ValueError, "Finish the current review first")
  if rewindDraft != nil:
    if rewindDraft in reg: killBuffer(rewindDraft)
    rewindDraft = nil
  var current = fileState(cp.root)
  for rel in cp.before.keys:
    let f = readCheckFile(cp.root, rel)
    if f.mode.len > 0: current[rel] = f
  let paths = changedFiles(cp.before, current)
  if paths.len == 0:
    echoLine = "Checkpoint: no file changes"
    return
  # Save the redo point before even opening a review, including formerly tracked
  # paths which are now ignored. Neither capture nor review touches the index.
  let backup = createCheckpoint(cp.root, cp.session, "Before rewind to " & $cp.number,
    parentDir(cp.storage), paths)
  let origin = b
  var next = 0
  var skipped: seq[string]
  rewindActive = true
  proc advance() =
    while next < paths.len:
      let rel = paths[next]
      inc next
      let path = safePath(cp.root, rel)
      let old = readCheckFile(cp.root, rel)
      let proposed = cp.before.getOrDefault(rel)
      let opened = reg.byPath(path)
      if old == proposed: continue
      if (opened != nil and (opened.modified or opened.isReadOnly)) or
          old.mode == "120000" or proposed.mode == "120000" or
          '\0' in old.data or '\0' in proposed.data or
          validateUtf8(old.data) != -1 or validateUtf8(proposed.data) != -1:
        skipped.add rel
        continue
      let before = bufferFromBytes(old.data, path)
      let after = bufferFromBytes(proposed.data, path)
      # Empty-file existence, mode and encoding changes still need an explicit y.
      let metadataOnly = before.text == after.text
      let oldText = if metadataOnly: "Current: " & (if old.mode.len == 0: "absent" else: old.mode) & " (" & $old.data.len & " bytes)\n" else: before.text
      let newText = if metadataOnly: "Checkpoint: " & (if proposed.mode.len == 0: "absent" else: proposed.mode) & " (" & $proposed.data.len & " bytes)\n" else: after.text
      let draft = newBuffer(oldText)
      reg.add(draft, "*checkpoint: " & rel & "*")
      rewindDraft = draft
      rewindCancelled = false
      rewindTaken = 0
      switchTo(draft)
      afterReview = proc() =
        try:
          let cancelled = rewindCancelled
          let accepted = (rewindTaken > 0 or draft.text != oldText) and not cancelled and
            (not metadataOnly or draft.text == newText)
          let text = draft.text
          rewindDraft = nil
          if draft in reg: killBuffer(draft)
          if origin in reg: switchTo(origin)
          if accepted:
            let nowOpen = reg.byPath(path)
            if readCheckFile(cp.root, rel) != old or
                (opened != nil and opened notin reg) or
                (nowOpen != nil and (nowOpen.modified or nowOpen.isReadOnly or nowOpen.text != before.text)):
              skipped.add rel & " (changed during review)"
            else:
              let whole = text == newText
              before.splice(0, before.text.runeLen, if metadataOnly: after.text else: text)
              let bytes = if whole: proposed.data else: before.fileBytes
              if proposed.mode.len == 0 and whole:
                if fileExists(path): removeFile(path)
              else:
                createDir(parentDir(path))
                atomicWrite(path, bytes)
                if whole and proposed.mode.len > 0:
                  var permissions = getFilePermissions(path)
                  if proposed.mode == "100755": permissions.incl fpUserExec
                  else:
                    permissions.excl fpUserExec
                    permissions.excl fpGroupExec
                    permissions.excl fpOthersExec
                  setFilePermissions(path, permissions)
              if nowOpen != nil:
                let fresh = bufferFromBytes(bytes, path)
                nowOpen.snapshot()
                nowOpen.splice(0, nowOpen.text.runeLen, fresh.text)
                nowOpen.bom = fresh.bom
                nowOpen.crlf = fresh.crlf
                discard nowOpen.acknowledgeSave(fresh)
                nowOpen.finish()
          if cancelled: next = paths.len
          advance()
        except CatchableError:
          rewindActive = false
          raise
      beginReview(newText, "Checkpoint " & $cp.number & " → " & rel)
      # Keep the existing review keys. w applies to the disposable draft; count
      # acceptance across w as well as q through the draft's resulting content.
      return
    rewindActive = false
    finishCheckpoint(backup)
    if checkpointBuf != nil and checkpointBuf in reg: rebuildCheckpoints()
    echoLine = "Checkpoint rewind finished; redo point " & $backup.number &
      (if skipped.len > 0: "; skipped: " & skipped.join(", ") else: "")
  try: advance()
  except CatchableError:
    rewindActive = false
    raise

proc checkpointsKey(key: string) =
  if b != checkpointBuf or checkpointBuf == nil: return
  if key == "q":
    discard interp.evalString("(previous-buffer)", "<checkpoints>")
    return
  let row = b.cursor.line - 3
  if row notin 0..<rows.len: return
  let cp = loadCheckpoint(rows[row].storage)
  case key
  of "enter", "C-m", "C-j":
    openFileDiff(cp.root, "Turn " & $cp.number, "before turn", checkpointDiff(cp))
  of "r": reviewCheckpoint(cp)
  else: discard

interp.defPrimitive("agent-checkpoints-key", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  checkpointsKey(args[0].asString)
  nilValue())
interp.defPrimitive("agent-checkpoints", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  openCheckpoints()
  nilValue())
killHooks.add proc(buf: Buffer) =
  if buf == checkpointBuf: checkpointBuf = nil
