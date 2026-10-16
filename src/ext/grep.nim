## consult-ripgrep: search a directory's files for a query with ripgrep (grep without
## it) and pick among the matches with a preview, as consult-ripgrep does.
import std/[os, strutils, tables]
import ../[core, buffer, lisp, chat, lsp, grep]

var grepDir: string  # the directory the query prompt searches

proc grepRoot(): string =
  ## The project (nearest .git above the file), else the file's directory, else the cwd.
  let dir = if core.b.path.len > 0: parentDir(core.b.path) else: getCurrentDir()
  rootFromDir(dir)

proc consultRipgrep*(dir = "") =
  ## Asks for the query, then lists `file:line: text` matches to narrow and jump to.
  grepDir = if dir.len > 0: expandTilde(dir) else: grepRoot()
  if not dirExists(grepDir):
    echoLine = "No such directory: " & grepDir
    return
  beginMini("grep-query", "Grep in " & shortPath(grepDir, 40) & ": ")

proc showHits(query: string): bool =
  let (hits, error) = runGrep(grepDir, query)
  if error.len > 0:
    echoLine = "grep: " & error
    return true
  if hits.len == 0:
    echoLine = "No matches for " & query & " in " & shortPath(grepDir, 40)
    return true
  targets = @[]
  refRows = @[]
  for h in hits:
    targets.add Location(path: h.path, line: h.line, col: h.col)
    refRows.add hitRow(h, grepDir)
  beginMini("grep-results", "Match: ")
  true

definePrompt(Prompt(kind: "grep-query", text: true, onAccept: proc(value: string): bool =
  if value.len == 0: return false
  showHits(value)))
definePrompt(Prompt(kind: "grep-results", text: true, consult: true, candidates: refRowsNow, onAccept: acceptReference))

interp.defPrimitive("consult-ripgrep", proc(args: seq[Value]): Value =
  ## (consult-ripgrep) searches the project; (consult-ripgrep "dir") that directory.
  args.arity(0, 1)
  consultRipgrep(if args.len == 1: args[0].asString else: "")
  nilValue())
interp.defPrimitive("consult-ripgrep-org", proc(args: seq[Value]): Value =
  ## C-c n s: the user's `my/consult-ripgrep-org`: search the whole Org directory.
  args.arity(0, 0)
  consultRipgrep(interp.env.values["org-roam-directory"].asString)
  nilValue())

defaults.add """
(global-set-key "C-c n s" 'consult-ripgrep-org)
"""
