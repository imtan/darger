## Auto-revert: a buffer whose file changed on disk is read again when it has no
## edits of its own (as auto-revert-mode does), and saving over a changed file asks
## first (as Emacs' file-supersession check does), so an agent's or another
## editor's write is never lost silently.
import std/[os, times, tables]
import ../[core, buffer, buffers, lisp]

type Stamp = tuple[time: Time, size: int64]

var
  stamps: Table[Buffer, Stamp]  # the file as the buffer last read or wrote it
  checked: float

proc stampOf(path: string): Stamp =
  try: (getLastModificationTime(path), getFileSize(path))
  except CatchableError: (Time(), -1'i64)

proc record(buf: Buffer) =
  if buf.path.len > 0 and fileExists(buf.path): stamps[buf] = stampOf(buf.path)

proc changedOnDisk*(buf: Buffer): bool =
  ## The file differs from what the buffer last read or wrote (a deleted file does not count).
  buf in stamps and fileExists(buf.path) and stampOf(buf.path) != stamps[buf]

proc revertBuffer*(buf: Buffer) =
  buf.revert()
  record(buf)

visitHooks.add proc() = record(b)
saveHooks.add proc() = record(b)
killHooks.add proc(buf: Buffer) = stamps.del buf

tickHooks.add proc(): bool =
  # Once a second: buffers without edits follow their files; edited ones wait for the save guard.
  if epochTime() - checked < 1.0: return false
  checked = epochTime()
  for slot in reg.slots:
    let buf = slot.buf
    if buf notin stamps and buf.path.len > 0:
      record(buf)  # opened before this extension saw it (the command line)
      continue
    if buf.modified or not changedOnDisk(buf): continue
    revertBuffer(buf)
    echoLine = "Reverted " & reg.displayName(buf)
    result = true

saveGuards.add proc(): bool =
  if not changedOnDisk(b): return false
  beginMini("supersede", reg.displayName(b) & " changed on disk; save anyway? (y or n) ")
  true

definePrompt(Prompt(kind: "supersede", onAccept: proc(value: string): bool =
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
