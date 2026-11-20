## Org footnotes over rune lines, independent of the editor and its UI.
import std/[unicode, options, sets, tables, algorithm]
import orgmode

type
  FootnoteKind* = enum fnReference, fnInline, fnDefinition
  Footnote* = object
    kind*: FootnoteKind
    label*, text*: string
    line*, col*, endCol*: int  ## endCol is exclusive
  FootnoteDefinition* = object
    label*: string
    line*, bodyCol*, lastLine*: int
  FootnoteIssueKind* = enum fiUndefined, fiUnreferenced, fiDuplicate, fiMalformed
  FootnoteIssue* = object
    kind*: FootnoteIssueKind
    line*, col*: int
    label*, message*: string

proc labelRune(r: Rune): bool =
  # unicode provides letters but no decimal-digit predicate; each block has ten digits.
  if r.isAlpha or r == Rune('-') or r == Rune('_'): return true
  for first in [0x30, 0x660, 0x6F0, 0x7C0, 0x966, 0x9E6, 0xA66, 0xAE6,
      0xB66, 0xBE6, 0xC66, 0xCE6, 0xD66, 0xDE6, 0xE50, 0xED0, 0xF20,
      0x1040, 0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80, 0x1A90,
      0x1B50, 0x1BB0, 0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900, 0xA9D0,
      0xA9F0, 0xAA50, 0xABF0, 0xFF10, 0x104A0, 0x10D30, 0x10D40,
      0x11066, 0x110F0, 0x11136, 0x111D0, 0x112F0, 0x11450, 0x114D0,
      0x11650, 0x116C0, 0x116D0, 0x116DA, 0x11730, 0x118E0, 0x11950,
      0x11BF0, 0x11C50, 0x11D50, 0x11DA0, 0x11F50, 0x16130, 0x16A60,
      0x16AC0, 0x16B50, 0x1D7CE, 0x1D7D8, 0x1D7E2, 0x1D7EC, 0x1D7F6,
      0x1E140, 0x1E2F0, 0x1E4F0, 0x1E5F1, 0x1E950, 0x1FBF0]:
    if int(r) in first..first+9: return true

proc validFootnoteLabel*(label: string): bool =
  ## A nonempty sequence of Unicode letters/digits, hyphens and underscores.
  if label.len == 0: return false
  for r in label.runes:
    if not labelRune(r): return false
  true

proc scanLine(line: seq[Rune], n: int): tuple[notes: seq[Footnote], issues: seq[FootnoteIssue]] =
  var i = 0
  while i + 3 < line.len:
    if line[i] != Rune('[') or line[i+1] != Rune('f') or
        line[i+2] != Rune('n') or line[i+3] != Rune(':'):
      inc i
      continue
    var z = i + 4
    var depth = 1
    while z < line.len:
      if line[z] == Rune('['): inc depth
      elif line[z] == Rune(']'): dec depth
      inc z
      if depth == 0: break
    var sep = i + 4
    while sep < z and labelRune(line[sep]): inc sep
    let label = $line[i+4..<sep]
    let inlineNote = sep < z and line[sep] == Rune(':')
    if depth != 0 or not (inlineNote or
        (label.len > 0 and sep == z - 1 and line[sep] == Rune(']'))):
      result.issues.add FootnoteIssue(kind: fiMalformed, line: n, col: i, label: label,
        message: "malformed footnote " & $line[i..<min(z, i + 40)])
    else:
      # As org-footnote-definition-re: a labelled marker at column 0 starts a definition,
      # whatever follows it; an inline note never does.
      let kind = if inlineNote: fnInline elif i == 0: fnDefinition else: fnReference
      result.notes.add Footnote(kind: kind, label: label, line: n, col: i, endCol: z,
        text: if inlineNote: $line[sep+1..<z-1] else: "")
    i = z

proc footnotesOnLine*(line: seq[Rune], n: int): seq[Footnote] =
  ## All valid markers, including the definition marker at column zero.
  scanLine(line, n).notes

proc blank(line: seq[Rune]): bool =
  for r in line:
    if not r.isWhiteSpace: return false
  true

proc footnoteDefinitions*(lines: seq[seq[Rune]]): seq[FootnoteDefinition] =
  ## Separate definitions, ending before another definition, headline or two blank lines.
  var markers = initTable[int, Footnote]()
  for n, line in lines:
    let notes = footnotesOnLine(line, n)
    if notes.len > 0 and notes[0].kind == fnDefinition: markers[n] = notes[0]
  for n in 0..<lines.len:
    if n notin markers: continue
    let note = markers[n]
    var last = n
    for j in n+1..<lines.len:
      if j in markers or isHeadline(lines[j]): break
      if blank(lines[j]) and j + 1 < lines.len and blank(lines[j+1]): break
      last = j
    while last > n and blank(lines[last]): dec last
    var body = note.endCol  # the body starts after the blanks following the marker
    while body < lines[n].len and lines[n][body] in [Rune(' '), Rune('\t')]: inc body
    result.add FootnoteDefinition(label: note.label, line: n, bodyCol: body, lastLine: last)

