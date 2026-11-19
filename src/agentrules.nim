## Rule-file discovery and memory append text, independent of the editor.
import std/[os, strutils, algorithm]

type RuleFile* = object
  scope*, path*: string
  lines*: int             ## -1 when the file exists but its line count is unavailable

proc ruleDirectories*(root: string): seq[string] =
  var dir = normalizedPath(absolutePath(root))
  while dir.len > 0:
    result.insert(dir, 0)
    let parent = parentDir(dir)
    if parent == dir: break
    dir = parent

proc countLines*(path: string): int =
  ## Count only: do not decode, parse or retain a rule's contents (including user rules).
  var file: File
  if not open(file, path, fmRead): return -1
  defer: file.close()
  var chunk: array[4096, char]
  var last = '\n'
  while true:
    let size = file.readBuffer(addr chunk[0], chunk.len)
    if size == 0: break
    for i in 0..<size:
      if chunk[i] == '\n': inc result
    last = chunk[size - 1]
  if last != '\n': inc result

proc collectRules*(root, home: string): seq[RuleFile] =
  var rows: seq[RuleFile]
  proc add(path, scope: string) =
    if not fileExists(path): return
    let normalized = normalizedPath(absolutePath(path))
    for row in rows:
      if row.path == normalized: return
    var count = -1
    try: count = countLines(normalized)
    except CatchableError: discard
    rows.add RuleFile(scope: scope, path: normalized, lines: count)
  add(home / ".claude/CLAUDE.md", "user")
  add(home / ".codex/AGENTS.md", "user")
  for dir in ruleDirectories(root):
    add(dir / "CLAUDE.md", "project")
    add(dir / ".claude/CLAUDE.md", "project")
    add(dir / "AGENTS.md", "project")
    var cursor: seq[string]
    if dirExists(dir / ".cursor/rules"):
      for path in walkFiles(dir / ".cursor/rules/*.mdc"): cursor.add path
    cursor.sort()
    for path in cursor: add(path, "project")
    add(dir / ".github/copilot-instructions.md", "project")
    add(dir / "CLAUDE.local.md", "local")
  rows

proc defaultMemoryPath*(root: string): string =
  if fileExists(root / "CLAUDE.md"): root / "CLAUDE.md"
  elif fileExists(root / "AGENTS.md"): root / "AGENTS.md"
  else: root / "CLAUDE.md"

proc memoryAppend*(old, text: string): string =
  let line = text.strip()
  if line.len == 0 or '\n' in line or '\r' in line:
    raise newException(ValueError, "Memory must be one non-empty line")
  (if old.len > 0 and not old.endsWith("\n"): "\n" else: "") & "- " & line & "\n"

proc rulePathLabel*(path: string): string =
  path.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")

proc ruleLabel*(row: RuleFile): string =
  ## Keep a path containing a tab or newline on one display row; navigation uses the raw path.
  row.scope.alignLeft(7) & "  " & rulePathLabel(row.path) &
    "  (" & (if row.lines < 0: "?" else: $row.lines) & " lines)"
