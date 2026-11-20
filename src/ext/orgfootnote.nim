## Org footnote commands, using the shared xref, consult and keyboard hover UI.
import std/[unicode, strutils, options, tables]
import ../[core, buffer, buffers, lisp, lsp, orgmode, orgfootnote, render]
import org, langserver

var
  labelSource: Buffer
  labelPoint: Point
  labelVersion: int
  labelSection: string

proc canInsert(): bool =
  ## Not on a definition line, and not inside an existing marker (right before or after
  ## one is fine, as in Emacs).
  for note in footnotesOnLine(b.lines[b.cursor.line], b.cursor.line):
    if note.kind == fnDefinition:
      echoLine = "Cannot insert a footnote on a definition line"
      return false
    if b.cursor.col > note.col and b.cursor.col < note.endCol:
      echoLine = "Already on a footnote"
      return false
  true

proc insertLabel(buf: Buffer, at: Point, label, section: string) =
  ## Both insertions are a single undo step, with point ready for the definition body.
  let inserted = insertFootnote(buf.lines, at, label, section)
  buf.snapshot()
  buf.splice(0, buf.text.runeLen, orgText(inserted.lines))
  buf.cursor = inserted.body
  buf.last = "edit"
  if revealHook != nil: revealHook(buf, buf.cursor.line)
  echoLine = "Footnote [fn:" & label & "]"

definePrompt(Prompt(kind: "footnote-label", text: true, onAccept: proc(value: string): bool =
  if labelSource notin reg or labelSource.version != labelVersion:
    echoLine = "Buffer changed; run the footnote command again"
    return true
  if not validFootnoteLabel(value):
    echoLine = "Invalid footnote label"
    return false
  if footnoteLabelUsed(labelSource.lines, value):
    echoLine = "Footnote label already used: " & value
    return false
  insertLabel(labelSource, labelPoint, value, labelSection)
  true))

proc footnoteInsert() =
  ## Insert an automatic label or ask for a valid unused label.
  if not canInsert(): return
  let setting = interp.env.values["org-footnote-section"]
  let section = if setting.kind == vNil: "" else: setting.asString
  let autoLabel = interp.env.values["org-footnote-auto-label"]
  if autoLabel.kind == vNil:
    labelSource = b
    labelPoint = b.cursor
    labelVersion = b.version
    labelSection = section
    beginMini("footnote-label", "Footnote label: ")
  else:
    let prefix = if autoLabel.kind == vTrue: "" else: autoLabel.asString
    let label = newFootnoteLabel(b.lines, prefix)
    if not validFootnoteLabel(label): echoLine = "Invalid footnote label prefix"
    else: insertLabel(b, b.cursor, label, section)

proc definition(label: string): tuple[found: bool, point: Point, text: string] =
  ## Resolve separate and named inline definitions, preferring the first in file order.
  for def in footnoteDefinitions(b.lines):
    if def.label == label:
      result = (true, (def.line, def.bodyCol), definitionBody(b.lines, def))
      break
  for note in footnoteReferences(b.lines):
    if note.kind == fnInline and note.label == label and
        (not result.found or note.line < result.point.line):
      return (true, (note.line, note.col + 5 + label.runeLen), note.text)

proc footnoteJump() =
  ## Jump between a reference and definition, recording the origin for M-,.
  let found = footnoteAt(b.lines, b.cursor.line, b.cursor.col)
  if found.isNone:
    echoLine = "No footnote at point"
    return
  let note = found.get
  var dest: Point
  case note.kind
  of fnInline:
    echoLine = "Inline footnote has no separate definition"
    return
  of fnReference:
    let def = definition(note.label)
    if not def.found:
      echoLine = "No definition for [fn:" & note.label & "]"
      return
    dest = def.point
  of fnDefinition:
    var refs: seq[Footnote]
    for refNote in footnoteReferences(b.lines):
      if refNote.label == note.label: refs.add refNote
    if refs.len == 0:
      echoLine = "No reference to [fn:" & note.label & "]"
      return
    dest = (refs[0].line, refs[0].col)
  pushXref(b, b.cursor, renderer.top, renderer.left)
  b.cursor = dest
  if revealHook != nil: revealHook(b, dest.line)

proc footnotePreview() =
  ## Show the body in the existing scrollable keyboard hover box.
  let found = footnoteAt(b.lines, b.cursor.line, b.cursor.col)
  if found.isNone:
    echoLine = "No footnote at point"
    return
  let note = found.get
  var text = note.text
  if note.kind != fnInline:
    let def = definition(note.label)
    if not def.found:
      echoLine = "No definition for [fn:" & note.label & "]"
      return
    text = "[fn:" & note.label & "] (" & $footnoteNumber(b.lines, note.label) & ")\n" & def.text
  hoverText = @[]
  for line in text.split('\n'):
    hoverText.add wrapCells(line, clamp(renderer.cols - 2, 10, 60))
  hoverTop = 0
  hoverActive = true
  hoverBuf = b

definePrompt(Prompt(kind: "footnote-check", text: true, consult: true,
  candidates: refRowsNow, onAccept: acceptReference))

interp.defPrimitive("org-footnote-insert", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if orgBuffer(): footnoteInsert()
  nilValue())
interp.defPrimitive("org-footnote-jump", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if orgBuffer(): footnoteJump()
  nilValue())
interp.defPrimitive("org-footnote-action", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if orgBuffer():
    if footnoteAt(b.lines, b.cursor.line, b.cursor.col).isSome: footnoteJump()
    else: footnoteInsert()
  nilValue())
interp.defPrimitive("org-footnote-preview", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if orgBuffer(): footnotePreview()
  nilValue())
interp.defPrimitive("org-footnote-check", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if orgBuffer():
    let issues = footnoteIssues(b.lines)
    if issues.len == 0:
      echoLine = "Footnotes OK: " & $footnoteReferences(b.lines).len & " references, " &
        $footnoteDefinitions(b.lines).len & " definitions"
    else:
      targets = @[]
      refRows = @[]
      for issue in issues:
        targets.add Location(line: issue.line, col: issue.col)
        let number = footnoteNumber(b.lines, issue.label)
        refRows.add $(issue.line + 1) & ": " & issue.message &
          (if number > 0: " (" & $number & ")" else: "")
      beginMini("footnote-check", "Footnote: ")
  nilValue())

defaults.add """
(setq org-footnote-section "Footnotes")
(setq org-footnote-auto-label t)
(global-set-key "C-c C-x f" 'org-footnote-action)
"""
