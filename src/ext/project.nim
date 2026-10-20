## Projects, as Emacs' project.el under C-x p: f finds a file in the project (the
## nearest .git above the current file, else its directory), p switches to a project
## visited before and finds a file there, b lists the project's buffers.
import std/[os, strutils, sequtils]
import ../[core, buffer, buffers, lisp, chat, project]

var
  projectRoot: string
  fileRows: seq[string]
  rootRows: seq[string]
  bufferRows: seq[string]

proc currentRoot(): string =
  let dir = if core.b.path.len > 0: parentDir(core.b.path) else: getCurrentDir()
  rootFromDir(dir)

proc findFileIn(root: string) =
  projectRoot = root
  fileRows = projectFiles(root)
  if fileRows.len == 0:
    echoLine = "No files under " & shortPath(root)
    return
  recordProject(root)
  beginMini("project-file", "Find file in " & extractFilename(root) & ": ")

definePrompt(Prompt(kind: "project-file", text: true, candidates: proc(): seq[string] = fileRows,
  onAccept: proc(value: string): bool =
    if value.len == 0: return false
    try: visit(projectRoot / value)
    except CatchableError as e: echoLine = e.msg
    true))
definePrompt(Prompt(kind: "project-switch", text: true, candidates: proc(): seq[string] = rootRows,
  onAccept: proc(value: string): bool =
    let root = expandTilde(value)
    if not dirExists(root):
      echoLine = "No such directory: " & value
      return true
    findFileIn(root)
    true))
definePrompt(Prompt(kind: "project-buffer", text: true, candidates: proc(): seq[string] = bufferRows,
  onAccept: proc(value: string): bool =
    let buf = reg.byName(value)
    if buf != nil: switchTo(buf)
    true))

interp.defPrimitive("project-find-file", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  findFileIn(currentRoot())
  nilValue())
interp.defPrimitive("project-switch-project", proc(args: seq[Value]): Value =
  ## C-x p p: a project visited before (or any directory typed), then a file in it.
  args.arity(0, 0)
  rootRows = loadProjects().mapIt(shortPath(it, 80))
  let here = currentRoot()
  if here notin loadProjects(): rootRows.insert(shortPath(here, 80), 0)
  beginMini("project-switch", "Project: ")
  nilValue())
interp.defPrimitive("project-buffers", proc(args: seq[Value]): Value =
  ## C-x p b: the buffers whose files are under the current project.
  args.arity(0, 0)
  let root = currentRoot()
  bufferRows = @[]
  for name in reg.names:
    let buf = reg.byName(name)
    if buf != nil and buf.path.len > 0 and buf.path.startsWith(root & "/"): bufferRows.add name
  if bufferRows.len == 0:
    echoLine = "No buffers in " & shortPath(root)
    return nilValue()
  beginMini("project-buffer", "Project buffer: ")
  nilValue())

visitHooks.add proc() =
  # Visiting a file in a repository makes it a known project for C-x p p.
  if core.b.path.len > 0:
    let root = rootFromDir(parentDir(core.b.path))
    if dirExists(root / ".git") or fileExists(root / ".git"): recordProject(root)

interp.defPrimitive("project-dired", proc(args: seq[Value]): Value =
  ## The project's root in dired (projectile's D).
  args.arity(0, 0)
  discard interp.call(symbol("dired"), @[stringValue(currentRoot())])
  nilValue())

defaults.add """
(global-set-key "C-x p f" 'project-find-file)
(global-set-key "C-x p p" 'project-switch-project)
(global-set-key "C-x p b" 'project-buffers)
(defhydra "C-c p" "projectile"
  '(("f" project-find-file "find file")
    ("p" project-switch-project "switch project")
    ("b" project-buffers "buffers")
    ("s" consult-ripgrep "grep")
    ("r" rgrep "rgrep buffer")
    ("v" magit-status "magit")
    ("d" project-dired "dired root")
    ("l" agent-locate "ask the agent")
    ("q" nil "quit")))
"""