proc footnoteReferences*(lines: seq[seq[Rune]]): seq[Footnote] =
  ## References and inline definitions in document order, excluding separate markers.
  for n, line in lines:
    for note in footnotesOnLine(line, n):
      if note.kind != fnDefinition: result.add note

proc footnoteAt*(lines: seq[seq[Rune]], line, col: int): Option[Footnote] =
  ## The marker containing point, from its '[' to just after its ']' (as org-in-regexp
  ## counts both ends), or none.
  if line notin 0..<lines.len: return
  for note in footnotesOnLine(lines[line], line):
    if col >= note.col and col <= note.endCol: return some(note)

proc definitionBody*(lines: seq[seq[Rune]], def: FootnoteDefinition): string =
  ## The body's text with continuation lines and without trailing blank lines.
  result = $lines[def.line][def.bodyCol..^1]
  if def.lastLine == def.line and blank(result.toRunes): return ""
  for n in def.line+1..def.lastLine: result.add "\n" & $lines[n]

proc footnoteLabelUsed*(lines: seq[seq[Rune]], label: string): bool =
  ## Whether a reference, inline note or separate definition already uses this label.
  for n, line in lines:
    for note in footnotesOnLine(line, n):
      if note.label == label: return true

proc newFootnoteLabel*(lines: seq[seq[Rune]], prefix = ""): string =
  ## The smallest unused positive number with the supplied prefix; never renumber labels.
  var used = initHashSet[string]()
  for n, line in lines:
    for note in footnotesOnLine(line, n): used.incl note.label
  var number = 1
  while prefix & $number in used: inc number
  prefix & $number

proc insertFootnote*(lines: seq[seq[Rune]], at: tuple[line, col: int], label, section: string):
    tuple[lines: seq[seq[Rune]], reference, body: tuple[line, col: int]] =
  ## Insert a reference and an empty definition, preserving the original final newline.
  result.lines = lines
  let marker = ("[fn:" & label & "]").toRunes
  let line = lines[at.line]
  result.lines[at.line] = line[0..<at.col] & marker & line[at.col..^1]
  result.reference = (at.line, at.col + marker.len)
  let finalNewline = lines.len > 1 and lines[^1].len == 0
  if result.lines.len > 1 and result.lines[^1].len == 0:
    result.lines.setLen(result.lines.len - 1)
  var pos = result.lines.len
  if section.len > 0:
    var head = -1
    for n, l in result.lines:
      if isHeadline(l) and headline(l).title == section:
        head = n
        break
    if head >= 0:
      pos = subtreeEnd(result.lines, head) + 1
      while pos > head + 1 and blank(result.lines[pos-1]): dec pos  # before the section's trailing blanks
    else:
      if result.lines.len > 0 and not blank(result.lines[^1]): result.lines.add @[]
      result.lines.add ("* " & section).toRunes
      pos = result.lines.len
  else:
    let defs = footnoteDefinitions(result.lines)
    if defs.len > 0: pos = defs[^1].lastLine + 1
  var added: seq[seq[Rune]]
  if pos > 0 and not blank(result.lines[pos-1]): added.add @[]
  result.body = (pos + added.len, marker.len + 1)
  added.add marker & @[Rune(' ')]
  if pos < result.lines.len and not blank(result.lines[pos]): added.add @[]
  if result.reference.line >= pos: result.reference.line += added.len
  result.lines = result.lines[0..<pos] & added & result.lines[pos..^1]
  if finalNewline: result.lines.add @[]

proc footnoteNumber*(lines: seq[seq[Rune]], label: string): int =
  ## Display order of first reference; anonymous inline notes each occupy one number.
  if label.len == 0: return 0
  var seen = initHashSet[string]()
  var number = 0
  for note in footnoteReferences(lines):
    if note.label.len == 0 or note.label notin seen:
      inc number
      if note.label == label: return number
      seen.incl note.label

proc footnoteIssues*(lines: seq[seq[Rune]]): seq[FootnoteIssue] =
  ## Undefined references, unused/duplicate definitions and malformed markers, in file order.
  var refs, defs: seq[Footnote]
  var used, defined: HashSet[string]
  for n, line in lines:
    let scan = scanLine(line, n)
    result.add scan.issues
    for note in scan.notes:
      if note.kind != fnDefinition:
        refs.add note
        if note.label.len > 0: used.incl note.label
      if note.kind != fnReference and note.label.len > 0:
        defs.add note
        defined.incl note.label
  for note in refs:
    if note.kind == fnReference and note.label notin defined:
      result.add FootnoteIssue(kind: fiUndefined, line: note.line, col: note.col,
        label: note.label, message: "undefined reference [fn:" & note.label & "]")
  var seen = initHashSet[string]()
  for note in defs:
    if note.label in seen:
      result.add FootnoteIssue(kind: fiDuplicate, line: note.line, col: note.col,
        label: note.label, message: "duplicate definition [fn:" & note.label & "]")
    elif note.label notin used:
      result.add FootnoteIssue(kind: fiUnreferenced, line: note.line, col: note.col,
        label: note.label, message: "unreferenced definition [fn:" & note.label & "]")
    seen.incl note.label
  result.sort(proc(a, b: FootnoteIssue): int =
    result = cmp(a.line, b.line)
    if result == 0: result = cmp(a.col, b.col))
