import std/[os, strutils, sysrand, json, unicode]

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

proc expandId*(command, id: string): string =
  ## The result is run by a shell, so id must stay within the characters sessionId()
  ## produces (hex and dashes); anything else is refused rather than quoted.
  for ch in id:
    if ch notin {'0'..'9', 'a'..'f', '-'}:
      raise newException(ValueError, "Agent session id contains unexpected characters")
  command.replace("{id}", id)

proc branchFromHead*(head: string): string =
  ## "ref: refs/heads/NAME" -> NAME; a detached HEAD gives its short hash.
  let s = head.strip
  if s.startsWith("ref: refs/heads/"): s[16..^1]
  elif s.startsWith("ref: "): s[5..^1]
  elif s.len >= 7: s[0..<7]
  else: ""

proc branchOf*(root: string): string =
  ## The branch checked out at root ("" outside git), without running git.
  var gitDir = root / ".git"
  try:
    if fileExists(gitDir):  # a worktree: "gitdir: /path/to/.git/worktrees/name"
      let line = readFile(gitDir).strip
      if line.startsWith("gitdir:"):
        gitDir = line[7..^1].strip
        if not gitDir.isAbsolute: gitDir = root / gitDir
    if not fileExists(gitDir / "HEAD"): return ""
    branchFromHead(readFile(gitDir / "HEAD"))
  except CatchableError: ""

proc rootFromDir*(path: string): string =
  result = normalizedPath(absolutePath(path))
  var dir = result
  while dir.len > 0:
    if dirExists(dir / ".git") or fileExists(dir / ".git"): return dir
    let up = parentDir(dir)
    if up == dir: break
    dir = up

proc appendTurn*(text, root, message: string): Turn =
  result.text = if text.len == 0: "# Agent chat: " & root else: strutils.strip(text, leading = false)
  result.text.add "\n\n## You\n" & message & "\n\n"
  result.agentLine = result.text.count('\n')
  result.text.add "## Agent\n"
  result.replyStart = result.text.len
  result.text.add "..."

proc replaceReply*(turn: Turn, reply: string): string =
  turn.text[0..<turn.replyStart] & strutils.strip(reply.replace("\r\n", "\n"), leading = false)

proc failureLine*(errors: string, code: int): string =
  for line in errors.splitLines:
    let text = strutils.strip(line)
    if text.len > 0: return text
  "exit code " & $code

type ChatOutput* = object
  reply*, activity*: string
  resultSeen*, isError*: bool

proc renderOutput*(output: string): ChatOutput =
  let endLine = output.rfind('\n')
  if endLine < 0: return
  let complete = output[0..endLine]
  var detected, stream, hasText, quoted: bool
  for line in complete.splitLines:
    if strutils.strip(line).len == 0: continue
    if validateUtf8(line) != -1:
      raise newException(ValueError, "reply is not valid UTF-8")
    var event: JsonNode
    try: event = parseJson(line)
    except JsonParsingError: discard
    if not detected:
      detected = true
      stream = event != nil and event.kind == JObject and
        event{"type"} != nil and event{"type"}.kind == JString
      if not stream:
        if validateUtf8(complete) != -1:
          raise newException(ValueError, "reply is not valid UTF-8")
        result.reply = complete
        return
    if event == nil or event.kind != JObject: continue
    template paragraph(text: string, quote = false) =
      if result.reply.len > 0:
        result.reply.add(if quoted and quote: "\n" else: "\n\n")
      result.reply.add text
      quoted = quote
    case event{"type"}.getStr
    of "assistant":
      let parts = event{"message", "content"}
      if parts == nil or parts.kind != JArray: continue
      for part in parts:
        case part{"type"}.getStr
        of "text":
          hasText = true
          let text = part{"text"}.getStr
          if text.len > 0:
            paragraph(text)
        of "tool_use":
          var summary: string
          for key in ["description", "file_path", "path", "pattern", "command", "url", "prompt", "query"]:
            summary = strutils.strip(part{"input", key}.getStr)
            if summary.len > 0: break
          summary = summary.splitLines.join(" ")
          if summary.runeLen > 100: summary = summary.runeSubStr(0, 100) & "…"
          result.activity = part{"name"}.getStr & (if summary.len > 0: ": " & summary else: "")
          paragraph("> " & result.activity, true)
        else: discard
    of "result":
      result.resultSeen = true
      result.isError = event{"is_error"}.getBool
      let text = event{"result"}.getStr
      if result.isError:
        paragraph("(failed: " & failureLine(text, 0) & ")")
      elif not hasText and text.len > 0:
        paragraph(text)
      return
    else: discard
  if not detected: result.reply = complete
