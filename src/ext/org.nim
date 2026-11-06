## Org mode and org-roam: structure editing on Org buffers and a directory of notes
## linked by id. Built on orgmode.nim (parsing) and roam.nim (the notes).
import std/[os, strutils, unicode, times, tables, browsers, sequtils]
import ../[core, buffer, buffers, lisp, lsp, orgmode, roam, syntax, remote, render]
from pixie import Color, parseHtmlColor, mix
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
  ## %A / %B in Japanese, as Emacs' format-time-string gives under a Japanese locale:
  ## system-time-locale when set ("C" / "en..." English, "ja..." Japanese), else the
  ## process's LC_ALL / LC_TIME / LANG. Without any, English, as Emacs.app launched
  ## from the Finder writes (the system's language is not consulted, as Emacs does not).
  let v = interp.env.values.getOrDefault("system-time-locale")
  if v != nil and v.kind == vString and v.str.len > 0: return v.str.startsWith("ja")
  for name in ["LC_ALL", "LC_TIME", "LANG"]:
    let s = getEnv(name)
    if s.len > 0: return s.startsWith("ja")
  false

var conditionLine = -1  # the journal headline the 体調 prompt is about

proc recordCondition*(n: int) =
  ## 1-5 at the prompt: that many ★ after the new entry's time, the cursor after them.
  if conditionLine notin 0..b.lines.high or conditionMark(n).len == 0: return
  let at = b.offset((conditionLine, b.lines[conditionLine].len))
  b.snapshot()
  b.splice(at, at, conditionMark(n))
  b.cursor = b.point(at + conditionMark(n).runeLen)
  b.last = "edit"

type JournalDay = object
  t, day: DateTime    # now, and the day it belongs to (org-extend-today-until)
  ja, remote: bool
  dir, path, dateLine: string

proc journalDay(): JournalDay =
  ## Today's journal file under org-journal-dir. Before org-extend-today-until o'clock
  ## the entry still belongs to yesterday's file; a /ssh:HOST:path directory works too.
  result.ja = japaneseLocale()
  result.t = now()
  result.day = result.t - hours(parseInt(setting("org-extend-today-until")))
  result.dir = expandTilde(setting("org-journal-dir"))
  result.remote = isRemote(result.dir)
  let name = strftime(setting("org-journal-file-format"), result.day, result.ja)
  result.path = if result.remote: remoteJoin(result.dir, name) else: result.dir / name
  result.dateLine = setting("org-journal-date-prefix") & strftime(setting("org-journal-date-format"), result.day, result.ja)

proc journalFirstText(j: JournalDay): string =
  ## A new day's file: org-journal-file-header, the date headline, then the day's template
  ## (org-journal-daily-template-file) under it, as the user's Emacs hook inserts it on the
  ## first entry; an ID makes the day a roam node.
  let templatePath = expandTilde(setting("org-journal-daily-template-file"))
  let dayTemplate =
    if templatePath.len == 0: ""
    elif isRemote(templatePath): remoteLoad(templatePath).text
    elif fileExists(templatePath): readFile(templatePath)
    else: ""
  let id = if interp.env.values["org-journal-add-id"].kind != vNil: newId() else: ""
  newJournalText(strftime(setting("org-journal-file-header"), j.day, j.ja), j.dateLine, dayTemplate, id)

proc journalNewEntry*() =
  ## C-c j, like org-journal-new-entry: today's file under org-journal-dir (created
  ## with org-journal-file-header and the date headline), then a time headline at
  ## the end with the cursor after it. A remote day's file is read, created (mkdir -p
  ## first) and saved over SSH.
  let j = journalDay()
  var firstText = ""  # a new file's contents; a local file gets it on disk before the visit
  if not pathStatus(j.path).exists:
    firstText = journalFirstText(j)
    ensureDirectory(j.dir)
    if not j.remote: writeFile(j.path, firstText)
  visit(j.path)
  if j.remote and firstText.len > 0 and b.text.len == 0:
    # The remote file is new: its first text is saved now, as the local one was written.
    b.snapshot()
    b.splice(0, 0, firstText)
    b.save()
  var text = withDateLine(withHeader(b.text, strftime(setting("org-journal-file-header"), j.day, j.ja)), j.dateLine)
  text = appendedText(text, setting("org-journal-time-prefix") & strftime(setting("org-journal-time-format"), j.t, j.ja))
  b.snapshot()
  b.splice(0, b.text.runeLen, text)
  b.cursor = b.point(b.text.runeLen)
  b.last = "edit"
  if interp.env.values["org-journal-condition-prompt"].kind != vNil:
    # The user's Emacs hook asks for the day's condition right after the entry.
    conditionLine = headlineAbove(b.lines, b.cursor.line)
    if conditionLine >= 0: beginMini("journal-condition", "体調 [1-5] (他のキーでスキップ): ")

