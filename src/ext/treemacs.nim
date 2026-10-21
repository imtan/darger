## A project tree in an ordinary read-only buffer and a left side pane.
import std/[os, strutils, unicode, tables]
import ../[core, buffer, buffers, panes, lisp, syntax, chat, remote, filetree]

var
  tree: Tree
  tbuf: Buffer
  trows: seq[Row]
  filePane: Pane
  lastPath: string

proc enabled(name: string): bool =
  let v = interp.env.values.getOrDefault(name)
  v != nil and v.kind != vNil

proc number(name: string, fallback: int): int =
  let v = interp.env.values.getOrDefault(name)
  if v == nil: fallback else: int(v.asNumber)

proc treePane(): Pane =
  if tbuf != nil:
    for p in layout.leaves:
      if p.buf == tbuf: return p

proc moveTo(line: int) =
  tbuf.cursor = (clamp(line, 0, tbuf.lines.high), 0)
  tbuf.goal = -1
  for p in layout.leaves:
    if p.buf == tbuf:
      p.cursor = tbuf.cursor
      if p != pane:
        p.top = max(0, tbuf.cursor.line - max(1, p.h - 1) div 2)

proc rebuild(keep = "") =
  tree.collapseDirs = max(0, number("treemacs-collapse-dirs", 3))
  trows = tree.rows(enabled("treemacs-show-hidden"))
  var lines: seq[string]
  var line = tbuf.cursor.line
  for i, row in trows:
    lines.add row.render
    if row.path == keep: line = i
  tbuf.splice(0, tbuf.text.runeLen, lines.join("\n"))
  tbuf.modified = false
  moveTo(line)

proc follow(path: string) =
  lastPath = path
  if isRemote(path):
    echoLine = "Treemacs does not support SSH paths"
    return
  if path.len == 0: return
  tree.collapseDirs = max(0, number("treemacs-collapse-dirs", 3))
  let line = tree.reveal(path, enabled("treemacs-show-hidden"))
  rebuild()
  if line >= 0: moveTo(line)

proc openTree() =
  if treePane() != nil: return
  if isRemote(b.path):
    echoLine = "Treemacs does not support SSH paths"
    return
  let path = b.path
  let dir = if path.len > 0: parentDir(absolutePath(path)) else: getCurrentDir()
  let left = pane
  let count = layout.leaves.len
  splitPane(false)
  if layout.leaves.len == count: return
  let right = layout.next(left, 1)
  if tbuf == nil:
    tbuf = newBuffer()
    reg.add(tbuf, "*treemacs*")
  tree = newTree(rootFromDir(dir))
  rebuild()
  # Select the preserved file first, so selectPane saves its point and scroll.
  selectPane(right)
  left.buf = tbuf
  left.cursor = tbuf.cursor
  (left.top, left.left) = (0, 0)
  filePane = right
  discard layout.resize(left, false, number("treemacs-width", 35) - left.w)
  layoutPanes()
  lastPath = ""
  if enabled("treemacs-follow-mode"): follow(path)

proc fileWindow(): Pane =
  if filePane in layout.leaves and filePane.buf != tbuf: return filePane
  for p in layout.leaves:
    if p.buf != tbuf:
      filePane = p
      return p
  let count = layout.leaves.len
  splitPane(false)
  if layout.leaves.len == count: return nil
  result = layout.next(pane, 1)
  (result.top, result.left) = (0, 0)
  # A tree-only frame needs an ordinary buffer before visiting or leaving.
  for slot in reg.slots:
    if slot.buf != tbuf:
      result.buf = slot.buf
      result.cursor = slot.buf.cursor
      filePane = result
      return
  result.buf = newBuffer()
  reg.add(result.buf)
  result.cursor = (0, 0)
  filePane = result

proc leaveTree() =
  let other = fileWindow()
  if other != nil: selectPane(other)

proc rootUp() =
  let old = tree.root.path
  tree = newTree(parentDir(old))
  let line = tree.reveal(old, enabled("treemacs-show-hidden"))
  rebuild()
  moveTo(max(0, line))

proc parentRow() =
  let here = tbuf.cursor.line
  if here == 0: rootUp()
  else:
    for i in countdown(here - 1, 0):
      if trows[i].depth < trows[here].depth:
        moveTo(i)
        break

