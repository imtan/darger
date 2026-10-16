## Org mode and org-roam: structure editing on Org buffers and a directory of notes
## linked by id. Built on orgmode.nim (parsing) and roam.nim (the notes).
import std/[os, strutils, unicode, times, tables, browsers]
import ../[core, buffer, buffers, lisp, lsp, orgmode, roam]
when defined(macosx): import ../macwin

var
  roamList*: seq[RoamNode]         # the nodes a roam prompt lists
  roamRows*: seq[string]           # their titles, the prompt's candidates
  roamRegion*: tuple[a, z: int]    # org-roam-node-insert: the region the link replaces

proc orgBuffer*(): bool =
  result = lang.name == "Org"
  if not result: echoLine = "Not an Org buffer"

proc setLine*(n: int, s: string) =
  ## Replaces line n as one undo step, keeping the cursor where it was.
  let cur = b.cursor
  b.snapshot()
  let a = b.offset((n, 0))
  b.splice(a, a + b.lines[n].len, s)
  b.cursor = (cur.line, min(cur.col, b.lines[cur.line].len))
  b.last = "edit"

proc orgHeadline*(): int =
  ## The headline at or above the cursor; -1, with a message, before the first.
  result = headlineAbove(b.lines, b.cursor.line)
  if result < 0: echoLine = "Before first headline"

proc swapBlocks*(a1, z1, z2: int) =
  ## Exchanges lines a1..z1 with z1+1..z2, moving the cursor with its line.
  let cur = b.cursor
  b.snapshot()
  var text: seq[string]
  for i in z1+1..z2: text.add $b.lines[i]
  for i in a1..z1: text.add $b.lines[i]
  b.splice(b.offset((a1, 0)), b.offset((z2, b.lines[z2].len)), text.join("\n"))
  b.cursor = (cur.line + (if cur.line <= z1: z2 - z1 else: a1 - z1 - 1), cur.col)
  b.last = "edit"

proc shiftHeadline*(delta: int) =
  if not orgBuffer(): return
  let n = orgHeadline()
  if n < 0: return
  let shifted = shiftLevel(b.lines[n], delta)
  if shifted == b.lines[n]: echoLine = "Cannot promote a top-level headline"
  else: setLine(n, $shifted)

proc moveSubtree*(down: bool) =
  if not orgBuffer(): return
  let n = orgHeadline()
  if n < 0: return
  let level = headline(b.lines[n]).level
  let z = subtreeEnd(b.lines, n)
  if down:
    let next = z + 1
    if next > b.lines.high or headline(b.lines[next]).level != level:
      echoLine = "Cannot move past the last sibling"
      return
    swapBlocks(n, z, subtreeEnd(b.lines, next))
  else:
    var prev = n - 1
    while prev >= 0 and (not isHeadline(b.lines[prev]) or headline(b.lines[prev]).level > level): dec prev
    if prev < 0 or headline(b.lines[prev]).level != level:
      echoLine = "Cannot move past the first sibling"
      return
    swapBlocks(prev, n - 1, z)

# ---- Folding: per buffer, the folded headlines; core asks which lines they hide
type FoldState = object
  folds: seq[Fold]
  version, lineCount: int  # the buffer state folds were last matched against
  map: seq[int8]
  global: string           # the last org-shifttab state, to cycle from

var folded: Table[Buffer, FoldState]

proc foldMapOf(buf: Buffer): seq[int8] =
  if buf notin folded: return
  let s = addr folded[buf]
  if s.folds.len == 0: return
  if s.version != buf.version:
    # An edit: find the headlines again (moved by the change in line count, or edited).
    s.folds = remapFolds(s.folds, buf.lines, buf.lines.len - s.lineCount)
    s.version = buf.version
    s.lineCount = buf.lines.len
    s.map = foldMap(buf.lines, s.folds)
  s.map

proc setFolds(buf: Buffer, folds: seq[Fold]) =
  folded[buf] = FoldState(folds: folds, version: buf.version, lineCount: buf.lines.len,
    map: foldMap(buf.lines, folds), global: folded.getOrDefault(buf).global)

proc foldsOf(buf: Buffer): seq[Fold] =
  discard foldMapOf(buf)  # brings them up to date with the text
  folded.getOrDefault(buf).folds

proc leaveHidden() =
  ## After a global fold the cursor may sit in hidden text: it goes to the headline above.
  let map = foldMapOf(b)
  if not hiddenLine(map, b.cursor.line): return
  let n = shownLine(map, b.lines.len, b.cursor.line, -1)
  if n >= 0: b.cursor = (n, min(b.cursor.col, b.lines[n].len))

