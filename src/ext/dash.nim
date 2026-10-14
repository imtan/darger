## The dashboard: recent files to open with one key, shown at start without arguments.
import std/[os, strutils, tables]
import ../[core, buffer, lisp, recent]

const
  dashMessage* = "Dashboard  Enter:open  q:scratch  F1:manual"
  dashLabels* = "123456789abc"
  dashFirst* = 4  # line of the first recent-file entry

var
  dashBuf*: Buffer
  dashFiles*: seq[string]

proc beginDash*() =
  beginOverlay("dash")
  dashFiles = loadRecent()
  if dashFiles.len > dashLabels.len: dashFiles.setLen(dashLabels.len)
  var lines = @["darger", "I'm talking about the present.", "", "Recent files"]
  let limit = max(30, (if renderer.cols > 0: renderer.cols else: 80) - 5)  # "  1  " prefix
  for i, f in dashFiles: lines.add "  " & dashLabels[i] & "  " & shortPath(f, limit)
  if dashFiles.len == 0: lines.add "  (none yet)"
  lines.add ""
  lines.add "F1 manual   C-x C-f open   q scratch"
  dashBuf = newBuffer(lines.join("\n"))
  dashBuf.path = "*dashboard*"
  dashBuf.cursor = if dashFiles.len > 0: (dashFirst, 2) else: (0, 0)

proc finishDash*() =
  finishOverlay()
  dashBuf = nil
  dashFiles = @[]

proc openEntry*(i: int) =
  if i notin 0..dashFiles.high: return
  let path = dashFiles[i]
  if not fileExists(path):
    echoLine = "No such file: " & shortPath(path)
    return
  finishDash()
  try: visit(path)
  except CatchableError as e:
    beginDash()
    echoLine = e.msg

proc dispatchDash*(c: string) =
  ## Like dispatchHelp: the dashboard only moves between entries or opens one.
  let full = overlayKey(c)
  if full.len == 0: return
  let name = keymap.getOrDefault(full).symName
  if full in ["q", "C-g", "escape"] or name == "dashboard": finishDash()
  elif full == "f1" or name == "help":
    finishDash()
    dispatch(full)
  elif full == "C-x C-c": quitEditor()
  elif full == "C-x C-f":
    finishDash()
    dispatch(full)
  elif full == "C-x d":
    finishDash()
    dispatch(full)
  elif full in ["enter", "C-m", "C-j"]: openEntry(dashBuf.cursor.line - dashFirst)
  elif name in ["next-line", "previous-line"] or full in ["C-n", "C-p", "down", "up"]:
    let delta = if name == "previous-line" or full in ["C-p", "up"]: -1 else: 1
    if dashFiles.len > 0:
      dashBuf.cursor = (clamp(dashBuf.cursor.line + delta, dashFirst, dashFirst + dashFiles.high), 2)
  elif full.len == 1 and dashLabels.find(full[0]) in 0..dashFiles.high:
    openEntry(dashLabels.find(full[0]))
  else: echoLine = full & " is undefined"

interp.defPrimitive("dashboard", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if mode == "dash": finishDash()
  elif mode in ["", "eval", "execute"]: beginDash()
  else: echoLine = "dashboard is unavailable here"
  nilValue())

defineMode(Mode(name: "dash", tag: "[Dash]", buffer: proc(): Buffer = dashBuf,
  message: proc(): string = overlayMessage(dashMessage), onKey: dispatchDash, onClose: finishDash))

startScreen = beginDash
