## An ordinary status buffer: its own keys, with normal window/buffer switching.
import std/[os, osproc, strutils, unicode, sets, streams]
import ../[core, buffer, buffers, lisp, syntax, magit, branchdiff]
import agent, reviewcomments

var
  mbuf: Buffer
  mroot: string
  mrows: seq[Row]
  mfaces: seq[seq[Face]]
  mbands: seq[int8]
  folds: FoldState
  mfiles: seq[FileKey]
  discardRoot, discardPath: string

proc runGit(root, command: string, input = ""): tuple[output: string, exitCode: int] =
  # execCmdEx normalises CRLF and adds a final newline, which corrupts patches.
  let process = startProcess("git -C " & quoteShell(root) & " -c core.quotePath=true " & command,
    options = {poUsePath, poEvalCommand, poStdErrToStdOut})
  try:
    if input.len > 0: process.inputStream.write(input)
    process.inputStream.close()
    result.output = process.outputStream.readAll()
    result.exitCode = process.waitForExit()
  finally: process.close()

proc loadRows(entry: StatusEntry, section: Section): seq[Row] =
  let expanded = (section, entry.path) in folds.expanded
  if not expanded: return fileRows(entry, section, false)
  if section == secUntracked and not symlinkExists(mroot / entry.path) and
      getFileSize(mroot / entry.path) > 512 * 1024:
    return fileRows(entry, section, true, note = "(large untracked file; diff omitted)")
  var command = "--literal-pathspecs diff " & diffOptions
  if section == secUntracked:
    command.add "--no-index -- /dev/null " & quoteShell(entry.path)
  else:
    if section == secStaged: command.add "--cached "
    command.add "-- " & quoteShell(entry.path)
    if entry.oldPath.len > 0: command.add " " & quoteShell(entry.oldPath)
  let reply = runGit(mroot, command)
  if reply.exitCode != 0 and not (section == secUntracked and reply.exitCode == 1):
    return fileRows(entry, section, true, note = "git diff: " & reply.output.strip.splitLines.join(" "))
  fileRows(entry, section, true, reply.output)

