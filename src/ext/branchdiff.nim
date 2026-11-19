## A read-only branch diff, without the understanding ledger's other views.
import std/[os, osproc, strutils, unicode, tables]
import ../[core, buffer, buffers, lisp, syntax, chat, ledger, branchdiff]
import agent, understand, reviewcomments

var
  diffBuf: Buffer
  root, branch, base: string
  files: seq[DiffFile]
  view: DiffView
  faces: seq[seq[Face]]
  bands: seq[int8]

proc rawGit(args: string): tuple[output: string, exitCode: int] =
  # agent.git strips whitespace; patches and NUL-delimited paths must keep it.
  execCmdEx("git -C " & quoteShell(root) & " -c core.quotePath=true " & args,
    options = {poUsePath, poStdErrToStdOut})

proc showDiff(line = 0, message = "") =
  view = diffView(files, branch, base)
  if message.len > 0:
    view.rows = @[view.rows[0], DiffRow(text: message, kind: dkNote, file: -1)]
    view.headers = @[]
  faces = @[]
  bands = @[]
  for row in view.rows:
    let face = case row.kind
      of dkSummary, dkFile: fKeyword
      of dkHunk: fType
      of dkAdded: fAnsi2
      of dkRemoved: fAnsi1
      of dkNote: fComment
      else: fPlain
    var colors = newSeq[Face](row.text.runeLen)
    for c in colors.mitems: c = face
    faces.add colors
    bands.add (case row.kind
      of dkRemoved: 1'i8
      of dkAdded: 2'i8
      else: 0'i8)
  var anchors: seq[CommentAnchor]
  for row in view.rows:
    anchors.add (if row.kind in [dkAdded, dkRemoved, dkContext]:
      CommentAnchor(path: row.path, line: row.newLine, content: row.text[1..^1], excerpt: row.text)
      else: CommentAnchor())
  setCommentView(diffBuf, root, anchors)
  diffBuf.splice(0, diffBuf.text.runeLen, view.text)
  diffBuf.modified = false
  diffBuf.cursor = (clamp(line, 0, diffBuf.lines.high), 0)

const diffOptions = "--no-ext-diff --no-textconv --no-color --no-relative --src-prefix=a/ --dst-prefix=b/ --unified=3 --submodule=short "

proc rebuild(line = 0) =
  let comparison = branchMergeBase(root, base)
  if not comparison.ok or comparison.output.len == 0:
    echoLine = "Cannot find merge base with " & base
    return
  let patch = rawGit("diff " & diffOptions & "--find-renames " & quoteShell(comparison.output) & " --")
  if patch.exitCode != 0:
    echoLine = "git diff: " & patch.output
    return
  var changed = parseDiff(patch.output)
  let untracked = rawGit("ls-files --others --exclude-standard -z")
  if untracked.exitCode != 0:
    echoLine = "git ls-files: " & untracked.output
    return
  for path in untracked.output.split('\0'):
    if path.len == 0: continue
    let added = rawGit("diff --no-index " & diffOptions & "-- /dev/null " & quoteShell(path))
    if added.exitCode notin [0, 1]:
      echoLine = "git diff: " & added.output
      return
    var parsed = parseDiff(added.output)
    if parsed.len == 0: parsed.add DiffFile()  # an empty untracked file
    parsed[0].path = path
    parsed[0].oldPath = ""
    parsed[0].isNew = true
    changed.add parsed[0]
  files = changed
  showDiff(line)

proc selectBase() =
  let origin = diffBuf
  let repo = root
  chooseBase(root, branch, proc(value: string) =
    if diffBuf != origin or root != repo or origin notin reg: return
    let rememberedRange = rangeFor(loadBases(basesPath()), root)
    rememberBase(basesPath(), root, value, rememberedRange)
    interp.env.values["understanding-base-branch"] = stringValue(value)
    base = value
    rebuild())

proc openBranchDiff*() =
  let repo = if b == diffBuf and diffBuf != nil: root else: currentRoot()
  if not (dirExists(repo / ".git") or fileExists(repo / ".git")):
    echoLine = "Not in a git repository"
    return
  root = repo
  branch = branchOf(root)
  if branch.len == 0: branch = "HEAD"
  base = baseFor(loadBases(basesPath()), root)
  if base.len == 0: base = baseBranch(root)
  if diffBuf == nil or diffBuf notin reg:
    diffBuf = newBuffer()
    reg.add(diffBuf, "*branch-diff*")
    setReadOnly(diffBuf, true)
    bindCommentKeys(diffBuf)
    for key in ["n", "p", "tab", "C-i", "S-tab", "enter", "C-m", "C-j", "b", "g", "q"]:
      setLocalKey(diffBuf, key, interp.evalString("(lambda () (branch-diff-key \"" & key & "\"))", "<branch-diff>"))
  files = @[]
  showDiff(message = if base.len == 0: "Choose a base branch (b)" else: "Loading diff…")
  switchTo(diffBuf)
  if base.len == 0:
    echoLine = "Choose a base branch (b)"
    selectBase()
  else: rebuild()

proc branchDiffKey(input: string) =
  if diffBuf == nil or b != diffBuf: return
  var key = if input == "C-i": "tab" else: input
  # chord() reports Shift-TAB as "tab"; keep this distinction inside the local
  # command, as org's folding does, without changing any global key binding.
  when not defined(headless):
    if key == "tab" and shift(): key = "S-tab"
  let line = diffBuf.cursor.line
  let row = view.rows[line]
  case key
  of "n", "p": diffBuf.cursor = (view.nextHeader(line, if key == "n": 1 else: -1), 0)
  of "tab":
    if row.file >= 0:
      files[row.file].folded = not files[row.file].folded
      showDiff(view.headers[row.file])
  of "S-tab":
    var fold = false
    for f in files:
      if not f.folded: fold = true
    for f in files.mitems: f.folded = fold
    let selected = row.file
    showDiff()
    if selected >= 0: diffBuf.cursor = (view.headers[selected], 0)
  of "enter", "C-m", "C-j":
    if row.file < 0: return
    let path = root / row.path
    if files[row.file].deleted or not fileExists(path):
      echoLine = row.path & " was deleted or is unavailable in the working tree"
      return
    let origin = diffBuf.cursor
    let top = renderer.top
    let left = renderer.left
    try:
      visit(path)
      pushXref(diffBuf, origin, top, left)
      b.cursor = (clamp(row.newLine - 1, 0, b.lines.high), 0)
    except CatchableError as e: echoLine = e.msg
  of "b": selectBase()
  of "g":
    branch = branchOf(root)
    if branch.len == 0: branch = "HEAD"
    if base.len == 0: selectBase()
    else: rebuild(line)
  of "q":
    let other = if layout.leaves.len > 1: otherPaneFor() else: nil
    if other != nil and other != pane: selectPane(other)
    else: discard interp.evalString("(previous-buffer)", "<branch-diff>")
  else: discard

faceProviders.add proc(buf: Buffer): seq[seq[Face]] =
  if buf == diffBuf and diffBuf != nil: faces else: @[]
bandProviders.add proc(buf: Buffer): seq[int8] =
  if buf == diffBuf and diffBuf != nil: bands else: @[]
modeNameProviders.add proc(buf: Buffer): string =
  if buf == diffBuf and diffBuf != nil: "Branch diff" else: ""
killHooks.add proc(buf: Buffer) =
  if buf == diffBuf:
    diffBuf = nil
    files = @[]
    view = DiffView()
    faces = @[]
    bands = @[]

interp.defPrimitive("branch-diff-key", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  branchDiffKey(args[0].asString)
  nilValue())
interp.defPrimitive("branch-diff", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if mode in ["", "eval", "execute"]: openBranchDiff()
  else: echoLine = "branch-diff is unavailable here"
  nilValue())
