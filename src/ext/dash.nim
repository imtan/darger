## The dashboard, shown at start without arguments, in the spirit of nvim's start
## screens: the DARGER logo and a line under it, a menu of one-key commands with
## their real bindings, the recent files labelled 1-9 and 0, and a footer with the
## day, the file count and the understanding debt. Everything is centred and laid out
## again for the window's size.
import std/[os, strutils, unicode, tables, times]
import ../[core, buffer, lisp, recent, syntax, ledger]

const
  dashMessage* = "Dashboard  Enter:open  j:journal  t:capture  a:agenda  s:shell  u:understanding  q:scratch  F1:manual"
  dashLabels* = "1234567890"
  # The menu: key, caption, the binding shown at the right, the command (a key chord
  # when it starts with "key:").
  dashActions* = [("j", "Journal entry", "C-c j", "org-journal-new-entry"),
                  ("t", "Capture a task", "C-c t", "org-capture"),
                  ("a", "Agenda", "M-x org-agenda", "org-agenda"),
                  ("u", "Understanding", "C-c u", "understanding"),
                  ("f", "Find file", "C-x C-f", "key:C-x C-f"),
                  ("p", "Projects", "C-x p p", "project-switch-project"),
                  ("g", "Agent chat", "C-c c", "agent-chat"),
                  ("s", "Shell", "C-c s", "shell"),
                  ("m", "Manual", "F1", "key:f1")]
  logo = ["██████╗  █████╗ ██████╗  ██████╗ ███████╗██████╗ ",
          "██╔══██╗██╔══██╗██╔══██╗██╔════╝ ██╔════╝██╔══██╗",
          "██║  ██║███████║██████╔╝██║  ███╗█████╗  ██████╔╝",
          "██║  ██║██╔══██║██╔══██╗██║   ██║██╔══╝  ██╔══██╗",
          "██████╔╝██║  ██║██║  ██║╚██████╔╝███████╗██║  ██║",
          "╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝"]
  tagline = "I'm talking about the present."

type Entry = object
  line: int      # the buffer line
  action: int    # index into dashActions, or -1
  file: int      # index into dashFiles, or -1

var
  dashBuf*: Buffer
  dashFiles*: seq[string]
  dashFirst* = 4          # line of the first recent-file entry
  dashFaces: seq[seq[Face]]
  dashBgs: seq[seq[int8]]  # the logo as filled cells (13) and their shadow (14): no glyphs, so any font works
  dashEntries: seq[Entry]
  dashSize: tuple[cols, rows: int]
  dashCurrent = 0         # the selected entry

proc width(s: string): int =
  for r in s.runes: result += runeWidth(r)

proc debtNote(): string =
  ## "understanding debt N" from the ledger, when there is one.
  let v = interp.env.values.getOrDefault("understanding-ledger")
  if v == nil or v.kind == vNil: return ""
  let path = expandTilde(v.asString)
  if not fileExists(path): return ""
  try:
    let (debt, understood) = debtCount(readFile(path))
    result = "debt " & $debt & " · understood " & $understood
  except CatchableError: result = ""

proc select(i: int) =
  ## The cursor sits on the entry's key, not at the window's edge.
  if dashEntries.len == 0: return
  dashCurrent = clamp(i, 0, dashEntries.high)
  let line = dashEntries[dashCurrent].line
  var col = 0
  while col < dashBuf.lines[line].len and dashBuf.lines[line][col] == Rune(' '): inc col
  dashBuf.cursor = (line, min(col, dashBuf.lines[line].len))

