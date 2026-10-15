## M-x darger-update: pull new commits from GitHub and rebuild in the background
## (update.nim does the git and nimble work).
import std/[os, strutils, tables, unicode]
import ../[core, buffer, buffers, lisp, update]

var
  updater*: Update                      # the self-update in progress, nil = none

proc updateLog*(u: Update) =
  ## The steps' output goes to *darger update*, without switching to it.
  const name = "*darger update*"
  var buf = reg.byName(name)
  if buf == nil:
    buf = newBuffer()
    reg.add(buf, name)
  buf.splice(0, buf.text.runeLen, u.log)
  buf.modified = false
  buf.regionActive = false
  buf.markSet = false
  buf.cursor = (0, 0)
  buf.finish()

proc pollUpdate*(): bool =
  if updater == nil or not updater.poll(): return false
  let u = updater
  updater = nil
  updateLog(u)
  echoLine = if u.error == "cancelled": "darger update cancelled"
    elif u.error.len > 0: "darger update failed: " & u.error & "  (see *darger update*)"
    elif u.upToDate: "darger is up to date" & (if u.ahead > 0: " (" & $u.ahead & " local commits ahead)" else: "")
    else: "darger updated to " & u.revision & " (" & $u.behind & " commits): restart to use it"
  true

interp.defPrimitive("darger-update", proc(args: seq[Value]): Value =
  ## Checks GitHub for new commits; when there are some, fast-forwards and rebuilds.
  args.arity(0, 0)
  if updater != nil: raise newException(LispError, "darger update already running")
  try:
    let dir = sourceDirectory(interp.env.values["darger-source-directory"].asString)
    updater = startUpdate(dir, interp.env.values["darger-build-command"].asString)
    echoLine = ""
  except CatchableError as e: raise newException(LispError, e.msg)
  nilValue())

messageHooks.add proc(): string =
  if updater == nil or overlayOf(mode).len > 0: return ""
  "Updating darger  " & updater.stepText & " " & updater.elapsedText & "  C-g:cancel" &
    (if echoLine.len > 0: "  " & echoLine else: "")

exitHooks.add proc() =
  if updater != nil: updater.cancel()
cancelHooks.add proc() =
  if updater != nil and not updater.cancelled:
    updater.cancel()
    echoLine = "darger update cancelled"
busyHooks.add proc(): bool = updater != nil
tickHooks.add pollUpdate
defaults.add """
(setq darger-source-directory "")
"""
defaults.add "(setq darger-build-command \"" & defaultBuildCommand() & "\")"
