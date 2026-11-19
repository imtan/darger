## Compiler locations and failure context, independent of editor and process state.
import std/[os, strutils, sets, algorithm]

type
  CompileSeverity* = enum csError, csWarning, csHint
  CompileLocation* = object
    path*: string
    line*, col*, row*: int  # zero based
    severity*: CompileSeverity

const buildFiles* = ["darger.nimble", "package.json", "Cargo.toml", "go.mod", "Makefile"]

proc guessCommand*(files: openArray[string]): string =
  for i, name in buildFiles:
    if name in files: return ["nimble build", "npm test", "cargo build", "go build ./...", "make"][i]
  "make"

proc number(s: string, at: var int): int =
  let start = at
  while at < s.len and s[at] in {'0'..'9'}: inc at
  if start == at: return -1
  try: parseInt(s[start..<at])
  except ValueError: -1

proc parseLocation*(text, root: string, row = 0): CompileLocation =
  var s = text.strip
  var path = ""
  var line = -1
  var col = 1
  if s.startsWith("File \""):
    let ending = s.find("\", line ", 6)
    if ending >= 0:
      path = s[6..<ending]
      var at = ending + 8
      line = number(s, at)
  else:
    for prefix in ["--> ", "::: ", "at "]:
      if s.startsWith(prefix): s = s[prefix.len..^1].strip
    # Node stack frames wrap the location in parentheses after the function name.
    if s.endsWith(")"):
      let opening = s.rfind('(')
      if opening >= 0 and ':' in s[opening..^1]: s = s[opening + 1..^2]
    for i in 0..<s.len:
      if s[i] notin {':', '('}: continue
      var at = i + 1
      let n = number(s, at)
      if at > i + 1 and n < 1: return
      if n < 1 or at >= s.len: continue
      var c = 1
      if s[i] == '(':
        if s[at] != ',': continue
        inc at
        while at < s.len and s[at] == ' ': inc at
        c = number(s, at)
        if c < 1 or at >= s.len or s[at] != ')': continue
      else:
        if s[at] != ':': continue
        inc at
        let start = at
        let possible = number(s, at)
        if at > start and (at == s.len or s[at] == ':'):
          if possible < 1: return
          c = possible
      path = s[0..<i].strip
      line = n
      col = c
      break
  if path.len == 0 or line < 1 or path[0] == '<' or "://" in path: return
  result = CompileLocation(path: normalizedPath(if path.isAbsolute: path else: root / path),
    line: line - 1, col: col - 1, row: row)
  let lower = text.toLowerAscii
  if "warning:" in lower: result.severity = csWarning
  elif "hint:" in lower or "note:" in lower: result.severity = csHint

proc locations*(lines: openArray[string], root: string): seq[CompileLocation] =
  for i, line in lines:
    let location = parseLocation(line, root, i)
    if location.path.len > 0: result.add location

proc failureRows*(lines: openArray[string], errors: openArray[CompileLocation], limit = 200): seq[int] =
  ## Prefer the newest error neighbourhoods, then fill from the output's tail.
  if limit <= 0: return
  var selected: HashSet[int]
  for i in countdown(errors.high, 0):
    if errors[i].severity != csError: continue
    for row in max(0, errors[i].row - 2)..min(lines.high, errors[i].row + 2):
      if selected.len < limit: selected.incl row
  for row in countdown(lines.high, 0):
    if selected.len >= limit: break
    selected.incl row
  for row in selected: result.add row
  result.sort()

proc sourceContext*(path, text: string, errors: openArray[CompileLocation]): string =
  let lines = text.splitLines
  var selected: HashSet[int]
  for error in errors:
    if error.path != path: continue
    for row in max(0, error.line - 20)..min(lines.high, error.line + 20): selected.incl row
  var rows: seq[int]
  for row in selected: rows.add row
  rows.sort()
  result = "\n--- Source: " & path & " ---\n"
  var previous = -1
  for row in rows:
    if previous >= 0 and row > previous + 1: result.add "...\n"
    result.add $(row + 1) & ": " & lines[row] & "\n"
    previous = row

proc failurePrompt*(command, root: string, code: int, lines: openArray[string],
                    errors: openArray[CompileLocation]): string =
  result = "このビルド／テストの失敗を直して。変更は最小限に。変更は agent-changes のレビュー（y/k）を通してください。\n" &
    "Directory: " & root & "\nCommand: " & command & "\nExit code: " & $code &
    "\n--- Build output (at most 200 lines; error context preferred) ---\n"
  for row in failureRows(lines, errors): result.add lines[row] & "\n"
