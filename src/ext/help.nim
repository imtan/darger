## The manual (F1): manual.nim's key reference in a read-only view.
import std/tables
import ../[core, buffer, lisp, manual]

const
  helpNavigation* = ["forward", "backward", "next-line", "previous-line", "bol", "eol", "bob", "eob"]
  helpMessage* = "Help  q:close  F1:toggle"

var helpBuf*: Buffer

proc beginHelp*() =
  beginOverlay("help")
  helpBuf = newBuffer(manualText)
  helpBuf.path = "*Help*"

proc finishHelp*() =
  finishOverlay()
  helpBuf = nil

proc dispatchHelp*(c: string) =
  ## Help mode only moves helpBuf; the edited buffer b is never touched.
  let full = overlayKey(c)
  if full.len == 0: return
  if full in ["q", "C-g", "enter", "C-m", "C-j", "f1", "escape"]:
    finishHelp()
    return
  if full == "C-x C-c":
    quitEditor()
    return
  if full != "C-l": recenterCycle = 0
  let name = keymap.getOrDefault(full).symName
  if name == "help":
    finishHelp()
  elif name in helpNavigation:
    let message = helpBuf.command(name)
    if message.len > 0: echoLine = message
  elif full in ["C-v", "pagedown", "M-v", "pageup"]: page(helpBuf, full)
  elif full == "C-l": recenter(helpBuf)
  else: echoLine = "q: close help"

interp.defPrimitive("help", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if mode == "help": finishHelp()
  elif mode in ["", "eval", "execute"]: beginHelp()  # M-x help / M-: (help) reach here from their prompt
  else: echoLine = "help is unavailable here"
  nilValue())

defineMode(Mode(name: "help", tag: "[Help]", buffer: proc(): Buffer = helpBuf,
  message: proc(): string = overlayMessage(helpMessage), onKey: dispatchHelp, onClose: finishHelp))

defaults.add """
(global-set-key "f1" 'help)
"""
