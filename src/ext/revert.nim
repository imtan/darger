## Auto-revert: a buffer whose file changed on disk is read again when it has no
## edits of its own (as auto-revert-mode does), and saving over a changed file asks
## first (as Emacs' file-supersession check does), so an agent's or another
## editor's write is never lost silently.
import std/[os, times, tables, strutils]
import ../remote
import ../[core, buffer, buffers, lisp]

type Stamp = tuple[time: Time, size: int64]

var
  stamps: Table[Buffer, Stamp]  # the file as the buffer last read or wrote it
  checked: float
  offered: Table[Buffer, Stamp]  # edited buffers already told about a change on disk

proc stampOf(path: string): Stamp =
  try: (getLastModificationTime(path), getFileSize(path))
  except CatchableError: (Time(), -1'i64)

proc record(buf: Buffer) =
  if not isRemote(buf.path) and buf.path.len > 0 and fileExists(buf.path): stamps[buf] = stampOf(buf.path)

proc changedOnDisk*(buf: Buffer): bool =
  ## The file differs from what the buffer last read or wrote (a deleted file does not count).
  not isRemote(buf.path) and buf in stamps and fileExists(buf.path) and stampOf(buf.path) != stamps[buf]

proc revertBuffer*(buf: Buffer) =
  buf.revert()
  record(buf)

visitHooks.add proc() = record(b)
saveHooks.add proc() = record(b)
killHooks.add proc(buf: Buffer) =
  stamps.del buf
  offered.del buf

defaults.add """
(setq auto-revert-review nil)
"""

tickHooks.add proc(): bool =
  # Once a second: buffers without edits follow their files; edited ones wait for the save guard.
  if epochTime() - checked < 1.0: return false
  checked = epochTime()
  for slot in reg.slots:
    let buf = slot.buf
    if buf notin stamps and buf.path.len > 0:
      record(buf)  # opened before this extension saw it (the command line)
      continue
    if not changedOnDisk(buf): continue
    if buf.modified:
      # An edited buffer: the disk's changes are offered as a review, once per change
      # (auto-revert-review t opens it for the current buffer when nothing else is open).
      let stamp = stampOf(buf.path)
      if offered.getOrDefault(buf) == stamp: continue
      offered[buf] = stamp
      if buf == b and mode.len == 0 and reviewHook != nil and
          interp.env.values["auto-revert-review"].kind != vNil:
        try: reviewHook(loadBuffer(buf.path).text, "file on disk")
        except CatchableError as e: echoLine = e.msg
      else:
        echoLine = reg.displayName(buf) & " changed on disk while edited (M-x diff-buffer-with-file to review)"
      result = true
      continue
    revertBuffer(buf)
    echoLine = "Reverted " & reg.displayName(buf)
    result = true

saveGuards.add proc(): bool =
  if not changedOnDisk(b): return false
  beginMini("supersede", reg.displayName(b) & " changed on disk; save anyway? (y, n, or r to review) ")
  true

definePrompt(Prompt(kind: "supersede", onAccept: proc(value: string): bool =
  if value.toLowerAscii == "r":
    # The disk's changes reviewed hunk by hunk against the buffer's own edits.
    if reviewHook != nil: reviewHook(loadBuffer(b.path).text, "file on disk")
    return true
  yesNo(value, proc() =
    b.save()
    wrote())))

interp.defPrimitive("revert-buffer", proc(args: seq[Value]): Value =
  ## Reads the file again even over edits (one undo step brings them back).
  args.arity(0, 0)
  if b.path.len == 0: echoLine = "Buffer has no file"
  else:
    revertBuffer(b)
    echoLine = "Reverted " & reg.displayName(b)
  nilValue())