proc replaceKeeping(buf: Buffer, text: string) =
  ## buf's text becomes text by splicing only the part that differs, so its cursor and
  ## mark stay on the text they were on.
  let old = buf.text.toRunes
  let fresh = text.toRunes
  var a = 0
  while a < old.len and a < fresh.len and old[a] == fresh[a]: inc a
  var z = 0
  while z < old.len - a and z < fresh.len - a and old[^(z+1)] == fresh[^(z+1)]: inc z
  let at = buf.offset(buf.cursor)
  buf.splice(a, old.len - z, $fresh[a ..< fresh.len - z])
  buf.cursor = buf.point(if at <= a: at elif at >= old.len - z: at + fresh.len - old.len
                         else: fresh.len - z)

proc journalQuickAdd*(entry: string): bool =
  ## org-journal-quick-add: one line for today's journal without leaving the buffer, as
  ## yuruorg's 日報クイック追記. The day and file are C-c j's; the entry is the time
  ## headline and the text, under org-journal-quick-add-headline (the end when "").
  ## An open buffer of the file is edited (one undo step) and saved; else the file is.
  if unicode.strip(entry).len == 0: return true
  let j = journalDay()
  let timeFormat = setting("org-journal-time-format")
  let stamp = setting("org-journal-time-prefix") &
    strutils.strip(strftime(timeFormat, j.t, j.ja), leading = false)
  var buf = reg.byPath(j.path)
  let open = buf != nil
  var base = ""
  if open: base = buf.text
  elif pathStatus(j.path).exists:
    buf = loadBuffer(j.path)
    base = buf.text
  else:
    ensureDirectory(j.dir)
    buf = newBuffer()
    buf.path = if j.remote: j.path else: absolutePath(j.path)
    base = journalFirstText(j)
  let header = strftime(setting("org-journal-file-header"), j.day, j.ja)
  let text = appendQuickEntry(withDateLine(withHeader(base, header), j.dateLine),
    setting("org-journal-quick-add-headline"), quickEntry(stamp, entry, timeFormat.endsWith("\n")))
  if open:
    buf.snapshot()
    replaceKeeping(buf, text)
    buf.last = "edit"
  else: buf.splice(0, buf.text.runeLen, text)
  buf.save()
  echoLine = "Journal: added to " & shortPath(j.path)
  true


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

var todoSpec = ""      # org-todo-keywords as last applied
var todoLine = -1      # the headline the fast-selection prompt is about

proc syncTodoKeywords() =
  ## org-todo-keywords, a list of "WORD(k)" and "|", drives cycling, faces and the agenda.
  let v = interp.env.values["org-todo-keywords"]
  let spec = if v.kind == vNil: @["TODO", "DONE"] else: v.asList.mapIt(it.asString)
  if $spec == todoSpec: return
  todoSpec = $spec
  setTodoKeywords(spec)
  # faces: active words red, yellow, blue, magenta, cyan in turn (the user's NEXT orange,
  # WAITING blue), done words dimmed
  const active = [fAnsi1, fAnsi3, fAnsi4, fAnsi5, fAnsi6, fAnsi2]
  orgTodoFaces = @[]
  var n = 0
  for w in todoKeywords:
    if isDone(w): orgTodoFaces.add (w, fComment)
    else:
      orgTodoFaces.add (w, active[min(n, active.high)])
      inc n
  shownBuf = nil  # highlight again

type ModernCache = object
  version: int
  spec: string
  lines: seq[seq[OrgDecoration]]

