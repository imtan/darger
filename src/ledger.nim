## The understanding ledger: hunks taken in a review, as Org entries in one file.
## A hunk taken without asking for an explanation is a TODO (understanding debt);
## one taken after the explanation is DONE with the explanation under it, so the
## user's Org tools (agenda, TODO keywords) track what is still to be understood.
import std/[strutils, times, os, sequtils]

type LedgerEntry* = object
  file*: string         ## the file the hunk changed
  line*: int            ## 1-based line in the file after the change
  project*: string      ## the project's directory name, as a tag
  source*: string       ## "Agent", "file on disk", "branch base", ...
  branch*: string       ## the git branch the work was on ("" outside git)
  rev*: string          ## the file's last-change commit when recorded ("" when unknown)
  removed*, added*: string
  explanation*: string  ## "" = debt
  at*: DateTime

proc tagOf(s: string): string =
  ## An Org tag: letters, digits, _ and @ only.
  for c in s:
    if c.isAlphaNumeric or c in {'_', '@'}: result.add c
    else: result.add '_'
  if result.len == 0: result = "project"

proc orgEntry*(e: LedgerEntry): string =
  ## One ledger heading with properties, the hunk as a diff block, and the explanation.
  let keyword = if e.explanation.len > 0: "DONE" else: "TODO"
  let name = extractFilename(e.file)
  let state = if e.explanation.len > 0: "understood"
    elif e.source == "branch base": "not yet understood" else: "taken without explanation"
  result = "* " & keyword & " " & name & ":" & $e.line & "  " & state &
    "  :" & (if e.explanation.len > 0: "understood" else: "debt") & ":" & tagOf(e.project) &
    (if e.branch.len > 0: ":" & tagOf(e.branch) else: "") & ":\n"
  result.add ":PROPERTIES:\n:FILE:     " & e.file & "\n:LINE:     " & $e.line & "\n:SOURCE:   " & e.source
  if e.branch.len > 0: result.add "\n:BRANCH:   " & e.branch
  if e.rev.len > 0: result.add "\n:REV:      " & e.rev
  result.add "\n:DATE:     " & e.at.format("yyyy-MM-dd HH:mm") & "\n:END:\n"
  result.add "#+begin_src diff\n"
  for l in e.removed.splitLines(keepEol = true):
    if l.len > 0: result.add "-" & l
  if e.removed.len > 0 and not e.removed.endsWith("\n"): result.add "\n"
  for l in e.added.splitLines(keepEol = true):
    if l.len > 0: result.add "+" & l
  if e.added.len > 0 and not e.added.endsWith("\n"): result.add "\n"
  result.add "#+end_src\n"
  if e.explanation.len > 0: result.add strutils.strip(e.explanation) & "\n"

proc appendEntries*(path: string, entries: seq[LedgerEntry]) =
  ## Entries added to the ledger file (created with a title when missing).
  if entries.len == 0: return
  var text = ""
  if fileExists(path): text = readFile(path)
  else: text = "#+title: Understanding ledger\n#+startup: folded\n\n"
  if text.len > 0 and not text.endsWith("\n"): text.add "\n"
  for e in entries: text.add orgEntry(e)
  writeFile(path, text)

type LedgerItem* = tuple[label, file: string, line: int, branch, rev: string, done: bool]

proc entries*(text: string): seq[LedgerItem] =
  ## Every entry: heading text and its FILE / LINE / BRANCH / REV properties.
  var i = 0
  let lines = text.splitLines
  while i < lines.len:
    if lines[i].startsWith("* TODO ") or lines[i].startsWith("* DONE "):
      var entry: LedgerItem = (label: lines[i][7..^1].strip, file: "", line: 1, branch: "", rev: "",
        done: lines[i].startsWith("* DONE "))
      var j = i + 1
      while j < lines.len and not lines[j].startsWith("* "):
        let s = lines[j].strip
        if s.startsWith(":FILE:"): entry.file = s[6..^1].strip
        elif s.startsWith(":LINE:"): entry.line = max(1, try: parseInt(s[6..^1].strip) except ValueError: 1)
        elif s.startsWith(":BRANCH:"): entry.branch = s[8..^1].strip
        elif s.startsWith(":REV:"): entry.rev = s[5..^1].strip
        inc j
      if entry.file.len > 0: result.add entry
      i = j
    else: inc i

iterator entrySpans(text: string): tuple[first, last: int] =
  ## Byte ranges bounded by top-level Org headings, preserving line endings.
  var first = -1
  var offset = 0
  for l in text.splitLines(keepEol = true):
    if l.startsWith("* "):
      if first >= 0: yield (first, offset)
      first = offset
    offset += l.len
  if first >= 0: yield (first, text.len)

