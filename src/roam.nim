## org-roam: notes are Org files with an ID property and a title, found under one
## directory; links between them are [[id:...]] links.
import std/[os, strutils, unicode, times, sysrand, algorithm]
import orgmode

type
  RoamNode* = object
    id*, title*, path*: string
    tags*: seq[string]  ## from #+filetags: :A:B:
    refs*: seq[tuple[id: string, line: int, text: string]]  # id links out of the file
  Backlink* = object
    title*, path*: string  # the linking note
    line*: int             # the line of the link there
    text*: string          # that line, trimmed

proc slug*(title: string): string =
  ## org-roam's file name slug: letters and digits lowercased, runs of anything else '_'.
  var gap = false
  for r in title.runes:
    if r.isAlpha or int(r) in ord('0')..ord('9'):
      if gap and result.len > 0: result.add '_'
      gap = false
      result.add $r.toLower
    else: gap = true

proc parseTags*(value: string): seq[string] =
  ## The tags in a #+filetags value, ":A:B:" or "A B".
  for t in value.split({':', ' ', '\t'}):
    if t.len > 0 and t notin result: result.add t

proc allTags*(nodes: seq[RoamNode]): seq[string] =
  ## Every tag any node has, sorted, case kept.
  for n in nodes:
    for t in n.tags:
      if t notin result: result.add t
  result.sort(proc(a, b: string): int = cmpIgnoreCase(a, b))

proc withTag*(lines: seq[string], tag: string): tuple[line: int, text: string, inserted: bool] =
  ## Where org-roam-tag-add puts the tag: the #+filetags: line with it appended
  ## (text replaces that line), or a new ":tag:" line after #+title: (else after
  ## the properties drawer, else at the top: inserted = true).
  let clean = tag.strip(chars = {':', ' '})
  var titleAt, endAt = -1
  for n, l in lines:
    let low = l.toLowerAscii
    if low.startsWith("#+filetags:"):
      let value = l[11..^1].strip
      let text = if value.len == 0: "#+filetags: :" & clean & ":"
        elif value.endsWith(":"): "#+filetags: " & value & clean & ":"
        else: "#+filetags: " & value & " " & clean
      return (n, text, false)
    if low.startsWith("#+title:") and titleAt < 0: titleAt = n
    if low.strip == ":end:" and endAt < 0: endAt = n
  let at = if titleAt >= 0: titleAt + 1 elif endAt >= 0: endAt + 1 else: 0
  (at, "#+filetags: :" & clean & ":", true)

type CaptureTemplate* = object
  ## One of org-roam-capture-templates: `(key description file head)`, where file
  ## and head may use ${title}, ${slug}, ${id}, %<FORMAT> and %T.
  key*, description*, file*, head*: string

proc expandTemplate*(tmpl, title, id: string, now: DateTime): string =
  ## ${title} ${slug} ${id}, %<FMT> through strftime, %T an active timestamp, %? dropped.
  var s = tmpl.replace("${title}", title).replace("${slug}", slug(title)).replace("${id}", id)
  s = s.replace("%?", "")
  s = s.replace("%T", now.format("'<'yyyy-MM-dd ddd HH:mm'>'"))
  while true:
    let a = s.find("%<")
    if a < 0: break
    let z = s.find(">", a)
    if z < 0: break
    s = s[0..<a] & strftime(s[a+2..<z], now) & s[z+1..^1]
  s

proc captureNoteText*(t: CaptureTemplate, title, id: string, now: DateTime): string =
  ## The new note: the ID drawer org-roam adds, then the template's head.
  var head = expandTemplate(t.head, title, id, now)
  if head.len > 0 and not head.endsWith("\n"): head.add "\n"
  if ":ID:" in head: head else: ":PROPERTIES:\n:ID:       " & id & "\n:END:\n" & head

proc captureNotePath*(dir: string, t: CaptureTemplate, title, id: string, now: DateTime): string =
  dir / expandTemplate(if t.file.len > 0: t.file else: "%<%Y%m%d%H%M%S>-${slug}.org", title, id, now)

proc parseNode*(path, text: string): RoamNode =
  result.path = path
  var lines: seq[seq[Rune]]
  for l in text.replace("\r\n", "\n").split('\n'): lines.add l.toRunes
  result.id = property(lines, "ID")
  result.title = keyword(lines, "title")
  if result.title.len == 0: result.title = splitFile(path).name
  result.tags = parseTags(keyword(lines, "filetags"))
  for n, l in lines:
    let s = $l
    var i = 0
    while true:
      i = s.find("[[id:", i)
      if i < 0: break
      var j = i + 5
      while j < s.len and s[j] notin {']', '['}: inc j
      if j < s.len and j > i + 5: result.refs.add (s[i+5..<j], n, strutils.strip(s))
      i = j

proc scanNodes*(dir: string): seq[RoamNode] =
  ## Every .org file under dir that has an ID, by title; dot-directories are skipped.
  if not dirExists(dir): return
  for path in walkDirRec(dir):
    if not path.endsWith(".org") or "/." in path or "\\." in path: continue
    var node: RoamNode
    try: node = parseNode(path, readFile(path))
    except IOError: continue
    if node.id.len > 0: result.add node
  result.sort(proc(a, b: RoamNode): int = cmpIgnoreCase(a.title, b.title))

proc byId*(nodes: seq[RoamNode], id: string): int =
  for i, n in nodes:
    if n.id == id: return i
  -1

proc byTitle*(nodes: seq[RoamNode], title: string): int =
  for i, n in nodes:
    if n.title == title: return i
  -1

proc backlinks*(nodes: seq[RoamNode], id: string): seq[Backlink] =
  for n in nodes:
    for r in n.refs:
      if r.id == id: result.add Backlink(title: n.title, path: n.path, line: r.line, text: r.text)


proc newId*(): string =
  ## A random UUID, as org-id makes.
  var bytes: array[16, byte]
  if not urandom(bytes): raise newException(IOError, "Cannot generate an id")
  bytes[6] = (bytes[6] and 0x0f) or 0x40
  bytes[8] = (bytes[8] and 0x3f) or 0x80
  for i, b in bytes:
    if i in [4, 6, 8, 10]: result.add '-'
    result.add toHex(b, 2).toLowerAscii

proc newNoteText*(id, title: string): string =
  ":PROPERTIES:\n:ID:       " & id & "\n:END:\n#+title: " & title & "\n\n"

proc newNotePath*(dir, title: string, now: DateTime): string =
  dir / (now.format("yyyyMMddHHmmss") & "-" & slug(title) & ".org")

proc dailyPath*(dir: string, day: DateTime): string =
  dir / "daily" / (day.format("yyyy-MM-dd") & ".org")

proc linkText*(id, title: string): string = "[[id:" & id & "][" & title & "]]"