var modernCache: Table[Buffer, ModernCache]

proc todoColors(word: string): tuple[fg, bg: Color] =
  result.fg = theme.keyword
  for (keyword, face) in orgTodoFaces:
    if keyword == word: result.fg = faceColor(face, theme.fg)
  var background = ""
  for spec in interp.env.values["org-todo-keyword-faces"].asList:
    let xs = spec.asList
    if xs.len < 2 or xs[0].asString != word: continue
    var face = xs[^1]
    var foreground = ""
    if face.kind == vString: foreground = face.asString
    elif face.kind == vList:
      let props = face.asList
      var i = 0
      while i + 1 < props.len:
        if props[i].str == ":foreground": foreground = props[i+1].asString
        elif props[i].str == ":background": background = props[i+1].asString
        i += 2
    if foreground.len > 0:
      # X11's SteelBlue1 is used in config.org; CSS uses SteelBlue without a suffix.
      if foreground.toLowerAscii == "steelblue1": foreground = "#63b8ff"
      try: result.fg = parseHtmlColor(foreground)
      except CatchableError: discard
  result.bg = mix(theme.bg, result.fg, 0.25)
  if background.len > 0:
    try: result.bg = parseHtmlColor(background)
    except CatchableError: discard

lineDecorators.add proc(buf: Buffer, line, cursorLine: int): seq[TextDecoration] =
  if interp.env.values["org-modern-mode"].kind == vNil or line == cursorLine or
      detect(buf.path, "").name != "Org": return
  if buf notin modernCache or modernCache[buf].version != buf.version or modernCache[buf].spec != todoSpec:
    modernCache[buf] = ModernCache(version: buf.version, spec: todoSpec,
      lines: modernDecorations(buf.lines))
  for span in modernCache[buf].lines[line]:
    var decoration = TextDecoration(first: span.first, last: span.last, text: span.text,
      foreground: (if span.kind == odBlock: theme.comment else: theme.fg))
    if span.kind == odTodo:
      let colors = todoColors(span.keyword)
      decoration.foreground = colors.fg
      decoration.background = colors.bg
      decoration.hasBackground = true
    result.add decoration
killHooks.add proc(buf: Buffer) = modernCache.del buf

interp.defPrimitive("org-toggle-modern", proc(args: seq[Value]): Value =
  args.arity(0, 1)
  let enabled = if args.len == 0: interp.env.values["org-modern-mode"].kind == vNil
    else: args[0].kind != vNil and (args[0].kind != vNumber or args[0].number > 0)
  interp.env.values["org-modern-mode"] = if enabled: Value(kind: vTrue) else: nilValue()
  echoLine = if enabled: "Org modern on" else: "Org modern off"
  nilValue())

proc pickTodo*(key: char) =
  ## A fast-selection key: that keyword on the headline; SPC removes it.
  if todoLine notin 0..b.lines.high: return
  if key == ' ': setLine(todoLine, $withTodo(b.lines[todoLine], ""))
  else:
    for (word, k) in todoKeys:
      if k == key: setLine(todoLine, $withTodo(b.lines[todoLine], word))

tickHooks.add proc(): bool =
  syncTodoKeywords()
  false

interp.defPrimitive("org-todo", proc(args: seq[Value]): Value =
  ## C-c C-t: cycles the keywords, or with selection keys in org-todo-keywords asks for
  ## one key, as Emacs' fast TODO selection does.
  args.arity(0, 0)
  if orgBuffer():
    syncTodoKeywords()
    let n = orgHeadline()
    if n < 0: return nilValue()
    if todoKeys.len == 0: setLine(n, $cycleTodo(b.lines[n]))
    else:
      todoLine = n
      var label = "TODO: "
      for (word, k) in todoKeys: label.add "[" & k & "] " & word & "  "
      beginMini("org-todo", label & "[SPC] none: ")
  nilValue())
var prioritySource: Buffer
var priorityLine, priorityVersion: int

