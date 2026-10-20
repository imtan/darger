## The *understanding* buffer: the ledger as a view to work from, like a magit
## status for understanding debt. The branch's files still to understand (with the
## ones already understood), the open debt entries on the branch, the glossary size.
## An ordinary read-only buffer with its own keys (window and buffer commands work as
## usual): Enter opens a comparison or the spot, b picks the base branch, U attests a
## whole file, x explains a debt, o opens the ledger, g rebuilds, q leaves.
import std/[os, strutils, tables, times, unicode]
import ../[core, buffer, buffers, lisp, syntax, chat, ledger]
import agent

type
  RowKind = enum rkNone, rkFile, rkDoneFile, rkDebt, rkLedger
  Row = object
    kind: RowKind
    rel, base, file: string
    line: int

var
  ubuf: Buffer
  ufaces: seq[seq[Face]]
  urows: seq[Row]
  uroot, ubranch: string
  ubase: string   # the base branch compared with: the setting, else the one remembered for this repository

proc basesPath(): string = getHomeDir() / ".darger-understanding-bases"

proc settingBase(): string =
  let v = interp.env.values["understanding-base-branch"]
  if v.kind != vNil and v.asString.len > 0: v.asString else: ""

proc otherBranches(): seq[string] =
  let (output, ok) = git(uroot, "for-each-ref --format=" & quoteShell("%(refname:short)") & " refs/heads refs/remotes")
  if ok:
    for l in output.splitLines:
      if l.len > 0 and l != ubranch and not l.endsWith("/HEAD") and l notin result: result.add l

proc paint(faces: var seq[Face], a, z: int, face: Face) =
  for i in max(0, a)..<min(z, faces.len): faces[i] = face

proc buildUnderstanding(keepLine = -1) =
  var lines: seq[string]
  var faces: seq[seq[Face]]
  urows = @[]
  proc add(text: string, row: Row, face = fPlain, upTo = -1) =
    lines.add text
    var f = newSeq[Face](text.runeLen)
    if face != fPlain: paint(f, 0, (if upTo < 0: f.len else: upTo), face)
    faces.add f
    urows.add row
  let ledger = ledgerPath()
  let ledgerText = if ledger.len > 0 and fileExists(ledger): readFile(ledger) else: ""
  let inGit = dirExists(uroot / ".git") or fileExists(uroot / ".git")
  if inGit:
    let base = ubase
    if base.len == 0:
      add("Branch " & ubranch & ": no base branch chosen (b)", Row(), fKeyword)
    else:
      let changes = branchChanges(uroot, ubranch, base)
      let mergeBase = changes.mergeBase
      var todo, done: seq[tuple[rel, text: string]]
      for f in changes.files:
        let text = "    " & f.rel & "   " & plusMinus(f) & (if f.dirty: "   (uncommitted)" else: "")
        if f.understood: done.add (f.rel, text)
        else: todo.add (f.rel, text)
      add("Branch " & ubranch & " vs " & base & (if changes.error.len > 0: "   git: " & changes.error else: ""), Row(), fKeyword)
      add("  To understand (" & $todo.len & ")", Row(), fConstant)
      for (rel, text) in todo:
        add(text, Row(kind: rkFile, rel: rel, base: mergeBase), (if "(uncommitted)" in text: fAnsi3 else: fPlain))
      if todo.len == 0: add("    nothing: every change from " & base & " is understood", Row(), fComment)
      add("  Understood (" & $done.len & ")", Row(), fConstant)
      for (rel, text) in done: add(text, Row(kind: rkDoneFile, rel: rel, base: mergeBase), fComment)
      add("", Row())
  else:
    add("Not in a git repository: " & shortPath(uroot), Row(), fKeyword)
    add("", Row())
  let debts = debtEntries(ledgerText, if inGit: ubranch else: "")
  let (open, understoodCount) = debtCount(ledgerText)
  add("Open debt" & (if inGit and ubranch.len > 0: " on " & ubranch else: "") & " (" & $debts.len & ")" &
    (if open != debts.len: "   " & $open & " open on all branches" else: "") & "   " & $understoodCount & " understood", Row(), fConstant)
  for d in debts:
    add("    " & d.label, Row(kind: rkDebt, file: d.file, line: d.line), fAnsi1, upTo = d.label.find("  ") + 4)
  if debts.len == 0: add("    none", Row(), fComment)
  add("", Row())
  let glossary = glossaryPath()
  let terms = if glossary.len > 0 and fileExists(glossary): glossaryTerms(readFile(glossary)).len else: 0
  add("Glossary: " & $terms & " terms (M-x glossary)   Ledger: " & (if ledger.len > 0: shortPath(ledger) else: "nil") & " (o)",
    Row(kind: rkLedger, file: ledger), fComment)
  if ubuf == nil or ubuf notin reg:
    ubuf = newBuffer()
    reg.add(ubuf, "*understanding*")
  ubuf.splice(0, ubuf.text.runeLen, lines.join("\n"))
  ubuf.modified = false
  ufaces = faces
  var line = if keepLine >= 0: keepLine else: 2
  while line < urows.len and urows[line].kind == rkNone and line < urows.high: inc line
  ubuf.cursor = (min(line, ubuf.lines.high), 0)

