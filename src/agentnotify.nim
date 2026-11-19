## Notification arguments and a streaming terminal notification detector, without UI or processes.
import std/strutils

proc appleScriptString*(value: string): string =
  result = "\""
  for c in value:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if c >= ' ': result.add c
  result.add '"'

proc notificationScript*(title, message, sound: string): string =
  result = "display notification " & appleScriptString(message) &
    " with title " & appleScriptString(title)
  if sound.len > 0: result.add " sound name " & appleScriptString(sound)

type
  NoticeState = enum ground, escape, osc, oscEscape, controlString, controlEscape
  NoticeParser* = object
    state: NoticeState
    prefix: string

proc finishOsc(p: var NoticeParser): int =
  if p.prefix.startsWith("9;") or p.prefix.startsWith("777;notify;"): result = 1
  p.prefix = ""
  p.state = ground

proc feed*(p: var NoticeParser, data: string): int =
  ## BEL outside OSC, OSC 9 and OSC 777;notify. Keep state across PTY reads;
  ## a title's BEL terminator is not a bell. Never retain terminal message bodies.
  for c in data:
    if c in {'\x18', '\x1a'}:
      p.state = ground
      p.prefix = ""
      continue
    case p.state
    of ground:
      if c == '\a': inc result
      elif c == '\e': p.state = escape
    of escape:
      case c
      of ']':
        p.state = osc
        p.prefix = ""
      of 'P', '^', '_', 'X': p.state = controlString
      of '\e': discard
      else:
        p.state = ground
        if c == '\a': inc result
    of osc:
      if c == '\a': result += p.finishOsc()
      elif c == '\e': p.state = oscEscape
      elif p.prefix.len < 12: p.prefix.add c
    of oscEscape:
      if c == '\\': result += p.finishOsc()
      else:
        p.prefix = ""
        p.state = if c == '\e': escape else: ground
    of controlString:
      if c == '\e': p.state = controlEscape
    of controlEscape:
      p.state = if c == '\\': ground elif c == '\e': controlEscape else: controlString

proc shouldNotify*(enabled, focused, shown, terminal: bool): bool =
  enabled and not (terminal and focused and shown)