proc pickPriority(key: char): bool =
  if key notin {'a'..'c', 'A'..'C', ' '}: return false
  if prioritySource notin reg or prioritySource.version != priorityVersion:
    echoLine = "Headline changed; run org-priority again"
    return true
  let cur = prioritySource.cursor
  prioritySource.snapshot()
  let at = prioritySource.offset((priorityLine, 0))
  prioritySource.splice(at, at + prioritySource.lines[priorityLine].len,
    $withPriority(prioritySource.lines[priorityLine], if key == ' ': '\0' else: key.toUpperAscii))
  prioritySource.cursor = (cur.line, min(cur.col, prioritySource.lines[cur.line].len))
  prioritySource.last = "edit"
  true

definePrompt(Prompt(kind: "org-priority", onAccept: proc(value: string): bool =
  value.len == 1 and pickPriority(value[0])))
runeFilters.add proc(r: Rune): bool =
  if mode != "org-priority": return false
  if r.int < 128 and pickPriority(char(r.int)):
    mode = ""
    prompt = ""
  true

interp.defPrimitive("org-priority", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if orgBuffer():
    let n = orgHeadline()
    if n >= 0:
      prioritySource = b
      priorityLine = n
      priorityVersion = b.version
      beginMini("org-priority", "Priority: [a] A  [b] B  [c] C  [SPC] none: ")
  nilValue())
for (name, up) in [("org-priority-up", true), ("org-priority-down", false)]:
  closureScope:
    let increase = up
    let command = name
    interp.defPrimitive(name, proc(args: seq[Value]): Value =
      args.arity(0, 0)
      if orgBuffer():
        let n = orgHeadline()
        if n >= 0:
          let next = cyclePriority(b.lines[n], increase, b.last == command)
          setLine(n, $next)
          b.last = command
      nilValue())
keyFilters.add proc(c: string): bool =
  # chord() omits Shift on arrows; route it through the added keymap entries on Org headlines
  # only, so Shift-selection keeps working in the body.
  if mode.len > 0 or prefix.len > 0 or lang.name != "Org" or c notin ["up", "down"] or not shift(): return false
  if not isHeadline(b.lines[b.cursor.line]): return false
  let key = "S-" & c
  if key notin keymap: return false
  discard interp.call(keymap[key], @[])
  true

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
var planningSource: Buffer
var planningVersion, planningLine: int
var planningKey: string

definePrompt(Prompt(kind: "org-planning", text: true, onAccept: proc(value: string): bool =
  if planningSource notin reg or planningSource.version != planningVersion:
    echoLine = "Headline changed; run the planning command again"
    return true
  try:
    let date = readOrgDate(value, now())
    let text = orgText(withPlanning(planningSource.lines, planningLine, planningKey, date))
    planningSource.snapshot()
    replaceKeeping(planningSource, text)
    planningSource.last = "edit"
    echoLine = planningKey & ": " & timestamp(date)
    true
  except CatchableError as e:
    echoLine = e.msg
    false))
for (name, key) in [("org-schedule", "SCHEDULED"), ("org-deadline", "DEADLINE")]:
  closureScope:
    let kind = key
    interp.defPrimitive(name, proc(args: seq[Value]): Value =
      args.arity(0, 0)
      if orgBuffer():
        let n = orgHeadline()
        if n >= 0:
          planningSource = b
          planningVersion = b.version
          planningLine = n
          planningKey = kind
          beginMini("org-planning", kind & " (YYYY-MM-DD, +days, fri; empty=today): ")
      nilValue())

proc archiveHeadings(headings: seq[int]) =
  if headings.len == 0:
    echoLine = "No done tasks to archive"
    return
  if b.path.len == 0:
    echoLine = "Save this buffer to a file before archiving"
    return
  let path = b.path & "_archive"
  try:
    let open = reg.byPath(path)
    let dest = if open != nil: open else: loadBuffer(path)
    let change = archiveTrees(b.lines, dest.lines, headings, b.path, now())
    if open != nil: dest.snapshot()
    replaceKeeping(dest, orgText(change.archive))
    dest.save()
    dest.last = "edit"
    b.snapshot()
    replaceKeeping(b, orgText(change.source))
    b.last = "edit"
    echoLine = "Archived " & $change.count & " subtree(s) to " & shortPath(path)
  except CatchableError as e: echoLine = e.msg

