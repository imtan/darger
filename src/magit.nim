## Pure parsing and presentation of git status --porcelain=v1 -z.
import std/strutils

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
