## Which files under a project changed between two moments (an agent's chat turn):
## modification times and sizes of the project's files before, compared with after.
import std/[os, times, tables, algorithm]
import project

type FileStamp* = tuple[time: Time, size: int64]
type Snapshot* = Table[string, FileStamp]  ## relative path -> stamp

proc stampOf(path: string): FileStamp =
  try: (getLastModificationTime(path), getFileSize(path))
  except CatchableError: (Time(), -1'i64)

proc snapshot*(root: string): Snapshot =
  ## The project's files (git's list, else a walk) with their stamps.
  for rel in projectFiles(root):
    result[rel] = stampOf(root / rel)

proc changedSince*(before: Snapshot, root: string): seq[string] =
  ## Files added, modified or deleted since `before`, sorted, relative to root.
  let now = snapshot(root)
  for rel, stamp in now:
    if rel notin before or before[rel] != stamp: result.add rel
  for rel in before.keys:
    if rel notin now: result.add rel
  result.sort()