var baseRows: seq[string]

proc chooseBase(first = false) =
  ## The base branch to compare with, from the local and remote-tracking branches, the
  ## usual one (main / master / develop) first; remembered for this repository.
  baseRows = otherBranches()
  let usual = baseBranch(uroot)
  if usual.len > 0 and usual in baseRows:
    baseRows.delete(baseRows.find(usual))
    baseRows.insert(usual, 0)
  if baseRows.len == 0:
    echoLine = "No other branch to compare with"
    return
  beginMini("understanding-base", (if first: "Understand " & ubranch & " against: " else: "Compare " & ubranch & " with: "))

definePrompt(Prompt(kind: "understanding-base", text: true,
  candidates: proc(): seq[string] = baseRows,
  onAccept: proc(value: string): bool =
    if value.len == 0: return true
    ubase = value
    rememberBase(basesPath(), uroot, value)
    interp.env.values["understanding-base-branch"] = stringValue(value)  # branch-debt follows, this session
    buildUnderstanding()
    echoLine = "Comparing with " & value & " (remembered for " & extractFilename(uroot) & "; b changes it)"
    true))

proc openUnderstanding*() =
  ## C-c u: the buffer for the current file's repository, shown in this window; the
  ## first time in a repository (nothing remembered) the base branch is asked for, so
  ## the comparison is never silently against master.
  uroot = currentRoot()
  ubranch = branchOf(uroot)
  ubase = settingBase()
  if ubase.len == 0: ubase = baseFor(loadBases(basesPath()), uroot)
  buildUnderstanding()
  switchTo(ubuf)
  if ubase.len == 0 and ubranch.len > 0: chooseBase(first = true)

proc leaveUnderstanding() =
  ## q: the other window when there is one, else the previous buffer.
  let other = otherPaneFor()
  if other != nil and other != pane: selectPane(other)
  else: discard interp.evalString("(previous-buffer)", "<understanding>")

proc attestFile(rel, base: string) =
  ## U: the whole file understood, as one DONE entry at its current commit.
  let path = ledgerPath()
  if path.len == 0:
    echoLine = "understanding-ledger is nil"
    return
  let file = uroot / rel
  appendEntries(path, @[LedgerEntry(file: file, line: 1, project: extractFilename(uroot), source: "branch base",
    branch: ubranch, rev: fileRev(uroot, file), explanation: "(understood by the reviewer, whole file)", at: now())])
  echoLine = rel & " marked understood"

