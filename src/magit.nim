## Pure parsing and presentation of git status --porcelain=v1 -z.
import std/[strutils, sets]
import branchdiff

type StatusEntry* = object
  index*, worktree*: char
  path*, oldPath*: string

proc parseStatus*(output: string): seq[StatusEntry] =
  let fields = output.split('\0')
  var i = 0
  while i < fields.len:
    let field = fields[i]
    inc i
    if field.len < 4 or field[2] != ' ': continue
    var entry = StatusEntry(index: field[0], worktree: field[1], path: field[3..^1])
    if entry.index in {'R', 'C'} or entry.worktree in {'R', 'C'}:
      if i >= fields.len or fields[i].len == 0: break
      entry.oldPath = fields[i]
      inc i
    result.add entry

proc untracked*(entry: StatusEntry): bool = entry.index == '?' and entry.worktree == '?'
proc staged*(entry: StatusEntry): bool = entry.index notin {' ', '?', '!'}
proc unstaged*(entry: StatusEntry): bool = entry.worktree notin {' ', '?', '!'}

proc displayPath*(path: string): string =
  ## Keep a filename on one display row; commands always use the original bytes.
  path.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")

proc statusLabel*(entry: StatusEntry, staged: bool): string =
  let status = if entry.untracked: '?' elif staged: entry.index else: entry.worktree
  $status & " " & (if entry.oldPath.len > 0: displayPath(entry.oldPath) & " -> " else: "") & displayPath(entry.path)

type
  Section* = enum secNone, secUntracked, secUnstaged, secStaged, secRecent
  FileKey* = tuple[section: Section, path: string]
  Row* = object
    text*: string
    section*: Section
    file*, heading*: bool
    entry*: StatusEntry
    kind*: DiffKind
    newLine*: int
    patch*: string             ## file headers plus this row's hunk, verbatim
  FoldState* = object
    expanded*: HashSet[FileKey]
    hidden*: set[Section]

const diffOptions* = "--no-ext-diff --no-textconv --no-color --no-relative --src-prefix=a/ --dst-prefix=b/ --unified=3 --submodule=short "

proc key*(row: Row): FileKey = (row.section, row.entry.path)

proc inSection*(entry: StatusEntry, section: Section): bool =
  case section
  of secUntracked: entry.untracked
  of secUnstaged: entry.unstaged
  of secStaged: entry.staged
  else: false

proc toggle*(state: var FoldState, row: Row) =
  if row.heading:
    if row.section in state.hidden: state.hidden.excl row.section
    else: state.hidden.incl row.section
  elif row.entry.path.len > 0:
    if not row.file or row.key in state.expanded: state.expanded.excl row.key
    else: state.expanded.incl row.key

proc toggleAll*(state: var FoldState, files: seq[FileKey]) =
  var close = false
  for file in files:
    if file in state.expanded: close = true
  for file in files:
    if close: state.expanded.excl file
    else:
      state.expanded.incl file
      state.hidden.excl file.section

proc hunkPatches*(patch: string): seq[string] =
  ## Retain Git's paths, CR bytes and no-final-newline markers for git apply.
  var header, body: string
  for line in patch.split('\n'):
    if line.startsWith("diff --git "):
      if body.len > 0: result.add header & body
      header = line & "\n"
      body = ""
    elif line.startsWith("@@ "):
      if body.len > 0: result.add header & body
      body = line & "\n"
    elif body.len > 0:
      if line.len > 0: body.add line & "\n"
    else:
      header.add line & "\n"
  if body.len > 0: result.add header & body

proc fileRows*(entry: StatusEntry, section: Section, expanded: bool,
               patch = "", note = ""): seq[Row] =
  let owner = Row(section: section, entry: entry, newLine: 1)
  var row = owner
  row.file = true
  row.kind = dkFile
  row.text = "  " & (if expanded: "▾ " else: "▸ ") & entry.statusLabel(section == secStaged)
  result.add row
  if not expanded: return
  let parsed = parseDiff(patch)
  var message = note
  if message.len == 0:
    if parsed.len == 0: message = "(empty file or no textual diff)"
    elif parsed[0].binary: message = "(binary file)"
    elif section == secUntracked and parsed[0].folded: message = "(large untracked file; diff omitted)"
    elif parsed[0].hunks.len == 0: message = "(metadata-only change)"
  if message.len > 0:
    row = owner
    row.kind = dkNote
    row.text = message
    result.add row
    return
  let patches = hunkPatches(patch)
  var index = 0
  for file in parsed:
    for hunk in file.hunks:
      row = owner
      row.kind = dkHunk
      row.text = hunk.header
      row.newLine = max(1, hunk.newStart)
      if index < patches.len: row.patch = patches[index]
      inc index
      result.add row
      for line in hunk.lines:
        row.kind = line.kind
        row.text = line.text
        row.newLine = line.newLine
        result.add row

proc restoredRow*(rows: seq[Row], selected: Row, fallback: int): int =
  result = clamp(fallback, 0, max(0, rows.high))
  for i, row in rows:
    if row.section != selected.section: continue
    if row.heading: result = i
    if selected.entry.path.len == 0:
      if row.heading and selected.heading: return i
    elif row.key == selected.key:
      if row.file:
        result = i
        if selected.file: return i
      elif row.kind == selected.kind and row.newLine == selected.newLine:
        return i