proc orgCycle*() =
  ## TAB on a headline: FOLDED -> CHILDREN -> SUBTREE, as org-cycle.
  let (folds, state) = cycleFold(b.lines, foldsOf(b), b.cursor.line)
  if state.len == 0: return
  setFolds(b, folds)
  echoLine = state

proc orgGlobalCycle*(state = "", quiet = false) =
  ## Shift-TAB: OVERVIEW -> CONTENTS -> SHOW ALL, as org-shifttab; `state` picks one.
  let next = if state.len > 0: state
    else: (case folded.getOrDefault(b).global
      of "OVERVIEW": "CONTENTS"
      of "CONTENTS": "SHOW ALL"
      else: "OVERVIEW")
  setFolds(b, globalFolds(b.lines, next))
  folded[b].global = next
  leaveHidden()
  if not quiet: echoLine = next

foldHook = foldMapOf
revealHook = proc(buf: Buffer, line: int) = setFolds(buf, revealFolds(buf.lines, foldsOf(buf), line))
killHooks.add proc(buf: Buffer) = folded.del buf
visitHooks.add proc() =
  # '#+startup: folded' (or overview / content) opens the file folded, as in Emacs.
  if lang.name == "Org":
    let state = startupState(b.lines)
    if state != "SHOW ALL": orgGlobalCycle(state, quiet = true)  # the echo line keeps its startup message
keyFilters.add proc(c: string): bool =
  # TAB on a headline cycles its fold and Shift-TAB the whole file; elsewhere TAB indents.
  if mode.len > 0 or prefix.len > 0 or lang.name != "Org" or c notin ["tab", "C-i"]: return false
  if shift(): orgGlobalCycle()
  elif isHeadline(b.lines[b.cursor.line]): orgCycle()
  else: return false
  true

proc roamDir*(): string = expandTilde(interp.env.values["org-roam-directory"].asString)

# ---- org-journal and org-capture
proc setting(name: string): string = interp.env.values[name].asString

proc japaneseLocale(): bool =
  ## %A / %B in Japanese, as Emacs' format-time-string gives under a Japanese locale.
  for v in ["LC_ALL", "LC_TIME", "LANG"]:
    let s = getEnv(v)
    if s.len > 0: return s.startsWith("ja")
  when defined(macosx): systemLocale().startsWith("ja")  # apps launched from the Finder have no LANG
  else: false

proc journalNewEntry*() =
  ## C-c j, like org-journal-new-entry: today's file under org-journal-dir (created
  ## with org-journal-file-header and the date headline), then a time headline at
  ## the end with the cursor after it. Before org-extend-today-until o'clock the
  ## entry still belongs to yesterday's file.
  let ja = japaneseLocale()
  let t = now()
  let day = t - hours(parseInt(setting("org-extend-today-until")))
  let dir = expandTilde(setting("org-journal-dir"))
  let path = dir / strftime(setting("org-journal-file-format"), day, ja)
  let dateLine = setting("org-journal-date-prefix") & strftime(setting("org-journal-date-format"), day, ja)
  if not fileExists(path):
    createDir(dir)
    # The day's template (org-journal-daily-template-file) goes under the date headline,
    # as the user's Emacs hook inserts it on the first entry; an ID makes the day a roam node.
    let templatePath = expandTilde(setting("org-journal-daily-template-file"))
    let dayTemplate = if templatePath.len > 0 and fileExists(templatePath): readFile(templatePath) else: ""
    let id = if interp.env.values["org-journal-add-id"].kind != vNil: newId() else: ""
    writeFile(path, newJournalText(strftime(setting("org-journal-file-header"), day, ja), dateLine, dayTemplate, id))
  visit(path)
  var text = b.text
  var hasDate = false
  for l in b.lines:
    if $l == dateLine: hasDate = true
  if not hasDate: text = appendedText(text, dateLine & "\n")
  text = appendedText(text, setting("org-journal-time-prefix") & strftime(setting("org-journal-time-format"), t, ja))
  b.snapshot()
  b.splice(0, b.text.runeLen, text)
  b.cursor = b.point(b.text.runeLen)
  b.last = "edit"

proc captureText*(value: string): bool =
  ## The capture prompt's Enter: the filled template goes under org-capture-headline in
  ## org-capture-file (through its buffer when it is open, else straight to disk).
  if value.len == 0: return false
  let path = expandTilde(setting("org-capture-file"))
  let entry = fillTemplate(setting("org-capture-template"), value, now())
  let open = reg.byPath(path)
  if open != nil:
    let (text, at) = insertUnder(open.text, setting("org-capture-headline"), entry)
    open.snapshot()
    open.splice(0, open.text.runeLen, text)
    open.cursor = open.point(text[0..<at].runeLen)
    open.last = "edit"
    if open.modified: open.save()
  else:
    let text = if fileExists(path): readFile(path) else: ""
    createDir(parentDir(path))
    writeFile(path, insertUnder(text, setting("org-capture-headline"), entry).text)
  echoLine = "Captured to " & shortPath(path)
  true

