## The *understanding* buffer: the ledger as a view to work from, like a magit
## status for understanding debt. The branch's files still to understand (with the
## ones already understood), the open debt entries on the branch, the glossary size.
## Enter opens a comparison or the spot, U attests a whole file, g rebuilds, q closes.
import std/[os, strutils, tables, times, sequtils, unicode]
import ../[core, buffer, buffers, lisp, syntax, chat, ledger]
import agent, web

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

proc paint(faces: var seq[Face], a, z: int, face: Face) =
  for i in max(0, a)..<min(z, faces.len): faces[i] = face

proc buildUnderstanding(keepLine = -1) =
  uroot = currentRoot()
  ubranch = branchOf(uroot)
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
    let base = baseBranch(uroot)
    if base.len == 0:
      add("Branch " & ubranch & ": no base branch (setq understanding-base-branch \"name\")", Row(), fKeyword)
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
  ubuf = newBuffer(lines.join("\n"))
  ubuf.path = "*understanding*"
  ufaces = faces
  var line = if keepLine >= 0: keepLine else: 2
  while line < urows.len and urows[line].kind == rkNone and line < urows.high: inc line
  ubuf.cursor = (min(line, ubuf.lines.high), 0)

proc openUnderstanding*() =
  if mode notin ["", "eval", "execute"]: closeOverlay()
  beginOverlay("understanding")
  buildUnderstanding()

proc finishUnderstanding() =
  finishOverlay()
  ubuf = nil

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

proc dispatchUnderstanding(c: string) =
  if c in ["q", "C-g", "escape"]:
    finishUnderstanding()
    return
  let full = overlayKey(c)
  if full.len == 0: return
  let command = keymap.getOrDefault(full).symName
  if full != "C-l": recenterCycle = 0
  let row = if ubuf.cursor.line < urows.len: urows[ubuf.cursor.line] else: Row()
  let here = ubuf.cursor.line
  case full
  of "enter", "C-m", "C-j", "f":
    case row.kind
    of rkFile, rkDoneFile:
      finishOverlay()
      branchRoot = uroot
      afterReview = proc() = openUnderstanding()
      reviewBranchFile(row.rel, row.base)
      if mode != "review": afterReview = nil; openUnderstanding()  # nothing to compare: stay here
    of rkDebt:
      finishOverlay()
      try:
        visit(row.file)
        b.cursor = (min(row.line - 1, b.lines.high), 0)
      except CatchableError as e: echoLine = e.msg
    of rkLedger:
      if row.file.len > 0:
        finishOverlay()
        visit(row.file)
    of rkNone: echoLine = "Nothing to open here"
  of "U":
    if row.kind == rkFile:
      attestFile(row.rel, row.base)
      buildUnderstanding(here)
    else: echoLine = "U marks a file still to understand"
  of "o":
    let path = ledgerPath()
    if path.len == 0: echoLine = "understanding-ledger is nil"
    else:
      finishOverlay()
      visit(path)
  of "g":
    buildUnderstanding(here)
    echoLine = "Rebuilt"
  of "?": echoLine = "Enter: compare the file with the base / go to the debt   U: whole file understood   o: the ledger   g: rebuild   q: close"
  of "f1":
    finishUnderstanding()
    dispatch(full)
  of "C-x C-c": quitEditor()
  else:
    if command == "understanding": finishUnderstanding()
    elif overlayMove(ubuf, full, command): discard
    else: echoLine = full & " is undefined"

defineMode(Mode(name: "understanding", modeName: "Understanding", buffer: proc(): Buffer = ubuf,
  faces: proc(): seq[seq[Face]] = ufaces,
  message: proc(): string = (if echoLine.len > 0: echoLine else: "Understanding  Enter:open U:understood o:ledger g:rebuild q:close ?:help"),
  onKey: dispatchUnderstanding, onClose: finishUnderstanding))

interp.defPrimitive("understanding", proc(args: seq[Value]): Value =
  ## M-x understanding / C-c u: the understanding buffer; from inside it, closes it.
  args.arity(0, 0)
  if mode == "understanding": finishUnderstanding()
  elif mode in ["", "eval", "execute"]: openUnderstanding()
  else: echoLine = "understanding is unavailable here"
  nilValue())

defaults.add """
(global-set-key "C-c u" 'understanding)
"""
