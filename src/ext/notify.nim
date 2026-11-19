## Shared completion / attention notices for agents and terminal programs.
import std/[osproc, tables, unicode, times]
when defined(linux): import std/os
from windy import focused
import ../[core, buffer, buffers, lisp, agentnotify]

var
  noticeBuffer: Buffer
  noticeText*: string
  noticeProcesses: seq[Process]
  wasSeen = false
  modeLineInstalled = false
  terminalNoticeAt: Table[Buffer, float]  # BEL / OSC bursts: one notice per buffer per 10 s

proc clearAgentNotice*() =
  if noticeText.len > 0:
    noticeText = ""
    noticeBuffer = nil
    dirty = true

proc foreground(): bool = window != nil and window.focused

proc showing(buf: Buffer): bool =
  if b == buf: return true
  for p in layout.leaves:
    if p != pane and p.buf == buf: return true

proc enabled(): bool = interp.env.values.getOrDefault("agent-notify", symbol("t")).kind != vNil

proc installModeLine() =
  # Other extensions assign modeLineHook at import time. Chain only after startup,
  # when the first notice arrives, so LSP / terminal / branch hints stay intact.
  if modeLineInstalled: return
  modeLineInstalled = true
  let previous = modeLineHook
  modeLineHook = proc(): string =
    result = if previous != nil: previous() else: ""
    if enabled() and noticeText.len > 0: result.add "  " & noticeText

proc notifyAgent*(buf: Buffer, failed = false, terminal = false) =
  let focused = foreground()
  let seen = focused and showing(buf)
  if not shouldNotify(enabled(), focused, showing(buf), terminal): return
  if terminal:
    let now = epochTime()
    if now - terminalNoticeAt.getOrDefault(buf, -1e9) < 10.0: return
    terminalNoticeAt[buf] = now
  installModeLine()
  noticeBuffer = buf
  noticeText = if failed: "agent ✗ failed" else: "agent ✓ done"
  wasSeen = seen
  dirty = true
  if focused: return
  when not defined(headless):
    let title = "Darger — " & reg.displayName(buf)
    let message = if terminal: "Terminal needs attention" else: noticeText
    try:
      when defined(macosx):
        let value = interp.env.values.getOrDefault("agent-notify-sound", nilValue())
        let sound = if value.kind == vString: value.asString else: ""
        noticeProcesses.add startProcess("/usr/bin/osascript",
          args = @["-e", notificationScript(title, message, sound)], options = {})
      elif defined(linux):
        let command = findExe("notify-send")
        if command.len > 0:
          noticeProcesses.add startProcess(command, args = @["--", title, message], options = {})
    except OSError: discard  # notifications must never interrupt a review or terminal

proc pollAgentNotice*(): bool =
  for i in countdown(noticeProcesses.high, 0):
    if noticeProcesses[i].peekExitCode() != -1:
      noticeProcesses[i].close()
      noticeProcesses.delete(i)
  if noticeText.len == 0: return false
  let seen = foreground() and showing(noticeBuffer)
  if not enabled() or noticeBuffer notin reg or (seen and not wasSeen):
    clearAgentNotice()
    return true
  wasSeen = seen

tickHooks.add pollAgentNotice

keyFilters.insert(proc(c: string): bool =
  clearAgentNotice()
  false, 0)
runeFilters.insert(proc(r: Rune): bool =
  clearAgentNotice()
  false, 0)
killHooks.add proc(buf: Buffer) =
  if buf == noticeBuffer: clearAgentNotice()
exitHooks.add proc() =
  for process in noticeProcesses:
    if process.peekExitCode() == -1: process.terminate()
    process.close()
  noticeProcesses = @[]
defaults.add """
(setq agent-notify t)
(setq agent-notify-sound nil)
"""
