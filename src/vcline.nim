## Cached branch lookup, independent of the editor UI.
import std/[os, strutils, tables, times]
import chat

type
  BranchEntry = object
    checked: float
    head: string
    modified: Time
    branch: string
  BranchCache* = object
    roots: Table[string, BranchEntry]
    directories: Table[string, tuple[checked: float, root: string]]

proc headPath(root: string): string =
  var dir = root / ".git"
  if fileExists(dir):
    let line = readFile(dir).strip
    if not line.startsWith("gitdir:"): return ""
    dir = line[7..^1].strip
    if not dir.isAbsolute: dir = root / dir
  dir / "HEAD"

proc branchFor*(cache: var BranchCache, path: string, now: float): string =
  ## Cache root discovery too, including files outside repositories.
  if path.len == 0: return ""
  let dir = parentDir(path)
  if dir notin cache.directories or now - cache.directories[dir].checked >= 1:
    cache.directories[dir] = (now, rootFromDir(dir))
  let root = cache.directories[dir].root
  if root in cache.roots and now - cache.roots[root].checked < 1:
    return cache.roots[root].branch
  var entry = cache.roots.getOrDefault(root)
  entry.checked = now
  try:
    let head = headPath(root)
    let modified = getLastModificationTime(head)
    if head != entry.head or modified != entry.modified:
      entry.branch = branchOf(root)
      entry.head = head
      entry.modified = modified
  except CatchableError:
    entry.head = ""
    entry.branch = ""
  cache.roots[root] = entry
  entry.branch