proc roamNode*(title: string): RoamNode =
  ## The listed node with that title, or a new note file for it.
  let i = roamList.byTitle(title)
  if i >= 0: return roamList[i]
  let dir = roamDir()
  createDir(dir)
  result = RoamNode(id: newId(), title: title, path: newNotePath(dir, title, now()))
  writeFile(result.path, newNoteText(result.id, title))
  echoLine = "Created " & shortPath(result.path)

proc roamPrompt*(kind, label: string) =
  roamList = scanNodes(roamDir())
  roamRows = @[]
  for n in roamList: roamRows.add n.title
  var initial = ""
  roamRegion = (0, 0)
  if kind == "roam-insert" and b.regionActive and b.markSet:
    roamRegion = b.region
    initial = $b.text.toRunes[roamRegion.a ..< roamRegion.z]
  beginMini(kind, label, initial)

proc openLink*(target: string) =
  ## Follows an Org link: id:, file:, a URL (in the system browser), or *Headline.
  let base = if b.path.len > 0: parentDir(b.path) else: getCurrentDir()
  if target.startsWith("id:"):
    let nodes = scanNodes(roamDir())
    let i = nodes.byId(target[3..^1])
    if i < 0: echoLine = "No note with id " & target[3..^1]
    else: visit(nodes[i].path)
  elif target.startsWith("file:"):
    visit(absolutePath(expandTilde(target[5..^1].split("::")[0]), base))
  elif "://" in target or target.startsWith("mailto:"):
    openDefaultBrowser(target)
    echoLine = "Opened in browser"
  elif target.startsWith("*"):
    for n, l in b.lines:
      if isHeadline(l) and headline(l).title == target[1..^1]:
        b.cursor = (n, 0)
        return
    echoLine = "No headline " & target[1..^1]
  else:
    let path = absolutePath(expandTilde(target), base)
    if fileExists(path) or dirExists(path): visit(path)
    else: echoLine = "Cannot open link: " & target

interp.defPrimitive("org-todo", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if orgBuffer():
    let n = orgHeadline()
    if n >= 0: setLine(n, $cycleTodo(b.lines[n]))
  nilValue())
interp.defPrimitive("org-toggle-checkbox", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if orgBuffer():
    let n = b.cursor.line
    let toggled = toggleCheckbox(b.lines[n])
    if toggled == b.lines[n]: echoLine = "No checkbox at point"
    else: setLine(n, $toggled)
  nilValue())
interp.defPrimitive("org-promote", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  shiftHeadline(-1)
  nilValue())
interp.defPrimitive("org-demote", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  shiftHeadline(1)
  nilValue())
interp.defPrimitive("org-move-subtree-up", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  moveSubtree(false)
  nilValue())
interp.defPrimitive("org-move-subtree-down", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  moveSubtree(true)
  nilValue())
interp.defPrimitive("org-meta-return", proc(args: seq[Value]): Value =
  ## A new headline or list item of the same kind below the current line.
  args.arity(0, 0)
  if orgBuffer():
    let start = newItemPrefix(b.lines[b.cursor.line])
    b.cursor.col = b.lines[b.cursor.line].len
    b.insert("\n" & start)
  nilValue())
interp.defPrimitive("org-open-at-point", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let link = linkAt(b.lines[b.cursor.line], b.cursor.col)
  if link.target.len == 0: echoLine = "No link at point"
  else: openLink(link.target)
  nilValue())
interp.defPrimitive("org-time-stamp", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  b.insert(timestamp(now()))
  nilValue())
interp.defPrimitive("org-journal-new-entry", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  journalNewEntry()
  nilValue())
interp.defPrimitive("org-capture", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  beginMini("capture", "Capture: ")
  nilValue())
interp.defPrimitive("org-cycle", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if orgBuffer():
    if isHeadline(b.lines[b.cursor.line]): orgCycle()
    else: echoLine = "Not on a headline"
  nilValue())
interp.defPrimitive("org-shifttab", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if orgBuffer(): orgGlobalCycle()
  nilValue())
interp.defPrimitive("org-goto", proc(args: seq[Value]): Value =
  ## The headlines as a consult list; Enter jumps, C-g returns.
  args.arity(0, 0)
  if orgBuffer():
    let items = outline(b.lines)
    if items.len == 0:
      echoLine = "No headlines"
      return nilValue()
    targets = @[]
    refRows = @[]
    for it in items:
      targets.add Location(line: it.line)
      refRows.add it.text
    beginMini("outline", "Headline: ")
  nilValue())