proc layoutDash() =
  ## The buffer and its colours for the current window size.
  let cols = max(40, if renderer.cols > 0: renderer.cols else: 80)
  let rows = max(20, if renderer.rows > 0: renderer.rows else: 30)
  dashSize = (cols, rows)
  var lines: seq[string]
  var faces: seq[seq[Face]]
  var bgs: seq[seq[int8]]
  dashEntries = @[]
  proc add(text: string, face = fPlain, spans: seq[(int, int, Face)] = @[]) =
    # centred: spans are (start, len) in runes of the uncentred text
    let pad = max(0, (cols - width(text)) div 2)
    let full = repeat(' ', pad) & text
    lines.add full
    var f = newSeq[Face](full.runeLen)
    if face != fPlain:
      for i in pad..<f.len: f[i] = face
    for (a, n, sf) in spans:
      for i in max(0, pad + a)..<min(f.len, pad + a + n): f[i] = sf
    faces.add f
    bgs.add @[]
  proc addLogo(art: string) =
    # Block characters become filled cells and box-drawing ones their shadow; the
    # text itself is spaces, so the look does not depend on the font's glyphs.
    let pad = max(0, (cols - art.runeLen) div 2)
    var row = newSeq[int8](pad + art.runeLen)
    var i = pad
    for r in art.runes:
      if r == Rune(0x2588): row[i] = 13
      elif r.int in 0x2550..0x256C: row[i] = 14
      inc i
    lines.add repeat(' ', pad + art.runeLen)
    faces.add newSeq[Face](pad + art.runeLen)
    bgs.add row
  # vertical centring of the whole block
  let menuWidth = 2 + 1 + 2 + 18 + 2 + 14
  let fileLimit = max(24, min(cols - 10, 70))
  let content = logo.len + 2 + dashActions.len + 2 + max(1, dashFiles.len) + 2
  for i in 0..<max(1, (rows - content) div 2): add("")
  for l in logo: addLogo(l)
  add(tagline, fComment)
  add("")
  for i, (key, caption, hint, _) in dashActions:
    let text = "  " & key & "  " & alignLeft(caption, 18) & "  " & alignLeft(hint, 14)
    dashEntries.add Entry(line: lines.len, action: i, file: -1)
    add(text, fPlain, @[(2, 1, fConstant), (2 + 1 + 2 + 18 + 2, 14, fComment)])
  add("")
  add(alignLeft("Recent files", menuWidth), fFnname)
  dashFirst = lines.len
  for i, f in dashFiles:
    let shown = shortPath(f, fileLimit)
    dashEntries.add Entry(line: lines.len, action: -1, file: i)
    add(alignLeft("  " & dashLabels[i] & "  " & shown, menuWidth), fPlain, @[(2, 1, fConstant)])
  if dashFiles.len == 0: add(alignLeft("  (none yet)", menuWidth), fComment)
  add("")
  let today = now()
  var footer = today.format("yyyy-MM-dd ddd") & " · " & $dashFiles.len & " recent"
  let debt = debtNote()
  if debt.len > 0: footer.add " · " & debt
  add(footer, fComment)
  dashBuf = newBuffer(lines.join("\n"))
  dashBuf.path = "*dashboard*"
  dashFaces = faces
  dashBgs = bgs
  dashCurrent = clamp(dashCurrent, 0, max(0, dashEntries.high))
  if dashEntries.len > 0: select(dashCurrent)

proc beginDash*() =
  beginOverlay("dash")
  dashFiles = loadRecent()
  if dashFiles.len > dashLabels.len: dashFiles.setLen(dashLabels.len)
  dashCurrent = dashActions.len  # the newest file when there is one
  if dashFiles.len == 0: dashCurrent = 0
  layoutDash()
  renderer.top = 0

proc finishDash*() =
  finishOverlay()
  dashBuf = nil
  dashFiles = @[]

proc openEntry*(i: int) =
  if i notin 0..dashFiles.high: return
  let path = dashFiles[i]
  if not fileExists(path):
    echoLine = "No such file: " & shortPath(path)
    return
  finishDash()
  try: visit(path)
  except CatchableError as e:
    beginDash()
    echoLine = e.msg

proc runAction(i: int) =
  if i notin 0..dashActions.high: return
  let command = dashActions[i][3]
  finishDash()
  if command.startsWith("key:"): dispatch(command[4..^1])
  else:
    try: discard interp.call(symbol(command), @[])
    except LispError as e: echoLine = e.msg


proc dispatchDash*(c: string) =
  ## The dashboard only moves between entries or opens one; its menu keys run commands.
  let full = overlayKey(c)
  if full.len == 0: return
  let name = keymap.getOrDefault(full).symName
  if full in ["q", "C-g", "escape"] or name == "dashboard": finishDash()
  elif full == "C-x C-c": quitEditor()
  elif full in ["C-x C-f", "C-x d", "C-x b"]:
    finishDash()
    dispatch(full)
  elif full in ["enter", "C-m", "C-j"]:
    if dashEntries.len > 0:
      let e = dashEntries[dashCurrent]
      if e.file >= 0: openEntry(e.file) else: runAction(e.action)
  elif name in ["next-line", "previous-line"] or full in ["C-n", "C-p", "down", "up", "k"]:
    select(dashCurrent + (if name == "previous-line" or full in ["C-p", "up", "k"]: -1 else: 1))
  elif full.len == 1 and dashLabels.find(full[0]) in 0..dashFiles.high:
    openEntry(dashLabels.find(full[0]))
  else:
    for i, (key, _, _, _) in dashActions:
      if full == key:
        runAction(i)
        return
    if full == "f1" or name == "help":
      finishDash()
      dispatch(full)
    else: echoLine = full & " is undefined"

interp.defPrimitive("dashboard", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if mode == "dash": finishDash()
  elif mode in ["", "eval", "execute"]: beginDash()
  else: echoLine = "dashboard is unavailable here"
  nilValue())

defineMode(Mode(name: "dash", tag: "[Dash]", buffer: proc(): Buffer = dashBuf,
  faces: proc(): seq[seq[Face]] = dashFaces, bgs: proc(): seq[seq[int8]] = dashBgs,
  colors: proc(): seq[int8] =
    if dashBuf != nil and dashEntries.len > 0:
      result = newSeq[int8](dashBuf.lines.len)
      result[dashEntries[dashCurrent].line] = 5,
  beforeDraw: proc() = (if (max(40, renderer.cols), max(20, renderer.rows)) != dashSize: layoutDash()),
  message: proc(): string = overlayMessage(dashMessage), onKey: dispatchDash, onClose: finishDash))

startScreen = beginDash
