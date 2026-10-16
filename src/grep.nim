## Searching text across files for consult-ripgrep: the command to run (ripgrep when
## installed, else grep) and the parsing of its `path:line:col:text` output.
import std/[os, strutils, osproc]

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
