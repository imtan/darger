## The understanding ledger: hunks taken in a review, as Org entries in one file.
## A hunk taken without asking for an explanation is a TODO (understanding debt);
## one taken after the explanation is DONE with the explanation under it, so the
## user's Org tools (agenda, TODO keywords) track what is still to be understood.
import std/[strutils, times, os]

type LedgerEntry* = object
  file*: string         ## the file the hunk changed
  line*: int            ## 1-based line in the file after the change
  project*: string      ## the project's directory name, as a tag
  source*: string       ## "Agent", "file on disk", ...
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
  result = "* " & keyword & " " & name & ":" & $e.line & "  " & (if e.explanation.len > 0: "understood" else: "taken without explanation") &
    "  :" & (if e.explanation.len > 0: "understood" else: "debt") & ":" & tagOf(e.project) & ":\n"
  result.add ":PROPERTIES:\n:FILE:     " & e.file & "\n:LINE:     " & $e.line & "\n:SOURCE:   " & e.source &
    "\n:DATE:     " & e.at.format("yyyy-MM-dd HH:mm") & "\n:END:\n"
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

proc debtEntries*(text: string): seq[tuple[label, file: string, line: int]] =
  ## The TODO (debt) entries: heading text, and the FILE / LINE properties under it.
  var i = 0
  let lines = text.splitLines
  while i < lines.len:
    if lines[i].startsWith("* TODO "):
      var entry = (label: lines[i][7..^1].strip, file: "", line: 1)
      var j = i + 1
      while j < lines.len and not lines[j].startsWith("* "):
        let s = lines[j].strip
        if s.startsWith(":FILE:"): entry.file = s[6..^1].strip
        elif s.startsWith(":LINE:"): entry.line = max(1, try: parseInt(s[6..^1].strip) except ValueError: 1)
        inc j
      if entry.file.len > 0: result.add entry
      i = j
    else: inc i

proc debtCount*(text: string): tuple[debt, understood: int] =
  ## How many entries of each kind the ledger text holds.
  for l in text.splitLines:
    if l.startsWith("* TODO "): inc result.debt
    elif l.startsWith("* DONE "): inc result.understood

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