interp.defPrimitive("org-archive-subtree", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if orgBuffer():
    let n = orgHeadline()
    if n >= 0: archiveHeadings(@[n])
  nilValue())
interp.defPrimitive("org-archive-done-tasks", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if orgBuffer():
    syncTodoKeywords()
    archiveHeadings(doneSubtrees(b.lines))
  nilValue())

proc agendaFiles(): seq[string] =
  ## org-agenda-files: a list of paths, or one path, ~ expanded; directories give their .org files.
  let v = interp.env.values["org-agenda-files"]
  let paths = if v.kind == vString: @[v.asString] elif v.kind == vNil: @[] else: v.asList.mapIt(it.asString)
  for p in paths:
    let full = absolutePath(expandTilde(p))
    if dirExists(full):
      for f in walkFiles(full / "*.org"): result.add f
    elif fileExists(full): result.add full

type RefileFile = object
  path, label, text: string
  buf: Buffer
  maxlevel: int

var
  refileSource: Buffer
  refileVersion, refileLine: int
  refileFiles: seq[RefileFile]
  refileRows: seq[string]
  refileChoices: seq[tuple[file, line: int]]
  refilePending: string

proc refileMaxlevel(current: bool): int =
  result = 3
  for spec in interp.env.values["org-refile-targets"].asList:
    let xs = spec.asList
    if xs.len < 3: continue
    if (current and xs[0].kind == vNil) or
        (not current and xs[0].kind == vSymbol and xs[0].str == "org-agenda-files"):
      for i in 1..<xs.len - 1:
        if xs[i].kind == vSymbol and xs[i].str == ":maxlevel":
          let at = if xs[i+1].kind == vSymbol and xs[i+1].str == ".": i+2 else: i+1
          if at < xs.len and xs[at].kind == vNumber: result = max(1, xs[at].number.int)

proc applyRefile(value: string, create = false): bool =
  if refileSource notin reg or refileSource.version != refileVersion:
    echoLine = "Source changed; run org-refile again"
    return true
  var file = -1
  var parent = -1
  let choice = refileRows.find(value)
  if choice >= 0:
    (file, parent) = refileChoices[choice]
  else:
    for i, f in refileFiles:
      if value.startsWith(f.label & "/"):
        file = i
        break
  if file < 0:
    echoLine = "Choose a target file/headline"
    return false
  let f = refileFiles[file]
  try:
    let open = if f.path.len == 0 and f.buf in reg: f.buf else: reg.byPath(f.path)
    let dest = if open != nil: open else: loadBuffer(f.path)
    if dest.text != f.text:
      echoLine = "Target changed; run org-refile again"
      return true
    var lines = dest.lines
    if choice < 0:
      let made = ensureRefileParent(lines, value[f.label.len+1..^1])
      if made.lines != lines and not create:
        refilePending = value
        beginMini("org-refile-confirm", "Create parent " & value & "? (yes/no): ")
        return true
      lines = made.lines
      parent = made.line
      if headline(lines[parent]).level > f.maxlevel:
        echoLine = "Parent exceeds org-refile-targets :maxlevel"
        return false
    let same = dest == refileSource
    # Creating a parent may shift the source's line; resolve that before moving it.
    var n = refileLine
    if same and lines != dest.lines:
      let delta = lines.len - dest.lines.len
      if lines[n] != dest.lines[n]: n += delta
    let moved = refileSubtree(if same: lines else: refileSource.lines, lines, n, parent, same)
    if same:
      dest.snapshot()
      replaceKeeping(dest, orgText(moved.target))
      dest.last = "edit"
    else:
      # Finish writing the destination before removing anything from the source.
      if open != nil: dest.snapshot()
      replaceKeeping(dest, orgText(moved.target))
      if open == nil: dest.save()
      dest.last = "edit"
      refileSource.snapshot()
      replaceKeeping(refileSource, orgText(moved.source))
      refileSource.last = "edit"
    echoLine = "Refiled to " & value
    true
  except CatchableError as e:
    echoLine = e.msg
    false

definePrompt(Prompt(kind: "org-refile", text: true,
  candidates: proc(): seq[string] = refileRows,
  onAccept: proc(value: string): bool = applyRefile(value)))