interp.defPrimitive("org-id-get-create", proc(args: seq[Value]): Value =
  ## Gives the file an ID property drawer at its top, making it an org-roam node.
  args.arity(0, 0)
  let id = property(b.lines, "ID")
  if id.len > 0:
    echoLine = "ID: " & id
    return nilValue()
  let cur = b.cursor
  let fresh = newId()
  b.snapshot()
  b.splice(0, 0, ":PROPERTIES:\n:ID:       " & fresh & "\n:END:\n")
  b.cursor = (cur.line + 3, cur.col)
  b.last = "edit"
  echoLine = "ID: " & fresh
  nilValue())
interp.defPrimitive("org-roam-node-find", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  roamPrompt("roam-find", "Node: ")
  nilValue())
interp.defPrimitive("org-roam-node-insert", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  roamPrompt("roam-insert", "Insert node: ")
  nilValue())
interp.defPrimitive("org-roam-buffer-toggle", proc(args: seq[Value]): Value =
  ## The notes linking to this one, previewed like references.
  args.arity(0, 0)
  let id = property(b.lines, "ID")
  if id.len == 0:
    echoLine = "Not an org-roam node: no ID (M-x org-id-get-create)"
    return nilValue()
  let links = backlinks(scanNodes(roamDir()), id)
  if links.len == 0:
    echoLine = "No backlinks"
    return nilValue()
  targets = @[]
  refRows = @[]
  for l in links:
    targets.add Location(path: l.path, line: l.line)
    refRows.add l.title & "  " & l.text
  beginMini("backlinks", "Backlinks: ")
  nilValue())
interp.defPrimitive("org-roam-dailies-today", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let path = dailyPath(roamDir(), now())
  if not fileExists(path):
    createDir(parentDir(path))
    writeFile(path, newNoteText(newId(), now().format("yyyy-MM-dd")))
  visit(path)
  nilValue())

proc roamRowsNow*(): seq[string] = roamRows
proc acceptRoam*(value: string): bool =
  if value.len == 0: return false
  let node = roamNode(value)
  if mode == "roam-find": visit(node.path)
  elif roamRegion.a < roamRegion.z:
    b.snapshot()
    b.splice(roamRegion.a, roamRegion.z, linkText(node.id, node.title))
    b.last = "edit"
  else: b.insert(linkText(node.id, node.title))
  true
definePrompt(Prompt(kind: "outline", text: true, consult: true, candidates: refRowsNow, onAccept: acceptReference))
definePrompt(Prompt(kind: "backlinks", text: true, consult: true, candidates: refRowsNow, onAccept: acceptReference))
definePrompt(Prompt(kind: "roam-find", text: true, candidates: roamRowsNow, onAccept: acceptRoam))
definePrompt(Prompt(kind: "roam-insert", text: true, candidates: roamRowsNow, onAccept: acceptRoam))
definePrompt(Prompt(kind: "capture", text: true, onAccept: captureText))

defaults.add """
(setq org-roam-directory "~/org-roam")
(setq org-journal-dir "~/org-journal")
(setq org-journal-file-format "%Y%m%d.org")
(setq org-journal-file-header "")
(setq org-journal-date-prefix "* ")
(setq org-journal-date-format "%A, %d %B %Y")
(setq org-journal-time-prefix "** ")
(setq org-journal-time-format "%R ")
(setq org-extend-today-until "0")
(setq org-journal-daily-template-file "")
(setq org-journal-add-id nil)
(setq org-capture-file "~/org/inbox.org")
(setq org-capture-headline "")
(setq org-capture-template "* TODO %?\n")
(global-set-key "C-c j" 'org-journal-new-entry)
(global-set-key "C-c t" 'org-capture)
(global-set-key "C-c C-t" 'org-todo)
(global-set-key "C-c C-c" 'org-toggle-checkbox)
(global-set-key "M-enter" 'org-meta-return)
(global-set-key "M-left" 'org-promote)
(global-set-key "M-right" 'org-demote)
(global-set-key "M-up" 'org-move-subtree-up)
(global-set-key "M-down" 'org-move-subtree-down)
(global-set-key "C-c C-o" 'org-open-at-point)
(global-set-key "C-c ." 'org-time-stamp)
(global-set-key "C-c C-j" 'org-goto)
(global-set-key "C-c n f" 'org-roam-node-find)
(global-set-key "C-c n i" 'org-roam-node-insert)
(global-set-key "C-c n l" 'org-roam-buffer-toggle)
(global-set-key "C-c n d" 'org-roam-dailies-today)
"""
