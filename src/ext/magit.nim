## An ordinary status buffer: its own keys, with normal window/buffer switching.
import std/[os, osproc, strutils, unicode]
import ../[core, buffer, buffers, lisp, syntax, magit]
import agent

type
  Section = enum secNone, secUntracked, secUnstaged, secStaged
  Row = object
    section: Section
    file: bool
    entry: StatusEntry

var
  mbuf: Buffer
  mroot: string
  mrows: seq[Row]
  mfaces: seq[seq[Face]]
  discardRoot, discardPath: string

proc runGit(root, command: string): tuple[output: string, exitCode: int] =
  execCmdEx("git -C " & quoteShell(root) & " " & command & " 2>&1", options = {poUsePath})

proc buildStatus(keepLine = 0) =
  var lines: seq[string]
  mrows = @[]
  mfaces = @[]
  proc add(text: string, row = Row(), face = fPlain) =
    lines.add text
    mrows.add row
    var faces = newSeq[Face](text.runeLen)
    for f in faces.mitems: f = face
    mfaces.add faces
  let status = runGit(mroot, "status --porcelain=v1 -z")
  if status.exitCode != 0:
    for line in strutils.strip(status.output).splitLines:
      add("git: " & line, face = fAnsi1)
  else:
    let branch = runGit(mroot, "symbolic-ref --short -q HEAD")
    let head = runGit(mroot, "log -1 --format=%s")
    add("Head: " & (if branch.exitCode == 0: strutils.strip(branch.output) else: "(detached)") &
      " " & (if head.exitCode == 0: strutils.strip(head.output) else: "(no commits)"), face = fKeyword)
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
        if (section == secUntracked and entry.untracked) or
           (section == secUnstaged and entry.unstaged) or
           (section == secStaged and entry.staged): files.add entry
      add("")
      let title = case section
        of secUntracked: "Untracked files"
        of secUnstaged: "Unstaged changes"
        else: "Staged changes"
      add(title & " (" & $files.len & ")", Row(section: section), fFnname)
      for entry in files:
        add("  " & entry.statusLabel(section == secStaged), Row(section: section, file: true, entry: entry),
          if section == secStaged: fAnsi2 elif section == secUnstaged: fAnsi1 else: fString)
    add("")
    let log = runGit(mroot, "log --oneline -10")
    let commits = if log.exitCode == 0 and strutils.strip(log.output).len > 0: strutils.strip(log.output).splitLines else: @[]
    add("Recent commits (" & $commits.len & ")", face = fFnname)
    for line in commits: add("  " & line, face = fComment)
  if mbuf == nil:
    mbuf = newBuffer()
    reg.add(mbuf, "*magit*")
  mbuf.splice(0, mbuf.text.runeLen, lines.join("\n"))
  mbuf.modified = false
  var line = clamp(keepLine, 0, mbuf.lines.high)
  if keepLine == 0:  # opening: the first file row, so s / u / Enter act at once
    for i, row in mrows:
      if row.file:
        line = i
        break
  mbuf.cursor = (line, 0)
  mbuf.goal = -1

proc action(root, command: string) =
  let here = if mbuf != nil: mbuf.cursor.line else: 0
  try:
    let reply = runGit(root, command)
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

proc visitRow(row: Row) =
  if not row.file: return
  let here = mbuf.cursor.line
  let root = mroot
  visit(root / row.entry.path)
  if row.entry.unstaged and not row.entry.untracked:
    let rel = if row.entry.oldPath.len > 0: row.entry.oldPath else: row.entry.path
    let head = runGit(root, "show " & quoteShell("HEAD:" & rel))
    if head.exitCode == 0: beginReview(head.output.replace("\r\n", "\n"), "git HEAD")
    else: echoLine = strutils.strip(head.output)
  buildStatus(here)

keyFilters.add proc(c: string): bool =
  if mode.len > 0 or prefix.len > 0 or mbuf == nil or b != mbuf: return false
  let here = mbuf.cursor.line
  let row = mrows[here]
  try:
    case c
    of "n", "p":
      mbuf.cursor = (clamp(here + (if c == "n": 1 else: -1), 0, mbuf.lines.high), 0)
      mbuf.goal = -1
    of "s", "u":
      if row.file:
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
      let other = otherPaneFor()
      if other != nil and other != pane: selectPane(other)
      else: discard interp.evalString("(previous-buffer)", "<magit>")
    of "?": echoLine = "s: stage  u: unstage  Enter: visit/review HEAD  k: discard (y/n)  c: commit  P: push  F: pull  g: refresh  n/p: move  q: leave"
    of "backspace", "delete", "C-h", "C-d", "C-k", "C-w", "C-y", "M-y", "C-o", "C-t", "M-d", "M-backspace", "tab", "C-i", "C-/", "C-_":
      echoLine = "The magit buffer is read-only"
    else: return false
  except CatchableError as e: echoLine = e.msg
  true

runeFilters.add proc(r: Rune): bool =
  if mode.len > 0 or prefix.len > 0 or mbuf == nil or b != mbuf: return false
  if r.int < 128 and char(r.int) in {'s', 'u', 'k', 'c', 'P', 'F', 'g', 'n', 'p', 'q', '?'}: return false
  echoLine = "The magit buffer is read-only (? for keys)"
  true
faceProviders.add proc(buf: Buffer): seq[seq[Face]] =
  if mbuf != nil and buf == mbuf: mfaces else: @[]
bandProviders.add proc(buf: Buffer): seq[int8] =
  if mbuf != nil and buf == mbuf:
    result = newSeq[int8](buf.lines.len)
    result[buf.cursor.line] = 5
killHooks.add proc(buf: Buffer) =
  if buf == mbuf: mbuf = nil

interp.defPrimitive("magit-status", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if b != mbuf: mroot = currentRoot()
  buildStatus(if b == mbuf: mbuf.cursor.line else: 0)
  switchTo(mbuf)
  nilValue())

defaults.add """
(global-set-key "C-x g" 'magit-status)
"""
