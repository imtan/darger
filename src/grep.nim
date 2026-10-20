## Searching text across files for consult-ripgrep: the command to run (ripgrep when
## installed, else grep) and the parsing of its `path:line:col:text` output.
import std/[os, strutils, osproc, sequtils]

type Hit* = object
  path*: string
  line*, col*: int   ## 0-based
  text*: string

proc grepCommand*(dir, query: string): seq[string] =
  ## rg with vimgrep output and smart case, or grep -rn (case-insensitive) without it.
  if findExe("rg").len > 0:
    @["rg", "--vimgrep", "--no-heading", "--smart-case", "--max-count", "200", "--", query, dir]
  else: @["grep", "-rnIi", "--exclude-dir=.git", "--", query, dir]

proc parseHit*(line: string, vimgrep: bool): Hit =
  ## `path:line:col:text` (rg --vimgrep) or `path:line:text` (grep); line.len == 0 when it is neither.
  var rest = line
  var path = ""
  # a Windows drive letter would confuse the first colon; paths here are POSIX
  let p1 = rest.find(':')
  if p1 <= 0: return
  path = rest[0..<p1]
  rest = rest[p1+1..^1]
  let p2 = rest.find(':')
  if p2 <= 0: return
  var lineNo = 0
  try: lineNo = parseInt(rest[0..<p2])
  except ValueError: return
  rest = rest[p2+1..^1]
  var col = 0
  if vimgrep:
    let p3 = rest.find(':')
    if p3 <= 0: return
    try: col = parseInt(rest[0..<p3])
    except ValueError: return
    rest = rest[p3+1..^1]
  Hit(path: path, line: max(0, lineNo - 1), col: max(0, col - 1), text: rest)

proc parseHits*(output: string, vimgrep: bool, limit = 2000): seq[Hit] =
  for l in output.splitLines:
    if l.len == 0: continue
    let h = parseHit(l, vimgrep)
    if h.path.len > 0: result.add h
    if result.len >= limit: break

proc hitRow*(h: Hit, base: string, width = 200): string =
  ## `relative/path:line: text`, the text cut for the list.
  let rel = if base.len > 0 and h.path.startsWith(base): h.path[base.len..^1].strip(chars = {'/'}) else: h.path
  var text = h.text.strip
  if text.len > width: text = text[0..<width]
  rel & ":" & $(h.line + 1) & ": " & text

proc resolvePlace(h: Hit, root: string): Hit =
  ## A hit with its path made absolute under root; path "" when no such file.
  result = h
  var p = h.path.strip(chars = {'`', '\'', '"', ' '})
  if p.startsWith("~/"): p = getHomeDir() / p[2..^1]
  if not p.isAbsolute: p = root / p
  result.path = if fileExists(p): normalizedPath(p) else: ""

proc parsePlaces*(output, root: string): seq[Hit] =
  ## Places an agent names, one per line: `path:line: note`, `path:line` or
  ## `path:line:col: note`, with Markdown bullets or backticks around them tolerated;
  ## lines that are not a place or name no existing file are skipped.
  for raw in output.splitLines:
    var l = raw.strip
    while l.len > 0 and l[0] in {'-', '*', '>', ' '}: l = l[1..^1].strip
    l = l.replace("`", "").strip
    if l.len == 0: continue
    var h = parseHit(l & (if l.count(':') == 1: ":" else: ""), false)
    if h.path.len == 0: continue
    # `path:line:col: note` when the text starts with a number and a colon
    let t = h.text
    let c = t.find(':')
    if c > 0 and t[0..<c].strip.allCharsInSet({'0'..'9'}) and t[0..<c].strip.len > 0:
      h.col = max(0, parseInt(t[0..<c].strip) - 1)
      h.text = t[c+1..^1]
    h.text = h.text.strip
    h = resolvePlace(h, root)
    if h.path.len > 0: result.add h

proc findReferences*(text, root: string): seq[Hit] =
  ## `path:line` references anywhere in a text (an agent's reply): existing files only,
  ## each place once, with the rest of its line as the note.
  for raw in text.splitLines:
    var i = 0
    while i < raw.len:
      if raw[i] in {'/', '.', '~', '_', '-'} or raw[i].isAlphaNumeric:
        var j = i
        while j < raw.len and (raw[j].isAlphaNumeric or raw[j] in {'/', '.', '~', '_', '-'}): inc j
        if j < raw.len and raw[j] == ':' and j + 1 < raw.len and raw[j+1] in {'0'..'9'}:
          var k = j + 1
          while k < raw.len and raw[k] in {'0'..'9'}: inc k
          let h = resolvePlace(Hit(path: raw[i..<j], line: max(0, parseInt(raw[j+1..<k]) - 1), text: raw.strip), root)
          if h.path.len > 0 and not result.anyIt(it.path == h.path and it.line == h.line): result.add h
          i = k
          continue
        i = j
      else: inc i

proc runGrep*(dir, query: string): tuple[hits: seq[Hit], error: string] =
  ## Runs the search in dir; rg exits 1 for no match, which is not an error.
  let cmd = grepCommand(dir, query)
  try:
    var shell = quoteShell(cmd[0])
    for a in cmd[1..^1]: shell.add " " & quoteShell(a)
    let (output, code) = execCmdEx(shell, options = {poUsePath})
    if code > 1: return (@[], output.strip.splitLines[0])
    (parseHits(output, cmd[0] == "rg"), "")
  except OSError as e: (@[], e.msg)