proc markDone*(text: string, file: string, line: int, explanation: string): string =
  ## Repay the first matching TODO, leaving all other bytes intact.
  for (first, last) in entrySpans(text):
    let body = text[first..<last]
    let items = entries(body)
    if items.len == 0 or items[0].done or items[0].file != file or items[0].line != line: continue
    let newline = body.find('\n')
    let headingEnd = if newline < 0: body.len else: newline
    let heading = body[0..<headingEnd]
    let eol = if heading.endsWith("\r"): "\r\n" else: "\n"
    result = text[0..<first] & "* DONE " & heading[7..^1]
      .replace("taken without explanation", "understood")
      .replace("not yet understood", "understood")
      .replace(":debt:", ":understood:") & body[headingEnd..^1]
    if explanation.len > 0:
      if not result.endsWith("\n"): result.add eol
      result.add explanation
      if not explanation.endsWith("\n"): result.add eol
    result.add text[last..^1]
    return
  result = text

proc debtNear*(text, file: string, line: int): int =
  ## Index in entries(); equal distances prefer the first recorded debt.
  result = -1
  var distance = high(int)
  for i, e in entries(text):
    if e.done or e.file != file: continue
    let d = abs(e.line - line)
    if result < 0 or d < distance:
      result = i
      distance = d

proc entryHunk*(text: string, index: int): string =
  ## The diff block contents for an index in entries().
  var i = 0
  for (first, last) in entrySpans(text):
    let body = text[first..<last]
    if entries(body).len == 0: continue
    if i == index:
      var inDiff = false
      for l in body.splitLines(keepEol = true):
        if l.strip == "#+end_src": inDiff = false
        if inDiff: result.add l
        if l.strip == "#+begin_src diff": inDiff = true
      return
    inc i

proc debtEntries*(text: string, branch = ""): seq[tuple[label, file: string, line: int]] =
  ## The TODO (debt) entries, those of one branch when given ("" = all).
  for e in entries(text):
    if not e.done and (branch.len == 0 or e.branch == branch): result.add (e.label, e.file, e.line)

proc understoodRevs*(text, branch: string): seq[tuple[file, rev: string]] =
  ## For branch debt: the (file, rev) pairs this branch's entries attest to: a DONE
  ## entry and no TODO one left at that revision (a TODO flipped to DONE in the Org
  ## file counts as repaid).
  var todos: seq[tuple[file, rev: string]]
  for e in entries(text):
    if e.branch != branch or e.rev.len == 0: continue
    if e.done:
      if (e.file, e.rev) notin result: result.add (e.file, e.rev)
    else: todos.add (e.file, e.rev)
  for t in todos:
    let i = result.find(t)
    if i >= 0: result.delete(i)

proc debtCount*(text: string): tuple[debt, understood: int] =
  ## How many entries of each kind the ledger text holds.
  for l in text.splitLines:
    if l.startsWith("* TODO "): inc result.debt
    elif l.startsWith("* DONE "): inc result.understood

proc loadBases*(path: string): seq[tuple[root, base: string]] =
  ## The base branch chosen for each repository, one `root<TAB>base` per line.
  var text: string
  try: text = readFile(path)
  except CatchableError: return
  for l in text.splitLines:
    let parts = l.split('\t')
    if parts.len == 2 and parts[0].len > 0 and parts[1].len > 0: result.add (parts[0], parts[1])

proc baseFor*(bases: seq[tuple[root, base: string]], root: string): string =
  for (r, b) in bases:
    if r == root: return b

proc rememberBase*(path, root, base: string) =
  var bases = loadBases(path).filterIt(it.root != root)
  bases.insert((root, base), 0)
  if bases.len > 100: bases.setLen(100)
  try: writeFile(path, bases.mapIt(it.root & "\t" & it.base).join("\n") & "\n")
  except CatchableError: discard

proc glossaryTerms*(explanation: string): seq[tuple[term, definition: string]] =
  ## `- term :: definition` lines of an explanation, as Org description items.
  for l in explanation.splitLines:
    let s = l.strip
    if s.startsWith("- ") and " :: " in s:
      let i = s.find(" :: ")
      let term = s[2..<i].strip
      let definition = s[i+4..^1].strip
      if term.len > 0 and definition.len > 0: result.add (term, definition)

proc mergeGlossary*(text: string, terms: seq[tuple[term, definition: string]]): string =
  ## The glossary file with new terms appended as `- term :: definition`; a term already
  ## there (case-insensitive) is left as it was.
  result = if text.len > 0: text else: "#+title: Glossary\n\n"
  if not result.endsWith("\n"): result.add "\n"
  var known: seq[string]
  for (term, _) in glossaryTerms(result): known.add term.toLowerAscii
  for (term, definition) in terms:
    if term.toLowerAscii in known: continue
    known.add term.toLowerAscii
    result.add "- " & term & " :: " & definition & "\n"