proc buildStatus(keepLine = -1) =
  let selected = if keepLine >= 0 and keepLine < mrows.len: mrows[keepLine] else: Row()
  var lines: seq[string]
  mrows = @[]
  mfaces = @[]
  mbands = @[]
  mfiles = @[]
  proc add(text: string, row = Row(), face = fPlain) =
    lines.add text
    mrows.add row
    var faces = newSeq[Face](text.runeLen)
    for f in faces.mitems: f = face
    mfaces.add faces
    mbands.add (case row.kind
      of dkRemoved: 1'i8
      of dkAdded: 2'i8
      else: 0'i8)
  let status = runGit(mroot, "status --porcelain=v1 -z --untracked-files=all")
  if status.exitCode != 0:
    for line in strutils.strip(status.output).splitLines:
      add("git: " & line, face = fAnsi1)
  else:
    let branch = runGit(mroot, "symbolic-ref --short -q HEAD")
    let head = runGit(mroot, "log -1 --format=%s")
    add("Head: " & (if branch.exitCode == 0: strutils.strip(branch.output) else: "(detached)") &
      " " & (if head.exitCode == 0: strutils.strip(head.output) else: "(no commits)"), face = fKeyword)
    add("TAB diff  S-TAB all  Enter open (M-, back)  s/u stage  c commit  C comment  r review  ? keys", face = fComment)
    let upstream = runGit(mroot, "rev-parse --abbrev-ref --symbolic-full-name " & quoteShell("@{u}"))
    if upstream.exitCode == 0:
      let counts = runGit(mroot, "rev-list --left-right --count " & quoteShell("@{u}...HEAD"))
      let parts = strutils.splitWhitespace(counts.output)
      add("Upstream: " & strutils.strip(upstream.output) &
        (if counts.exitCode == 0 and parts.len == 2: " (ahead " & parts[1] & ", behind " & parts[0] & ")" else: ""), face = fConstant)
    let entries = parseStatus(status.output)
    for section in [secUntracked, secUnstaged, secStaged]:
      var files: seq[StatusEntry]
      for entry in entries:
        if entry.inSection(section):
          files.add entry
          mfiles.add (section, entry.path)
      add("")
      let title = case section
        of secUntracked: "Untracked files"
        of secUnstaged: "Unstaged changes"
        else: "Staged changes"
      add(title & " (" & $files.len & ") " & (if section in folds.hidden: "▸" else: "▾"),
        Row(section: section, heading: true), fFnname)
      if section in folds.hidden: continue
      for entry in files:
        for row in loadRows(entry, section):
          let face = case row.kind
            of dkFile: (if section == secStaged: fAnsi2 elif section == secUnstaged: fAnsi1 else: fString)
            of dkHunk: fType
            of dkAdded: fAnsi2
            of dkRemoved: fAnsi1
            of dkNote: fComment
            else: fPlain
          add(row.text, row, face)
    add("")
    let log = runGit(mroot, "log --oneline -10")
    let commits = if log.exitCode == 0 and strutils.strip(log.output).len > 0: strutils.strip(log.output).splitLines else: @[]
    add("Recent commits (" & $commits.len & ") " & (if secRecent in folds.hidden: "▸" else: "▾"),
      Row(section: secRecent, heading: true), fFnname)
    if secRecent notin folds.hidden:
      for line in commits: add("  " & line, Row(section: secRecent), fComment)
  if mbuf == nil:
    mbuf = newBuffer()
    reg.add(mbuf, "*magit*")
    setReadOnly(mbuf, true)
    bindCommentKeys(mbuf, key = "C", send = false)
    for key in ["s", "u", "k", "c", "P", "F", "g", "q", "n", "p", "?", "r",
                "tab", "C-i", "S-tab", "enter", "C-m", "C-j"]:
      setLocalKey(mbuf, key, interp.evalString("(lambda () (magit-key \"" & key & "\"))", "<magit>"))
  var anchors: seq[CommentAnchor]
  for row in mrows:
    anchors.add (if row.kind in [dkAdded, dkRemoved, dkContext] and row.entry.path.len > 0:
      CommentAnchor(path: row.entry.path, line: row.newLine, content: row.text[1..^1], excerpt: row.text)
      else: CommentAnchor())
  setCommentView(mbuf, mroot, anchors)
  mbuf.splice(0, mbuf.text.runeLen, lines.join("\n"))
  mbuf.modified = false
  var line = restoredRow(mrows, selected, keepLine)
  if keepLine < 0:  # opening: the first file row, so s / u / Enter act at once
    for i, row in mrows:
      if row.file:
        line = i
        break
  mbuf.cursor = (line, 0)
  mbuf.goal = -1

proc action(root, command: string, input = "") =
  let here = if mbuf != nil: mbuf.cursor.line else: 0
  try:
    let reply = runGit(root, command, input)
    let output = strutils.strip(reply.output)
    echoLine = if output.len > 0: output.splitLines()[^1]
               elif reply.exitCode == 0: "git: done"
               else: "git failed (" & $reply.exitCode & ")"
  except CatchableError as e: echoLine = e.msg
  if mbuf != nil: buildStatus(here)

definePrompt(Prompt(kind: "magit-commit", text: true, onAccept: proc(value: string): bool =
  if strutils.strip(value).len == 0: return false
  action(mroot, "commit -q -m " & quoteShell(value))
  true))
definePrompt(Prompt(kind: "magit-discard", text: true, onAccept: proc(value: string): bool =
  case strutils.strip(value).toLowerAscii
  of "y", "yes": action(discardRoot, "--literal-pathspecs checkout -- " & quoteShell(discardPath))
  of "n", "no": echoLine = "Discard cancelled"
  else: return false
  true))

proc visitRow(row: Row, review = false) =
  if row.entry.path.len == 0: return
  let root = mroot
  let path = root / row.entry.path
  if not fileExists(path):
    echoLine = displayPath(row.entry.path) & " was deleted or is unavailable in the working tree"
    return
  let history = xrefStack
  pushXref(mbuf, mbuf.cursor, renderer.top, renderer.left)
  try: visit(path)
  except CatchableError:
    xrefStack = history
    raise
  if not row.file: b.cursor = (clamp(row.newLine - 1, 0, b.lines.high), 0)
  echoLine = "M-, returns to *magit*"
  if review and row.entry.unstaged and not row.entry.untracked:
    let rel = if row.entry.oldPath.len > 0: row.entry.oldPath else: row.entry.path
    let head = runGit(root, "show " & quoteShell("HEAD:" & rel))
    if head.exitCode == 0: beginReview(head.output.replace("\r\n", "\n"), "git HEAD")
    else: echoLine = strutils.strip(head.output)

proc magitKey(input: string) =
  if mbuf == nil or b != mbuf: return
  var c = if input == "C-i": "tab" else: input
  when not defined(headless):
    if c == "tab" and shift(): c = "S-tab"
  let here = mbuf.cursor.line
  let row = mrows[here]
  try:
    case c
    of "n", "p":
      mbuf.cursor = (clamp(here + (if c == "n": 1 else: -1), 0, mbuf.lines.high), 0)
      mbuf.goal = -1
    of "s", "u":
      if not row.file and row.patch.len > 0 and row.section != secUntracked:
        if (c == "s" and row.section == secUnstaged) or (c == "u" and row.section == secStaged):
          action(mroot, "apply --cached " & (if c == "u": "-R " else: "") & "--whitespace=nowarn -", row.patch)
        else: echoLine = "Select an unstaged hunk to stage or a staged hunk to unstage"
      elif row.entry.path.len > 0:
        var paths = quoteShell(row.entry.path)
        if row.entry.oldPath.len > 0 and
            ((c == "u" and row.entry.index in {'R', 'C'}) or
             (c == "s" and row.entry.worktree in {'R', 'C'})):
          paths.add " " & quoteShell(row.entry.oldPath)
        action(mroot, "--literal-pathspecs " & (if c == "s": "add -- " else: "reset -q HEAD -- ") & paths)
      elif c == "s" and row.section in {secUntracked, secUnstaged}: action(mroot, "add -A")
      elif c == "u" and row.section == secStaged: action(mroot, "reset -q HEAD")
      else: echoLine = "Select a file or an applicable section"
    of "enter", "C-m", "C-j": visitRow(row)
    of "r": visitRow(row, review = true)
    of "tab":
      folds.toggle(row)
      buildStatus(here)
    of "S-tab":
      folds.toggleAll(mfiles)
      buildStatus(here)
    of "k":
      if row.file and row.entry.unstaged:
        discardRoot = mroot
        discardPath = row.entry.path
        beginMini("magit-discard", "Discard unstaged changes to " & displayPath(discardPath) & "? (y/n): ")
      else: echoLine = "Select an unstaged file to discard"
    of "c": beginMini("magit-commit", "Commit message: ")
    of "P": action(mroot, "push")
    of "F": action(mroot, "pull --ff-only")
    of "g": buildStatus(here)
    of "q":
      let other = if layout.leaves.len > 1: otherPaneFor() else: nil
      if other != nil and other != pane: selectPane(other)
      else: discard interp.evalString("(previous-buffer)", "<magit>")
    of "?": echoLine = "TAB: diff/section  S-TAB: all diffs  Enter: open  M-,: back  r: review HEAD  s/u: stage/unstage file or hunk  k: discard (y/n)  c: commit  C: comment  C-c C-k: delete comment  P: push  F: pull  g: refresh  n/p: move  q: leave"
    else: discard
  except CatchableError as e: echoLine = e.msg
faceProviders.add proc(buf: Buffer): seq[seq[Face]] =
  if mbuf != nil and buf == mbuf: mfaces else: @[]
bandProviders.add proc(buf: Buffer): seq[int8] =
  if mbuf != nil and buf == mbuf:
    result = mbands
    if result[buf.cursor.line] == 0: result[buf.cursor.line] = 5
killHooks.add proc(buf: Buffer) =
  if buf == mbuf: mbuf = nil

interp.defPrimitive("magit-key", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  magitKey(args[0].asString)
  nilValue())

interp.defPrimitive("magit-status", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if b != mbuf:
    let root = currentRoot()
    if root != mroot: folds = FoldState()
    mroot = root
  buildStatus(if b == mbuf: mbuf.cursor.line else: -1)
  switchTo(mbuf)
  nilValue())

defaults.add """
(global-set-key "C-x g" 'magit-status)
"""