proc understandingKey(c: string): bool =
  ## The buffer's keys, while it is current and no prefix is pending; everything else
  ## (C-x o, C-x b, splits) is the editor's as usual. Named keys arrive through
  ## keyFilters, typed letters through runeFilters.
  if mode.len > 0 or prefix.len > 0 or ubuf == nil or b != ubuf: return false
  let row = if ubuf.cursor.line < urows.len: urows[ubuf.cursor.line] else: Row()
  let here = ubuf.cursor.line
  case c
  of "enter", "C-m", "C-j", "f":
    case row.kind
    of rkFile, rkDoneFile:
      branchRoot = uroot
      afterReview = proc() =
        switchTo(ubuf)
        buildUnderstanding(here)
      reviewBranchFile(row.rel, row.base)
      if mode != "review":  # nothing to compare: stay here
        afterReview = nil
        switchTo(ubuf)
        buildUnderstanding(here)
    of rkDebt:
      try:
        visit(row.file)
        b.cursor = (min(row.line - 1, b.lines.high), 0)
      except CatchableError as e: echoLine = e.msg
    of rkLedger:
      if row.file.len > 0: visit(row.file)
    of rkNone: echoLine = "Nothing to open here"
  of "x":
    if row.kind == rkDebt:
      try:
        visit(row.file)
        b.cursor = (min(row.line - 1, b.lines.high), 0)
        repayUnderstanding()
      except CatchableError as e: echoLine = e.msg
    else: echoLine = "x explains an open debt"
  of "b": chooseBase()
  of "U":
    if row.kind == rkFile:
      attestFile(row.rel, row.base)
      buildUnderstanding(here)
    else: echoLine = "U marks a file still to understand"
  of "o":
    let path = ledgerPath()
    if path.len == 0: echoLine = "understanding-ledger is nil"
    else: visit(path)
  of "g":
    buildUnderstanding(here)
    echoLine = "Rebuilt"
  of "q": leaveUnderstanding()
  of "?": echoLine = "Enter: compare the file with the base / go to the debt   x: explain debt   b: base branch   U: whole file understood   o: the ledger   g: rebuild   q: leave"
  else: return false
  true
keyFilters.add understandingKey
runeFilters.add proc(r: Rune): bool =
  # Typed letters are the buffer's keys; anything else is swallowed (read-only).
  if mode.len > 0 or prefix.len > 0 or ubuf == nil or b != ubuf: return false
  if understandingKey($r): return true
  echoLine = "The understanding buffer is read-only (? for its keys)"
  true
faceProviders.add proc(buf: Buffer): seq[seq[Face]] =
  if buf == ubuf and ubuf != nil: ufaces else: @[]
bandProviders.add proc(buf: Buffer): seq[int8] =
  # The row under the cursor when it is a file or an entry.
  if buf == ubuf and ubuf != nil and ubuf.cursor.line < urows.len and urows[ubuf.cursor.line].kind != rkNone:
    result = newSeq[int8](ubuf.lines.len)
    result[ubuf.cursor.line] = 5
killHooks.add proc(buf: Buffer) =
  if buf == ubuf: ubuf = nil

interp.defPrimitive("understanding-base", proc(args: seq[Value]): Value =
  ## (understanding-base) asks for the base branch inside the buffer; (understanding-base "name") sets it.
  args.arity(0, 1)
  if args.len == 1:
    interp.env.values["understanding-base-branch"] = stringValue(args[0].asString)
    ubase = args[0].asString
    if ubuf != nil and b == ubuf: buildUnderstanding()
  elif ubuf != nil and b == ubuf: chooseBase()
  else: echoLine = "Open the understanding buffer first (C-c u)"
  nilValue())

interp.defPrimitive("understanding", proc(args: seq[Value]): Value =
  ## M-x understanding / C-c u: the understanding buffer; from inside it, leaves it.
  args.arity(0, 0)
  if ubuf != nil and b == ubuf: leaveUnderstanding()
  elif mode in ["", "eval", "execute"]: openUnderstanding()
  else: echoLine = "understanding is unavailable here"
  nilValue())

defaults.add """
(global-set-key "C-c u" 'understanding)
"""