proc treemacsKey(c: string): bool =
  if mode.len > 0 or tbuf == nil or b != tbuf: return false
  let rootKey = prefix == "C-c" and c == "C-r"
  if c == "C-r" and not rootKey: return false
  if prefix.len > 0:
    if prefix != "C-c" or c != "C-r": return false
    prefix = ""
  let row = trows[clamp(tbuf.cursor.line, 0, trows.high)]
  try:
    case c
    of "n", "p": moveTo(tbuf.cursor.line + (if c == "n": 1 else: -1))
    of "enter", "C-m", "C-j", "f":
      if row.isDir:
        tree.toggle(row.path)
        rebuild(row.path)
      else:
        let keep = pane
        let other = fileWindow()
        if other != nil:
          selectPane(other)
          try: visit(row.path)
          finally:
            if enabled("treemacs-stay-on-open"): selectPane(keep)
          follow(row.path)
    of "tab", "C-i", " ", "space":
      if row.isDir:
        tree.toggle(row.path)
        rebuild(row.path)
    of "^", "u": parentRow()
    of "g":
      tree.refresh()
      rebuild(row.path)
    of "H":
      interp.env.values["treemacs-show-hidden"] = if enabled("treemacs-show-hidden"): nilValue() else: Value(kind: vTrue)
      rebuild(row.path)
    of "C-r":
      if row.isDir:
        tree = newTree(row.path)
        rebuild()
        moveTo(0)
    of "q", "M-0": leaveTree()
    of "?": echoLine = "Enter/f: open/toggle  Tab/Space: toggle  n/p: move  ^/u: parent  g: refresh  H: hidden  C-c C-r: root  q/M-0: file"
    of "backspace", "delete", "C-h", "C-d", "C-k", "C-w", "C-y", "M-y", "C-o", "C-t", "M-d", "M-backspace", "C-/", "C-_":
      echoLine = "The tree buffer is read-only"
    else: return false
  except CatchableError as e: echoLine = e.msg
  true

keyFilters.add treemacsKey
runeFilters.add proc(r: Rune): bool =
  if mode.len > 0 or prefix.len > 0 or tbuf == nil or b != tbuf: return false
  if treemacsKey($r): return true
  echoLine = "The tree buffer is read-only (? for keys)"
  true
faceProviders.add proc(buf: Buffer): seq[seq[Face]] =
  if tbuf == nil or buf != tbuf: return
  for i, line in buf.lines:
    var faces = newSeq[Face](line.len)
    let face = if i == 0: fFnname elif i < trows.len and trows[i].isDir: fKeyword else: fPlain
    for f in faces.mitems: f = face
    result.add faces
bandProviders.add proc(buf: Buffer): seq[int8] =
  if tbuf != nil and buf == tbuf:
    result = newSeq[int8](buf.lines.len)
    if buf.cursor.line < result.len: result[buf.cursor.line] = 5
    for i, row in trows:
      if row.path == lastPath and i < result.len: result[i] = 5
modeNameProviders.add proc(buf: Buffer): string = (if tbuf != nil and buf == tbuf: "Tree" else: "")
noGutter.add proc(buf: Buffer): bool = tbuf != nil and buf == tbuf
killHooks.add proc(buf: Buffer) =
  if buf == tbuf:
    tbuf = nil
    tree = nil
    trows = @[]
    lastPath = ""
paneSkip.add proc(p: Pane): bool =
  tbuf != nil and p.buf == tbuf and enabled("treemacs-is-never-other-window")
tickHooks.add proc(): bool =
  if treePane() == nil or b == tbuf: return false
  filePane = pane
  if b.path == lastPath: return false
  if enabled("treemacs-follow-mode"): follow(b.path)
  else: lastPath = b.path
  true

interp.defPrimitive("treemacs", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let p = treePane()
  if p == nil: openTree()
  else:
    if layout.leaves.len == 1: leaveTree()
    let next = layout.remove(p)
    if next != nil:
      if pane == p: selectPane(next)
      layoutPanes()
  nilValue())
interp.defPrimitive("treemacs-select-window", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if tbuf != nil and b == tbuf: leaveTree()
  else:
    openTree()
    let p = treePane()
    if p != nil:
      filePane = pane
      selectPane(p)
  nilValue())
interp.defPrimitive("treemacs-root-up", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if tree != nil: rootUp()
  nilValue())

defaults.add """
(setq treemacs-width 35)
(setq treemacs-follow-mode t)
(setq treemacs-collapse-dirs 3)
(setq treemacs-show-hidden nil)
(setq treemacs-stay-on-open nil)
(setq treemacs-is-never-other-window t)
(global-set-key "C-x t t" 'treemacs)
(global-set-key "M-0" 'treemacs-select-window)
"""
