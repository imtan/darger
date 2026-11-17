## Unified git diff parsing and display-to-source positions, independent of the editor.
import std/[strutils, sequtils]

type
  DiffKind* = enum dkSummary, dkFile, dkHunk, dkContext, dkAdded, dkRemoved, dkNote
  DiffLine* = object
    text*: string
    kind*: DiffKind
    newLine*: int             ## 1-based; removed lines use the nearest new-side line
  DiffHunk* = object
    header*: string
    newStart*, newCount*: int
    lines*: seq[DiffLine]
  DiffFile* = object
    path*, oldPath*: string
    added*, removed*: int
    isNew*, deleted*, renamed*, binary*, folded*: bool
    hunks*: seq[DiffHunk]
  DiffRow* = object
    text*, path*: string
    kind*: DiffKind
    file*: int               ## -1 for the summary
    newLine*: int
  DiffView* = object
    rows*: seq[DiffRow]
    headers*: seq[int]

proc gitPath(s: string): string =
  ## Git's C-quoted paths encode UTF-8 as octal bytes, not Unicode code points.
  if s.len < 2 or s[0] != '"': return s
  var i = 1
  while i < s.len and s[i] != '"':
    if s[i] != '\\':
      result.add s[i]
      inc i
      continue
    inc i
    if i >= s.len: break
    case s[i]
    of '0'..'7':
      var value, n: int
      while i < s.len and s[i] in {'0'..'7'} and n < 3:
        value = value * 8 + ord(s[i]) - ord('0')
        inc i
        inc n
      result.add char(value and 255)
      continue
    of 't': result.add '\t'
    of 'n': result.add '\n'
    of 'r': result.add '\r'
    of 'a': result.add '\a'
    of 'b': result.add '\b'
    of 'f': result.add '\f'
    of 'v': result.add '\v'
    else: result.add s[i]
    inc i

proc patchPath(s: string): string =
  result = gitPath(s)
  # Unquoted ---/+++ filenames with spaces can end in a tab delimiter.
  if not s.startsWith("\""): result = result.strip(leading = false, chars = {'\t'})
  if result.startsWith("a/") or result.startsWith("b/"): result = result[2..^1]

proc headerPaths(s: string): tuple[oldPath, path: string] =
  var split = -1
  if s.startsWith("\""):
    var i = 1
    while i < s.len:
      if s[i] == '\\': i += 2
      elif s[i] == '"':
        split = i + 1
        break
      else: inc i
  else:
    # In a metadata-only change the two names are equal, even if they contain
    # spaces and the literal " b/". Renames have their own unambiguous headers.
    var i = s.find(" b/")
    while i >= 0:
      split = i
      if s[2..<i] == s[i+3..^1]: break
      i = s.find(" b/", i + 1)
    if split < 0: split = s.find(" \"b/")
  if split >= 0:
    result = (patchPath(s[0..<split]), patchPath(s[split+1..^1]))

proc parseDiff*(patch: string, foldLines = 3000, foldBytes = 512 * 1024): seq[DiffFile] =
  var file = DiffFile()
  var active = false
  var hunk = -1
  var nextLine, bodyLines, bodyBytes: int
  template finish() =
    if active:
      file.folded = bodyLines > foldLines or bodyBytes > foldBytes
      result.add file
  for line in patch.splitLines:
    if line.startsWith("diff --git "):
      finish()
      let paths = headerPaths(line[11..^1])
      file = DiffFile(path: paths.path, oldPath: paths.oldPath)
      active = true
      hunk = -1
      bodyLines = 0
      bodyBytes = 0
    elif active:
      if line.startsWith("@@ "):
        let parts = line.splitWhitespace
        if parts.len < 4 or not parts[2].startsWith("+"): continue
        let range = parts[2][1..^1].split(',')
        try:
          let start = parseInt(range[0])
          let count = if range.len > 1: parseInt(range[1]) else: 1
          file.hunks.add DiffHunk(header: line, newStart: start, newCount: count)
          hunk = file.hunks.high
          nextLine = start
          inc bodyLines
          bodyBytes += line.len
        except ValueError: discard
      elif hunk >= 0:
        if line.len == 0: continue  # splitLines' final empty row is not context
        var kind: DiffKind
        case line[0]
        of '+': kind = dkAdded; inc file.added
        of '-': kind = dkRemoved; inc file.removed
        of ' ': kind = dkContext
        of '\\': kind = dkNote
        else: continue
        let h = file.hunks[hunk]
        let nearest = clamp(nextLine, max(1, h.newStart), max(1, h.newStart + max(1, h.newCount) - 1))
        file.hunks[hunk].lines.add DiffLine(text: line, kind: kind, newLine: nearest)
        if kind in {dkAdded, dkContext}: inc nextLine
        inc bodyLines
        bodyBytes += line.len
      elif line.startsWith("new file mode "): file.isNew = true
      elif line.startsWith("deleted file mode "): file.deleted = true
      elif line.startsWith("rename from "):
        file.oldPath = gitPath(line[12..^1]); file.renamed = true
      elif line.startsWith("rename to "): file.path = gitPath(line[10..^1])
      elif line.startsWith("--- "):
        let path = patchPath(line[4..^1])
        if path != "/dev/null": file.oldPath = path
        else: file.isNew = true
      elif line.startsWith("+++ "):
        let path = patchPath(line[4..^1])
        if path != "/dev/null": file.path = path
        else: file.deleted = true
      elif line.startsWith("Binary files ") or line == "GIT binary patch": file.binary = true
  finish()

proc shownPath(path: string): string =
  path.replace("\\", "\\\\").replace("\t", "\\t").replace("\r", "\\r").replace("\n", "\\n")

proc diffView*(files: seq[DiffFile], branch, base: string): DiffView =
  var added, removed: int
  for f in files:
    added += f.added
    removed += f.removed
  result.rows.add DiffRow(text: branch & " ← " & base & "   " & $files.len &
    " files  +" & $added & " −" & $removed, kind: dkSummary, file: -1)
  if files.len == 0:
    result.rows.add DiffRow(text: "nothing changed against " & base, kind: dkNote, file: -1)
  for i, f in files:
    var label = (if f.folded: "▸ " else: "▾ ") & shownPath(f.path) & "  +" & $f.added & " −" & $f.removed
    if f.renamed: label.add "  (renamed from " & shownPath(f.oldPath) & ")"
    if f.isNew: label.add "  (new file)"
    if f.deleted: label.add "  (deleted)"
    if f.binary: label.add "  (binary)"
    result.headers.add result.rows.len
    result.rows.add DiffRow(text: label, kind: dkFile, file: i, path: f.path, newLine: 1)
    if f.folded: continue
    for h in f.hunks:
      result.rows.add DiffRow(text: h.header, kind: dkHunk, file: i, path: f.path, newLine: max(1, h.newStart))
      for l in h.lines:
        result.rows.add DiffRow(text: l.text, kind: l.kind, file: i, path: f.path, newLine: l.newLine)

proc text*(view: DiffView): string = view.rows.mapIt(it.text).join("\n")

proc nextHeader*(view: DiffView, line, direction: int): int =
  result = line
  if direction > 0:
    for h in view.headers:
      if h > line: return h
  else:
    for i in countdown(view.headers.high, 0):
      if view.headers[i] < line: return view.headers[i]
