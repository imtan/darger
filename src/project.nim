import remote
## Projects for the C-x p commands: the files of a project root (git's list when it is
## a repository, else a walk that skips hidden and build directories) and the roots
## visited before, kept in ~/.darger-projects.
import std/[os, strutils, osproc, algorithm]
import fileio

const
  maxProjects* = 30
  maxFiles* = 20000
  skipDirs = ["node_modules", "nimcache", "target", "build", "dist", ".git", "__pycache__"]

proc projectsPath(): string = getHomeDir() / ".darger-projects"

proc projectFiles*(root: string): seq[string] =
  if isRemote(root): return @[]
  ## Relative paths under root, sorted: `git ls-files -co --exclude-standard` in a
  ## repository (tracked and untracked, ignores applied), else every regular file
  ## outside hidden and build directories.
  if dirExists(root / ".git") or fileExists(root / ".git"):
    let (output, code) = execCmdEx("git -C " & quoteShell(root) & " ls-files -co --exclude-standard -z",
      options = {poUsePath})
    if code == 0:
      for f in output.split('\0'):
        if f.len > 0: result.add f
        if result.len >= maxFiles: break
      result.sort()
      return
  for path in walkDirRec(root, relative = true, yieldFilter = {pcFile}, followFilter = {pcDir}):
    var skip = false
    for part in path.split('/'):
      if part.startsWith('.') or part in skipDirs: skip = true
    if skip: continue
    result.add path
    if result.len >= maxFiles: break
  result.sort()

proc loadProjects*(path = projectsPath()): seq[string] =
  ## Known project roots, most recent first.
  var text: string
  try: text = readFile(path)
  except CatchableError: return
  for line in text.splitLines:
    if line.len > 0 and line notin result and result.len < maxProjects: result.add line

proc recordProject*(root: string, path = projectsPath()) =
  if root.len == 0 or '\n' in root: return
  var roots = @[root]
  for r in loadProjects(path):
    if r != root and roots.len < maxProjects: roots.add r
  try: atomicWrite(path, roots.join("\n") & "\n")
  except CatchableError: discard
