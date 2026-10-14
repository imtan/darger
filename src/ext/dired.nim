## Dired: a directory listing view that opens, creates, renames and trashes entries
## (filer.nim does the file work).
import std/[os, strutils, unicode, tables]
from windy import closeIme  # not the whole module: vmath's colour accessor b would shadow the buffer
import ../[core, buffer, buffers, render, lisp, filer, syntax, complete]

const
  diredMessage* = "Dired  n/p:move  Enter/f:open  ^:parent  g:refresh  +:mkdir  R:rename  D:trash  q:close"

var
  diredBuf*: Buffer
  diredEntries*: seq[filer.Entry]
  diredFaces*: seq[seq[Face]]
  diredSource*, pendingTrash*: string

proc beginDired*(path: string, selected = "") =
  let dir = normalizedPath(absolutePath(expandTilde(path)))
  let entries = readDirectory(dir)  # leave the current listing intact on any error
  var lines = @[dir.replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t")]
  for entry in entries: lines.add formatRow(entry)
  if entries.len == 0: lines.add ""  # keep point off the header even in an empty directory
  let buf = newBuffer(lines.join("\n"))
  buf.path = dir
  buf.cursor = (1, 0)
  var colors = newSeq[seq[Face]](lines.len)
  for i, entry in entries:
    if entry.name == selected: buf.cursor.line = i + 1
    if entry.isDir:
      colors[i + 1] = newSeq[Face](buf.lines[i + 1].len)
      for col in nameCol..<colors[i + 1].len: colors[i + 1][col] = fFnname
  if mode != "dired": beginOverlay("dired")
  diredBuf = buf
  diredEntries = entries
  diredFaces = colors
  renderer.top = 0
  renderer.left = 0
  pendingTrash = ""

proc finishDired*() =
  finishOverlay()
  diredBuf = nil
  diredEntries = @[]
  diredFaces = @[]
  pendingTrash = ""

proc diredName*(): string =
  let index = diredBuf.cursor.line - 1
  if index in 0..diredEntries.high: diredEntries[index].name else: ""

proc diredPrompt*() =
  beginMini("dired-path", "Dired: ", (if b.path.len > 0: parentDir(b.path) else: getCurrentDir()) & DirSep)

proc dispatchDired*(c: string) =
  if c in ["q", "C-g", "escape"]:
    finishDired()
    return
  if pendingTrash.len > 0:
    if c notin ["y", "n"]:
      echoLine = "Please answer y or n"
      return
    let path = pendingTrash
    let row = diredBuf.cursor.line
    pendingTrash = ""
    if c == "y":
      trashEntry(path)
      beginDired(diredBuf.path)
      diredBuf.cursor = (clamp(row, 1, max(1, diredEntries.len)), 0)  # the entry that moved up
    return
  let full = overlayKey(c)
  if full.len == 0: return
  let name = diredName()
  let path = diredBuf.path / name
  let command = keymap.getOrDefault(full).symName
  if full in ["enter", "C-m", "C-j", "f"] and name.len > 0:
    let info = getFileInfo(path)  # vanished entries must not open an empty new file
    if info.kind == pcDir: beginDired(path)
    else:
      visit(path)
      finishDired()
  elif full == "^":
    let parent = parentDir(diredBuf.path)
    if parent.len > 0 and parent != diredBuf.path:
      beginDired(parent, extractFilename(diredBuf.path))
  elif full == "g": beginDired(diredBuf.path, name)
  elif full == "+": beginMini("dmkdir", "Create directory: ", diredBuf.path & DirSep)
  elif full == "R" and name.len > 0:
    diredSource = path
    beginMini("drename", "Rename to: ", path)
  elif full == "D" and name.len > 0: pendingTrash = path
  elif full in ["n", "C-n", "down", "p", "C-p", "up"] or command in ["next-line", "previous-line"]:
    let delta = if full in ["p", "C-p", "up"] or command == "previous-line": -1 else: 1
    diredBuf.cursor = (clamp(diredBuf.cursor.line + delta, 1, max(1, diredEntries.len)), 0)
  elif full in ["C-v", "M-v", "pagedown", "pageup"]:
    page(diredBuf, full)
    diredBuf.cursor = (max(1, diredBuf.cursor.line), 0)
  elif command in ["bob", "eob"] or full in ["M-<", "M->"]:
    let row = if command == "eob" or full == "M->": max(1, diredEntries.len) else: 1
    diredBuf.cursor = (row, 0)

interp.defPrimitive("dired", proc(args: seq[Value]): Value =
  args.arity(0, 1)
  if mode in ["", "eval", "execute", "dired"]:
    if args.len == 0: diredPrompt()  # C-x d, M-x dired: ask for the directory, as Emacs does
    else:
      try: beginDired(args[0].asString)
      except CatchableError as e: echoLine = e.msg
  else: echoLine = "dired is unavailable here"
  nilValue())

defineMode(Mode(name: "dired", modeName: "Dired", buffer: proc(): Buffer = diredBuf,
  faces: proc(): seq[seq[Face]] = diredFaces,
  message: proc(): string =
    (if pendingTrash.len > 0: "Trash " & diredName() & "? (y or n)"
     elif echoLine.len > 0: echoLine else: diredMessage),
  onKey: dispatchDired, onClose: finishDired))

definePrompt(Prompt(kind: "dired-path", text: true, paths: true, candidates: noRows,
  rawEnter: proc(): bool = dirExists(expandTilde(mini.text)),
  onAccept: proc(value: string): bool =
    if value.len == 0: return false
    beginDired(value)
    true))

proc acceptDiredName*(value: string): bool =
  let kind = mode
  mode = "dired"
  if value.len == 0: return true
  let path = absolutePath(expandTilde(value), diredBuf.path)
  if kind == "dmkdir": makeDirectory(path)
  else: renameEntry(diredSource, path)
  beginDired(parentDir(path), extractFilename(path))
  true
proc always*(): bool = true
definePrompt(Prompt(kind: "dmkdir", text: true, paths: true, over: "dired", candidates: noRows,
  rawEnter: always, onAccept: acceptDiredName))
definePrompt(Prompt(kind: "drename", text: true, paths: true, over: "dired", candidates: noRows,
  rawEnter: always, onAccept: acceptDiredName))

dirVisitor = proc(path: string) = beginDired(path)
defaults.add """
(global-set-key "C-x d" 'dired)
"""