definePrompt(Prompt(kind: "org-refile-confirm", onAccept: proc(value: string): bool =
  if value.toLowerAscii in ["y", "yes"]: return applyRefile(refilePending, true)
  true))

interp.defPrimitive("org-refile", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if not orgBuffer(): return nilValue()
  let n = orgHeadline()
  if n < 0: return nilValue()
  refileSource = b
  refileVersion = b.version
  refileLine = n
  refileFiles = @[]
  refileRows = @[]
  refileChoices = @[]
  var paths = @[b.path]
  for path in agendaFiles():
    if path notin paths: paths.add path
  for path in paths:
    let buf = if path == b.path: b else: reg.byPath(path)
    let text = if buf != nil: buf.text else: loadBuffer(path).text
    let label = if path.len == 0: "*current*" else: extractFilename(path)
    refileFiles.add RefileFile(path: path, label: label, text: text, buf: buf,
      maxlevel: refileMaxlevel(buf == b))
  for i in 0..<refileFiles.len:
    let label = refileFiles[i].label
    if refileFiles.countIt(it.label == label) > 1:
      for j in 0..<refileFiles.len:
        if refileFiles[j].label == label: refileFiles[j].label = refileFiles[j].path
  for i, f in refileFiles:
    let ts = refileTargets(orgLines(f.text), f.maxlevel)
    for t in ts:
      if f.buf == b and t.line in n..subtreeEnd(b.lines, n): continue
      var row = f.label & "/" & t.path
      if ts.countIt(it.path == t.path) > 1: row.add " [line " & $(t.line+1) & "]"
      refileRows.add row
      refileChoices.add (i, t.line)
  beginMini("org-refile", "Refile to (file/headline): ")
  nilValue())

proc agendaGroups(): seq[AgendaGroup] =
  for spec in interp.env.values["org-super-agenda-groups"].asList:
    var group: AgendaGroup
    let xs = spec.asList
    var i = 0
    while i + 1 < xs.len:
      let key = xs[i].str
      let value = xs[i+1]
      case key
      of ":name": group.name = value.asString
      of ":todo": group.todo = value.asString
      of ":tag": group.tag = value.asString
      of ":priority":
        let p = value.asString
        if p.len == 1 and p[0] in {'A'..'C'}: group.priority = p[0]
      of ":scheduled": group.scheduledToday = value.kind == vSymbol and value.str == "today"
      else: discard
      i += 2
    if group.name.len > 0: result.add group

proc orgAgenda*() =
  ## M-x org-agenda: today's scheduled, deadline and dated items and the undated TODOs
  ## of org-agenda-files, as a list; Enter goes to the headline, C-g comes back.
  syncTodoKeywords()
  var items: seq[AgendaItem]
  for path in agendaFiles():
    let open = reg.byPath(path)
    let lines = if open != nil: open.lines else: loadBuffer(path).lines
    items.add agendaItems(path, lines, now())
  items = agendaOrder(items)
  if items.len == 0:
    echoLine = if agendaFiles().len == 0: "No agenda files (setq org-agenda-files ...)" else: "Agenda is empty"
    return
  targets = @[]
  refRows = @[]
  for section in groupAgenda(items, agendaGroups()):
    for it in section.items:
      targets.add Location(path: it.path, line: it.line)
      refRows.add section.name & " | " & agendaRow(it)
  beginMini("agenda", "Agenda: ")

interp.defPrimitive("org-agenda", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  orgAgenda()
  nilValue())
interp.defPrimitive("org-journal-new-entry", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  journalNewEntry()
  nilValue())
