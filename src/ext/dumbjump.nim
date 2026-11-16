## Definition navigation when a language server is unavailable.
import std/[os, unicode, strutils, sets]
import ../[core, buffer, buffers, render, lisp, lsp, syntax, chat, grep, dumbjump, remote]

proc dumbJumpGo*() =
  let origin = b
  let at = b.cursor
  let name = symbolAt(b.lines[at.line], at.col, lang.name)
  if name.len == 0:
    echoLine = "No symbol at point"
    return
  var hits = rankDefinitions(definitions(b.lines, lang, name, b.path), b.path, at.line, at.col, name)
  let root = if isRemote(b.path): "" else:
    rootFromDir(if b.path.len > 0: parentDir(b.path) else: getCurrentDir())
  if hits.len == 0 and root.len > 0:
    let search = runGrep(root, name, literal = true)
    if search.error.len > 0:
      echoLine = "grep: " & search.error
      return
    var seen: HashSet[string]
    for h in search.hits:
      let path = normalizedPath(absolutePath(h.path))
      if path == b.path or path in seen: continue # current buffer wins over its saved text
      seen.incl path
      var lines: seq[seq[Rune]]
      let open = reg.byPath(path)
      if open != nil: lines = open.lines
      else:
        try:
          for line in readFile(path).replace("\r\n", "\n").split('\n'): lines.add line.toRunes
        except CatchableError: continue
      let language = if open != nil: reg.slot(open).lang else: detect(path, if lines.len > 0: $lines[0] else: "")
      hits.add definitions(lines, language, name, path)
    hits = rankDefinitions(hits, b.path, at.line, at.col, name)
  if hits.len == 0:
    echoLine = "No definition for " & name
  elif hits.len == 1:
    let h = hits[0]
    pushXref(origin, at, renderer.top, renderer.left)
    try:
      if h.path != b.path: visit(h.path)
      b.cursor = (h.line, h.col)
      b.finish()
      recenterCycle = 0
      recenter(b)
      renderer.left = 0
      echoLine = ""
    except CatchableError as e:
      discard xrefStack.pop()
      echoLine = e.msg
  else:
    targets = @[]
    refRows = @[]
    for h in hits:
      targets.add Location(path: h.path, line: h.line, col: h.col)
      refRows.add hitRow(h, root)
    beginMini("dumb-jump", "Definition of " & name & ": ")

definePrompt(Prompt(kind: "dumb-jump", text: true, consult: true,
  candidates: refRowsNow, onAccept: acceptReference))
interp.defPrimitive("dumb-jump-go", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  dumbJumpGo()
  nilValue())
