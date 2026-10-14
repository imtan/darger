## The buffer list (C-x C-b): switch to or kill buffers from a view.
import std/[strutils, tables]
import ../[core, buffer, buffers, lisp]

const
  blistMessage* = "Buffers  Enter:switch  k:kill  q:close"

var
  blistBuf*: Buffer
  blistBufs*: seq[Buffer]

proc buildBlist*(row = 0) =
  blistBufs = reg.buffers
  let names = reg.names
  var width = 4
  for n in names: width = max(width, cells(n))
  var lines = @[" CRM " & "Name" & spaces(width - 4) & "  Path"]
  for i, buf in blistBufs:
    lines.add " " & (if buf == b: "." else: " ") & " " & (if buf.modified: "*" else: " ") & " " &
      names[i] & spaces(width - cells(names[i])) & "  " & (if buf.path.len > 0: shortPath(buf.path) else: "")
  blistBuf = newBuffer(lines.join("\n"))
  blistBuf.path = "*Buffer List*"
  blistBuf.cursor = (clamp(row, 1, max(1, blistBufs.len)), 0)

proc beginBlist*() =
  let row = if reg.other != nil: 2 else: 1  # on the previous buffer, like C-x b's default
  beginOverlay("blist")
  pendingKill = nil
  buildBlist(row)

proc finishBlist*() =
  finishOverlay()
  blistBuf = nil
  blistBufs = @[]
  pendingKill = nil

proc blistKill*(buf: Buffer) =
  let row = blistBuf.cursor.line
  killBuffer(buf)
  buildBlist(row)
  echoLine = "Killed buffer"

proc dispatchBlist*(c: string) =
  ## Like dispatchDash: the list moves between buffers, switches to one or kills one.
  if pendingKill != nil:
    let buf = pendingKill
    if c notin ["y", "n", "C-g"]:
      echoLine = "Please answer y or n"
      return
    pendingKill = nil
    if c == "y": blistKill(buf)
    return
  let full = overlayKey(c)
  if full.len == 0: return
  let name = keymap.getOrDefault(full).symName
  let row = blistBuf.cursor.line
  let buf = if row - 1 in 0..blistBufs.high: blistBufs[row - 1] else: nil
  if full in ["q", "C-g", "escape"] or name == "list-buffers": finishBlist()
  elif full == "f1" or name == "help":
    finishBlist()
    dispatch(full)
  elif full == "C-x C-c": quitEditor()
  elif full in ["enter", "C-m", "C-j"] and buf != nil:
    finishBlist()
    switchTo(buf)
  elif full == "k" and buf != nil:
    if buf.modified and not modifiedIgnored(buf): pendingKill = buf
    else: blistKill(buf)
  elif name in ["next-line", "previous-line"] or full in ["C-n", "C-p", "down", "up", "n", "p"]:
    let delta = if name == "previous-line" or full in ["C-p", "up", "p"]: -1 else: 1
    blistBuf.cursor = (clamp(row + delta, 1, max(1, blistBufs.len)), 0)
  else: echoLine = full & " is undefined"

interp.defPrimitive("list-buffers", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if mode == "blist": finishBlist()
  elif mode in ["", "eval", "execute"]: beginBlist()
  else: echoLine = "list-buffers is unavailable here"
  nilValue())

defineMode(Mode(name: "blist", tag: "[Buffers]", buffer: proc(): Buffer = blistBuf,
  message: proc(): string =
    (if pendingKill != nil: killQuestion(pendingKill) else: overlayMessage(blistMessage)),
  onKey: dispatchBlist, onClose: finishBlist))

defaults.add """
(global-set-key "C-x C-b" 'list-buffers)
"""