interp.defPrimitive("org-journal-quick-add", proc(args: seq[Value]): Value =
  ## (org-journal-quick-add) asks for the line; (org-journal-quick-add "text") adds it.
  args.arity(0, 1)
  if args.len == 1: discard journalQuickAdd(args[0].asString)
  else: beginMini("journal-quick-add", "Journal: ")
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
# org-roam-capture (C-c n c) and org-roam-tag-add (C-c n t)

var
  captureTitle = ""
  captureTemplates: seq[CaptureTemplate]
  tagRows: seq[string]

proc roamTemplates(): seq[CaptureTemplate] =
  ## org-roam-capture-templates: a list of (key description file head) lists.
  let v = interp.env.values["org-roam-capture-templates"]
  if v.kind == vNil: return @[CaptureTemplate(key: "d", description: "default", head: "#+title: ${title}\n")]
  for item in v.asList:
    let parts = item.asList.mapIt(it.asString)
    if parts.len >= 2:
      result.add CaptureTemplate(key: parts[0], description: parts[1],
        file: (if parts.len > 2: parts[2] else: ""), head: (if parts.len > 3: parts[3] else: ""))

proc captureNote(t: CaptureTemplate) =
  ## The new note from the template, visited with point at its end; an existing file is only visited.
  let id = newId()
  let path = captureNotePath(roamDir(), t, captureTitle, id, now())
  if not fileExists(path):
    createDir(parentDir(path))
    writeFile(path, captureNoteText(t, captureTitle, id, now()))
  visit(path)
  b.cursor = (b.lines.high, b.lines[^1].len)
  echoLine = "Captured " & shortPath(path)

proc pickTemplate(key: char) =
  for t in captureTemplates:
    if t.key.len > 0 and t.key[0] == key: captureNote(t)

definePrompt(Prompt(kind: "roam-capture-title", text: true, onAccept: proc(value: string): bool =
  if value.strip.len == 0: return false
  captureTitle = value.strip
  captureTemplates = roamTemplates()
  if captureTemplates.len <= 1:
    captureNote(if captureTemplates.len == 1: captureTemplates[0] else: CaptureTemplate(head: "#+title: ${title}\n"))
  else:
    var label = "Template: "
    for t in captureTemplates: label.add "[" & t.key & "] " & t.description & "  "
    beginMini("roam-capture-template", label)
  true))
definePrompt(Prompt(kind: "roam-capture-template", onAccept: proc(value: string): bool =
  if value.len > 0: pickTemplate(value[0])
  true))
runeFilters.add proc(r: Rune): bool =
  if mode != "roam-capture-template": return false
  mode = ""
  prompt = ""
  echoLine = ""
  if r.int < 128: pickTemplate(char(r.int))
  true

interp.defPrimitive("org-roam-capture", proc(args: seq[Value]): Value =
  ## C-c n c: a title, then (with several templates) one key for the template.
  args.arity(0, 0)
  beginMini("roam-capture-title", "Title: ")
  nilValue())

definePrompt(Prompt(kind: "roam-tag", text: true, candidates: proc(): seq[string] = tagRows,
  onAccept: proc(value: string): bool =
    let tag = value.strip(chars = {':', ' '})
    if tag.len == 0: return false
    var lines: seq[string]
    for l in b.lines: lines.add $l
    let change = withTag(lines, tag)
    if change.inserted:
      let cur = b.cursor
      b.snapshot()
      let at = if change.line <= b.lines.high: b.offset((change.line, 0)) else: b.text.runeLen
      b.splice(at, at, change.text & (if change.line <= b.lines.high: "\n" else: ""))
      b.last = "edit"
      let line = if cur.line >= change.line: cur.line + 1 else: cur.line
      b.cursor = (line, cur.col)
    else: setLine(change.line, change.text)
    echoLine = "Tag " & tag & " added"
    true))
interp.defPrimitive("org-roam-tag-add", proc(args: seq[Value]): Value =
  ## C-c n t: a tag (the notes' existing tags offered) added to this file's #+filetags.
  args.arity(0, 0)
  if not orgBuffer(): return nilValue()
  tagRows = allTags(scanNodes(roamDir()))
  beginMini("roam-tag", "Tag: ")
  nilValue())

interp.defPrimitive("org-roam-graph", proc(args: seq[Value]): Value =
  ## C-c n g: the notes and their id links as a page in the browser, this note in red.
  args.arity(0, 0)
  let nodes = scanNodes(roamDir())
  if nodes.len == 0:
    echoLine = "No org-roam notes under " & shortPath(roamDir())
    return nilValue()
  let path = getCacheDir() / "darger" / "org-roam-graph.html"
  try:
    createDir(parentDir(path))
    writeFile(path, graphHtml(nodes, property(b.lines, "ID")))
  except CatchableError as e:
    echoLine = e.msg
    return nilValue()
  openDefaultBrowser("file://" & path)
  echoLine = $nodes.len & " notes in the graph (browser)"
  nilValue())

proc openDaily(): string =
  ## Today's org-roam daily note, created when missing; returns its path.
  result = dailyPath(roamDir(), now())
  if not fileExists(result):
    createDir(parentDir(result))
    writeFile(result, newNoteText(newId(), now().format("yyyy-MM-dd")))
  visit(result)

interp.defPrimitive("org-roam-dailies-today", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  discard openDaily()
  nilValue())
interp.defPrimitive("org-roam-dailies-capture-today", proc(args: seq[Value]): Value =
  ## C-c n j: today's daily with a new "* HH:MM " headline at the end, cursor after it.
  args.arity(0, 0)
  discard openDaily()
  let entry = "* " & now().format("HH:mm") & " "
  b.snapshot()
  b.splice(0, b.text.runeLen, appendedText(b.text, entry))
  b.cursor = b.point(b.text.runeLen)
  b.last = "edit"
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
definePrompt(Prompt(kind: "journal-quick-add", text: true, onAccept: journalQuickAdd))
definePrompt(Prompt(kind: "agenda", text: true, consult: true, candidates: refRowsNow, onAccept: acceptReference))
definePrompt(Prompt(kind: "org-todo", onAccept: proc(value: string): bool =
  if value.len > 0: pickTodo(value[0])
  true))
runeFilters.add proc(r: Rune): bool =
  if mode != "org-todo": return false
  if r.int < 128: pickTodo(char(r.int))
  mode = ""
  prompt = ""
  echoLine = ""
  true
definePrompt(Prompt(kind: "journal-condition", onAccept: proc(value: string): bool =
  if value.len > 0 and value[0] in '1'..'5': recordCondition(ord(value[0]) - ord('0'))
  true))
runeFilters.add proc(r: Rune): bool =
  # The condition prompt takes one key: a digit records, anything else skips, as read-char did.
  if mode != "journal-condition": return false
  if r.int in ord('1')..ord('5'): recordCondition(r.int - ord('0'))
  mode = ""
  prompt = ""
  echoLine = ""
  true

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
(setq org-journal-condition-prompt nil)
(setq org-journal-quick-add-headline "")
(setq org-capture-file "~/org/inbox.org")
(setq org-capture-headline "")
(setq org-capture-template "* TODO %?\n")
(setq org-refile-targets '((nil :maxlevel . 3) (org-agenda-files :maxlevel . 3)))
(global-set-key "C-c C-w" 'org-refile)
(global-set-key "C-c C-s" 'org-schedule)
(global-set-key "C-c C-d" 'org-deadline)
(global-set-key "C-c C-x C-a" 'org-archive-subtree)
(setq org-agenda-files nil)
(setq org-super-agenda-groups
  '((:name "最重要" :priority "A")
    (:name "次にやる" :todo "NEXT")
    (:name "今日やる" :scheduled today)
    (:name "ゲーム制作" :tag "game")
    (:name "執筆・思考" :tag "write")
    (:name "研究・学習" :tag "study")
    (:name "体調・生活" :tag "health")
    (:name "雑務" :tag "life")
    (:name "待ち" :todo "WAITING")
    (:name "未整理（Inbox）" :todo "TODO")))
(global-set-key "S-up" 'org-priority-up)
(global-set-key "S-down" 'org-priority-down)
(setq org-todo-keywords nil)
(setq org-todo-keyword-faces nil)
(setq org-modern-mode t)
(global-set-key "C-c j" 'org-journal-new-entry)
(global-set-key "C-c q" 'org-journal-quick-add)
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
(global-set-key "C-c n j" 'org-roam-dailies-capture-today)
(global-set-key "C-c n c" 'org-roam-capture)
(global-set-key "C-c n g" 'org-roam-graph)
(global-set-key "C-c n t" 'org-roam-tag-add)
(setq org-roam-capture-templates nil)
"""
