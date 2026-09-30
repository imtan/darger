import std/[os, strutils, sysrand]

type Turn* = object
  text*: string
  replyStart*, agentLine*: int

proc sessionId*(): string =
  var bytes: array[16, byte]
  if not urandom(bytes): raise newException(IOError, "Cannot generate agent session id")
  bytes[6] = (bytes[6] and 0x0f) or 0x40
  bytes[8] = (bytes[8] and 0x3f) or 0x80
  for i, b in bytes:
    if i in [4, 6, 8, 10]: result.add '-'
    result.add toHex(b, 2).toLowerAscii

proc expandId*(command, id: string): string = command.replace("{id}", id)

proc rootFromDir*(path: string): string =
  result = normalizedPath(absolutePath(path))
  var dir = result
  while dir.len > 0:
    if dirExists(dir / ".git") or fileExists(dir / ".git"): return dir
    let up = parentDir(dir)
    if up == dir: break
    dir = up

proc appendTurn*(text, root, message: string): Turn =
  result.text = if text.len == 0: "# Agent chat: " & root else: text.strip(leading = false)
  result.text.add "\n\n## You\n" & message & "\n\n"
  result.agentLine = result.text.count('\n')
  result.text.add "## Agent\n"
  result.replyStart = result.text.len
  result.text.add "..."

proc replaceReply*(turn: Turn, reply: string): string =
  turn.text[0..<turn.replyStart] & reply.replace("\r\n", "\n").strip(leading = false)

proc failureLine*(errors: string, code: int): string =
  for line in errors.splitLines:
    let text = line.strip
    if text.len > 0: return text
  "exit code " & $code
