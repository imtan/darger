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

# The graph (org-roam-graph): one HTML page with the notes as nodes and their id links as
# edges, laid out by a small force simulation in the page, so no Graphviz is needed.

proc jsonString(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '<': result.add "\\u003c"  # never closes the <script>
    elif c.ord < 0x20: result.add "\\u00" & toHex(c.ord, 2)
    else: result.add c
  result.add "\""

proc graphData*(nodes: seq[RoamNode], current = ""): string =
  ## `{"nodes": [{"id", "title", "tags", "current"}], "edges": [[from, to]]}` with
  ## the node indexes as edge ends; links to unknown ids are dropped, duplicates merged.
  var index: seq[string]
  result = "{\"nodes\":["
  for i, n in nodes:
    index.add n.id
    if i > 0: result.add ","
    result.add "{\"id\":" & jsonString(n.id) & ",\"title\":" & jsonString(n.title) &
      ",\"tags\":" & jsonString(n.tags.join(" ")) & ",\"current\":" & (if n.id == current: "true" else: "false") & "}"
  result.add "],\"edges\":["
  var seen: seq[(int, int)]
  for i, n in nodes:
    for r in n.refs:
      let j = index.find(r.id)
      if j < 0 or j == i or (i, j) in seen: continue
      seen.add (i, j)
      if seen.len > 1: result.add ","
      result.add "[" & $i & "," & $j & "]"
  result.add "]}"

const graphPage = """<!doctype html>
<meta charset="utf-8">
<title>org-roam graph</title>
<style>
html, body { margin: 0; height: 100%; background: #1e1e2e; color: #cdd6f4; font: 13px sans-serif; overflow: hidden; }
canvas { display: block; }
#info { position: fixed; left: 12px; top: 10px; opacity: .8; }
</style>
<div id="info"></div>
<canvas id="c"></canvas>
<script>
const data = DATA;
const canvas = document.getElementById("c"), ctx = canvas.getContext("2d");
const info = document.getElementById("info");
const N = data.nodes, E = data.edges;
let W, H, scale = 1, panX = 0, panY = 0;
const deg = N.map(() => 0);
for (const [a, b] of E) { deg[a]++; deg[b]++; }
for (let i = 0; i < N.length; i++) {
  const ang = i * 2.399963, r = 40 + 12 * Math.sqrt(i);
  N[i].x = r * Math.cos(ang); N[i].y = r * Math.sin(ang); N[i].vx = 0; N[i].vy = 0;
}
function resize() { W = canvas.width = innerWidth; H = canvas.height = innerHeight; }
addEventListener("resize", resize); resize();
let hot = 1, hover = -1, drag = -1, last = null;
function step() {
  if (hot < 0.005) return;
  for (let i = 0; i < N.length; i++) for (let j = i + 1; j < N.length; j++) {
    let dx = N[j].x - N[i].x, dy = N[j].y - N[i].y, d2 = dx * dx + dy * dy + 0.01;
    const f = 1200 / d2; dx *= f; dy *= f;
    N[i].vx -= dx; N[i].vy -= dy; N[j].vx += dx; N[j].vy += dy;
  }
  for (const [a, b] of E) {
    const dx = N[b].x - N[a].x, dy = N[b].y - N[a].y, d = Math.sqrt(dx * dx + dy * dy) + 0.01;
    const f = (d - 60) * 0.02; N[a].vx += dx / d * f; N[a].vy += dy / d * f; N[b].vx -= dx / d * f; N[b].vy -= dy / d * f;
  }
  for (const n of N) {
    n.vx -= n.x * 0.002; n.vy -= n.y * 0.002;
    n.vx *= 0.85; n.vy *= 0.85;
    if (N.indexOf(n) !== drag) { n.x += n.vx * hot; n.y += n.vy * hot; }
  }
  hot *= 0.995;
}
function sx(x) { return W / 2 + (x + panX) * scale; }
function sy(y) { return H / 2 + (y + panY) * scale; }
function draw() {
  step();
  ctx.clearRect(0, 0, W, H);
  ctx.strokeStyle = "rgba(205,214,244,0.25)"; ctx.lineWidth = 1;
  for (const [a, b] of E) {
    const lit = hover === a || hover === b;
    ctx.strokeStyle = lit ? "#f9e2af" : "rgba(205,214,244,0.25)";
    ctx.beginPath(); ctx.moveTo(sx(N[a].x), sy(N[a].y)); ctx.lineTo(sx(N[b].x), sy(N[b].y)); ctx.stroke();
  }
  for (let i = 0; i < N.length; i++) {
    const n = N[i], r = 3 + Math.sqrt(deg[i]) * 2;
    ctx.fillStyle = n.current ? "#f38ba8" : hover === i ? "#f9e2af" : "#89b4fa";
    ctx.beginPath(); ctx.arc(sx(n.x), sy(n.y), r, 0, 7); ctx.fill();
    if (scale > 0.6 || hover === i || n.current || deg[i] > 3) {
      ctx.fillStyle = hover === i ? "#f9e2af" : "#cdd6f4";
      ctx.fillText(n.title, sx(n.x) + r + 3, sy(n.y) + 4);
    }
  }
  requestAnimationFrame(draw);
}
function at(mx, my) {
  let best = -1, bd = 100;
  for (let i = 0; i < N.length; i++) {
    const dx = sx(N[i].x) - mx, dy = sy(N[i].y) - my, d = dx * dx + dy * dy;
    if (d < bd) { bd = d; best = i; }
  }
  return best;
}
canvas.onmousemove = e => {
  if (drag >= 0) { N[drag].x = (e.clientX - W / 2) / scale - panX; N[drag].y = (e.clientY - H / 2) / scale - panY; hot = Math.max(hot, 0.3); }
  else if (last) { panX += (e.clientX - last.x) / scale; panY += (e.clientY - last.y) / scale; last = { x: e.clientX, y: e.clientY }; }
  else hover = at(e.clientX, e.clientY);
  const n = hover >= 0 ? N[hover] : null;
  info.textContent = n ? n.title + (n.tags ? "  [" + n.tags + "]" : "") + "  " + deg[hover] + " links" : N.length + " notes, " + E.length + " links. Drag to move, wheel to zoom.";
};
canvas.onmousedown = e => { drag = at(e.clientX, e.clientY); if (drag < 0) last = { x: e.clientX, y: e.clientY }; };
canvas.onmouseup = () => { drag = -1; last = null; };
canvas.onwheel = e => { scale *= e.deltaY < 0 ? 1.1 : 0.9; e.preventDefault(); };
info.textContent = N.length + " notes, " + E.length + " links. Drag to move, wheel to zoom.";
draw();
</script>
"""

proc graphHtml*(nodes: seq[RoamNode], current = ""): string =
  ## The graph page; `current` (an id) is drawn in red.
  graphPage.replace("DATA", graphData(nodes, current))
