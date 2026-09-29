import std/[os, osproc, unicode, json, strutils, times, tables, tempfiles]
import ../src/lsp
from ../src/buffer import newBuffer, text, command, offset, point, Buffer

# Framing: split frames, two in one chunk, a large payload, a malformed header.
block:
  let a = """{"a":1}"""
  let b = """{"b":"ü"}"""
  var buf = ""
  var malformed = false
  let fa = frame(a)
  let fb = frame(b)
  buf = fa[0..5]
  doAssert takeFrames(buf, malformed).len == 0
  buf.add fa[6..^1] & fb[0..20]
  doAssert takeFrames(buf, malformed) == @[a]
  buf.add fb[21..^1]
  doAssert takeFrames(buf, malformed) == @[b]
  doAssert buf.len == 0
  buf = fa & fb & fa[0..2]
  doAssert takeFrames(buf, malformed) == @[a, b]
  doAssert buf == fa[0..2]
  let big = "\"" & repeat('x', 100_000) & "\""
  buf = "content-length: " & $big.len & "\r\nContent-Type: application/vscode-jsonrpc\r\n\r\n" &
    big[0..49_999]
  doAssert takeFrames(buf, malformed).len == 0
  buf.add big[50_000..^1]
  doAssert takeFrames(buf, malformed) == @[big]
  doAssert not malformed
  buf = "Content-Type: x\r\n\r\n{}" & fa
  doAssert takeFrames(buf, malformed).len == 0
  doAssert malformed and buf.len == 0

# UTF-16 columns: a CJK rune is one unit, an emoji two.
block:
  let line = "a漢😀b".toRunes
  doAssert utf16Col(line, 0) == 0
  doAssert utf16Col(line, 2) == 2
  doAssert utf16Col(line, 3) == 4
  doAssert utf16Col(line, 4) == 5
  doAssert utf16Col(line, 9) == 5
  doAssert runeCol(line, 2) == 2
  doAssert runeCol(line, 3) == 2  # inside the surrogate pair rounds down
  doAssert runeCol(line, 4) == 3
  doAssert runeCol(line, 99) == 4

# uris
block:
  when defined(windows):
    doAssert uriOf("C:\\a b\\x.nim") == "file:///C:/a%20b/x.nim"
    doAssert pathOf("file:///C:/a%20b/x.nim") == "C:\\a b\\x.nim"
    doAssert pathOf("file:///c%3A/x.nim") == "c:\\x.nim"
    doAssert uriOf("c:\\x.nim") == "file:///C:/x.nim"  # rust-analyzer sends c:
  else:
    doAssert uriOf("/tmp/a b/漢.nim") == "file:///tmp/a%20b/%E6%BC%A2.nim"
    doAssert uriOf("/x/a+b#c.nim") == "file:///x/a%2Bb%23c.nim"
  for p in [getTempDir() / "dir with space" / "file.nim", getTempDir() / "日本語" / "a.py"]:
    doAssert pathOf(uriOf(p)) == absolutePath(p), p

# rootOf: the nearest .git, else the file's directory.
block:
  let tmp = createTempDir("darger-tlsp-", "")
  createDir(tmp / "proj" / ".git")
  createDir(tmp / "proj" / "src" / "deep")
  doAssert rootOf(tmp / "proj" / "src" / "deep" / "a.nim") == tmp / "proj"
  createDir(tmp / "loose")
  doAssert rootOf(tmp / "loose" / "b.nim") == tmp / "loose"
  removeDir(tmp)

# Server table.
block:
  setServer("Test", "definitely-not-a-server-xyz --stdio")
  doAssert serverFor("Test") == ""
  doAssert missingServer("Test") == "definitely-not-a-server-xyz not found"
  setServer("Test", "")
  doAssert not hasServer("Test") and missingServer("Test") == ""
  doAssert missingServer("Python") == "pyright-langserver, pylsp not found" or serverFor("Python") != ""
  doAssert languageId("JS/TS", "a.ts") == "typescript"
  doAssert languageId("JS/TS", "a.mjs") == "javascript"
  doAssert languageId("C/C++", "a.c") == "c"
  doAssert languageId("C/C++", "a.cpp") == "cpp"
  doAssert languageId("Shell", "a.sh") == "shellscript"
  doAssert languageId("GDScript", "a.gd") == "gdscript"
  doAssert serverFor("Text") == ""


# Completion items: snippets stripped, textEdit / InsertReplaceEdit starts, sortText order.
block:
  doAssert stripSnippet("foo(${1:a}, ${2:b})$0") == "foo(a, b)"
  doAssert stripSnippet("${1:outer ${2:inner}} x") == "outer inner x"
  doAssert stripSnippet("a\\$b \\} \\\\ \\n") == "a$b } \\ \\n"
  doAssert stripSnippet("${1|yes,no|}!") == "yes!"
  doAssert stripSnippet("$TM_FILENAME: ${2}$1") == ": "
  doAssert stripSnippet("{ $1 }") == "{  }"
  doAssert stripSnippet("plain $") == "plain $"
  let items = parseCompletion(%*{"isIncomplete": false, "items": [
    {"label": " zeta", "kind": 6, "sortText": "2", "detail": " int "},
    {"label": "alpha", "kind": 3, "sortText": "1", "insertTextFormat": 2,
     "insertText": "alpha(${1:x})$0"},
    {"label": "beta", "kind": 15, "sortText": "3", "filterText": "b",
     "textEdit": {"range": {"start": {"line": 2, "character": 4},
                            "end": {"line": 2, "character": 6}}, "newText": "beta()"}},
    {"label": "gamma", "sortText": "4", "textEdit": {"newText": "gam",
     "insert": {"start": {"line": 1, "character": 1}, "end": {"line": 1, "character": 2}},
     "replace": {"start": {"line": 1, "character": 1}, "end": {"line": 1, "character": 3}}}}]})
  doAssert items.len == 4
  doAssert items[0].label == "alpha" and items[0].text == "alpha(x)" and not items[0].edit
  doAssert items[1].label == "zeta" and items[1].text == "zeta" and items[1].detail == "int"
  doAssert items[2].text == "beta()" and items[2].edit and (items[2].line, items[2].col) == (2, 4)
  doAssert items[2].filterText == "b"
  doAssert items[3].text == "gam" and items[3].edit and (items[3].line, items[3].col) == (1, 1)
  doAssert parseCompletion(%*[{"label": "x", "insertText": "y"}])[0].text == "y"
  let inc = %*{"isIncomplete": true, "items": [{"label": "p", "additionalTextEdits": [
    {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
     "newText": "#include <p.h>\n"}]}]}
  doAssert incompleteList(inc) and not incompleteList(%*[]) and not incompleteList(nil)
  doAssert parseCompletion(inc)[0].extra == @[TextEdit(newText: "#include <p.h>\n")]
  doAssert items[0].extra.len == 0
  doAssert parseCompletion(newJNull()).len == 0
  doAssert [kindTag(3), kindTag(6), kindTag(2), kindTag(22), kindTag(14), kindTag(25),
    kindTag(15), kindTag(1)] == ["f", "v", "m", "c", "k", "t", "s", "o"]

# Locations: Location, Location[], LocationLink[] (targetSelectionRange), null.
block:
  let uri = uriOf(getTempDir() / "a.nim")
  let loc = %*{"uri": uri, "range": {"start": {"line": 3, "character": 5},
    "end": {"line": 3, "character": 8}}}
  let one = parseLocations(loc)
  doAssert one.len == 1 and one[0].path == absolutePath(getTempDir() / "a.nim") and
    (one[0].line, one[0].col) == (3, 5)
  doAssert parseLocations(%*[loc, loc]).len == 2
  let link = parseLocations(%*[{"targetUri": uri,
    "targetRange": {"start": {"line": 1, "character": 0}, "end": {"line": 9, "character": 0}},
    "targetSelectionRange": {"start": {"line": 2, "character": 7}, "end": {"line": 2, "character": 9}}}])
  doAssert (link[0].line, link[0].col) == (2, 7)
  doAssert parseLocations(newJNull()).len == 0 and parseLocations(%*[]).len == 0

# Formatting edits: reverse order, one undo step, the cursor kept on its text.
block:
  let b = newBuffer("a  \n漢😀 x  \nfoo")
  b.cursor = (2, 1)  # between f and oo
  let edits = parseEdits(%*[
    {"range": {"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 3}}, "newText": ""},
    {"range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 7}}, "newText": ""},
    {"range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 0}}, "newText": "1"},
    {"range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 0}}, "newText": "2\r\n"}])
  doAssert edits.len == 4 and edits[3].newText == "2\n"
  doAssert applyEdits(b, edits)
  doAssert b.text == "a\n漢😀 x\n12\nfoo", b.text
  doAssert b.cursor == (3, 1), $b.cursor
  doAssert b.modified
  discard b.command("undo")
  doAssert b.text == "a  \n漢😀 x  \nfoo" and b.cursor == (2, 1)
  doAssert not applyEdits(b, [])
  # A span around the cursor: it ends up inside the new text; a range past the end clamps.
  let c = newBuffer("hello world")
  c.cursor = (0, 8)
  doAssert applyEdits(c, parseEdits(%*[{"range": {"start": {"line": 0, "character": 6},
    "end": {"line": 5, "character": 0}}, "newText": "you"}]))
  doAssert c.text == "hello you" and c.cursor == (0, 8)
  # A replace and an insert at one start: the insert goes before the replacement.
  let d = newBuffer("0123456789")
  doAssert applyEdits(d, [TextEdit(col: 5, endCol: 8, newText: "y"), TextEdit(col: 5, endCol: 5, newText: "x")])
  doAssert d.text == "01234xy89", d.text
  # Overlapping edits are invalid: the earlier one is skipped instead of crashing.
  let e = newBuffer("0123456789")
  doAssert applyEdits(e, [TextEdit(col: 0, endCol: 9, newText: ""), TextEdit(col: 5, endCol: 9, newText: "")])
  doAssert e.text == "012349", e.text
  # A completion with a clangd-style '.' -> '->' fix beside it, the cursor after both.
  let f = newBuffer("p.fo")
  f.cursor = (0, 4)
  doAssert applyEdits(f, [TextEdit(col: 2, endCol: 4, newText: "foo"),
                          TextEdit(col: 1, endCol: 2, newText: "->")])
  doAssert f.text == "p->foo" and f.cursor == (0, 6), f.text

# Hover text: MarkupContent, MarkedString arrays, light de-markdown.
block:
  doAssert hoverLines(%*{"contents": {"kind": "markdown",
    "value": "### `foo`\n\n```nim\nproc foo(x: int)\n```\n\n\nDoes **x**.\n"}}) ==
    @["foo", "", "proc foo(x: int)", "", "Does **x**."]
  doAssert hoverLines(%*{"contents": ["plain", {"language": "c", "value": "int x"}]}) ==
    @["plain", "", "int x"]
  doAssert hoverLines(%*{"contents": "just text"}) == @["just text"]
  doAssert hoverLines(newJNull()).len == 0
  doAssert hoverLines(%*{"contents": {"kind": "plaintext", "value": ""}}).len == 0

# Views: diagnostic marks per rune, consult-flymake rows, M-? rows.
block:
  var lines: seq[seq[Rune]]
  for s in ["abcdef", "漢字", ""]: lines.add s.toRunes
  let ds = @[Diagnostic(line: 0, col: 1, endLine: 0, endCol: 4, severity: 2, message: "w"),
    Diagnostic(line: 0, col: 3, endLine: 1, endCol: 1, severity: 1, message: "e\nmore"),
    Diagnostic(line: 0, col: 6, endLine: 0, endCol: 6, severity: 4, message: "h"),
    Diagnostic(line: 9, col: 0, endLine: 9, endCol: 1, severity: 3, message: "gone")]
  let m = diagMarks(lines, ds)
  doAssert m.len == 3
  doAssert m[0] == @[0'i8, 2, 2, 1, 1, 1, 4], $m[0]  # an error wins; zero width at the end
  doAssert m[1] == @[1'i8, 0, 0] and m[2].len == 0, $m[1]
  var many: seq[Diagnostic]
  for l in [0, 11]: many.add Diagnostic(line: l, col: 2, severity: 1, message: "x\ny")
  many.add Diagnostic(line: 3, col: 0, severity: 3, message: "i")
  doAssert diagRows(many) == @["1:3   E  x", "12:3  E  x", "4:1   I  i"]
  let a = absolutePath("/p/a.nim")
  let z = absolutePath("/p/z.nim")
  let locs = @[Location(path: z, line: 0, col: 0), Location(path: a, line: 1, col: 3),
    Location(path: a, line: 0, col: 2), Location(path: z, line: 5, col: 0)]
  proc linesOf(p: string): seq[seq[Rune]] =
    if p == a: @["  x".toRunes, "😀 y x".toRunes] else: @["zz".toRunes]
  proc nameOf(p: string): string = extractFilename(p)
  let (ts, rows) = referenceRows(locs, linesOf, nameOf)
  doAssert rows == @["z.nim:1: zz", "z.nim:6: ", "a.nim:1: x", "a.nim:2: 😀 y x"], $rows
  doAssert ts[3] == Location(path: a, line: 1, col: 2) and ts[1].path == z  # rune column

let started = epochTime()
let deadline = started + 5
let fake = currentSourcePath().parentDir / "fake_lsp.py"

template waitUntil(c: Client, cond: untyped) =
  while not cond and epochTime() < deadline:
    discard c.poll()
    sleep(10)
  doAssert cond, astToStr(cond)

proc roundTrip(c: Client) =
  var initialized = false
  c.initialize(proc(res, error: JsonNode) = initialized = error == nil)
  c.waitUntil(c.state == lsReady)
  doAssert initialized and c.triggerCharacters == @["."]
  let uri = uriOf(getTempDir() / "fake doc:1.txt")  # published back as "fake%20doc:1.txt"
  var lines: seq[seq[Rune]]
  for s in ["x TODO y", "漢😀ERROR z", "pri"]: lines.add s.toRunes
  c.didOpen(uri, "plaintext", lines, 1)
  c.waitUntil(uri in c.diagnostics)
  let ds = c.diagnostics[uri]
  doAssert ds.len == 2, $ds
  doAssert ds[0].severity == 2 and ds[0].message == "todo left"
  doAssert (ds[0].line, ds[0].col, ds[0].endLine, ds[0].endCol) == (0, 2, 0, 6)
  doAssert ds[1].severity == 1 and ds[1].message == "error word" and ds[1].code == "7"
  doAssert (ds[1].line, ds[1].col, ds[1].endCol) == (1, 2, 7), $ds[1]  # UTF-16 3..8
  var items: seq[CompItem]
  var answered = false
  c.request("textDocument/completion", %*{"textDocument": {"uri": uri},
    "position": {"line": 2, "character": 3}}, proc(res, error: JsonNode) =
      answered = true
      items = parseCompletion(res))
  c.waitUntil(answered)
  var texts: Table[string, CompItem]
  for it in items: texts[it.label] = it
  doAssert "printf" in texts and "target" notin texts, $items
  doAssert texts["printf"].text == "printf(fmt, a)" and not texts["printf"].edit
  doAssert texts["print"].text == "print()" and texts["print"].edit and
    (texts["print"].line, texts["print"].col) == (2, 0)
  # Hover, definition, references and formatting on a second document.
  let uri2 = uriOf(getTempDir() / "fake doc 2.txt")
  var doc = newBuffer("x = target  \n漢 target(x)\nend")
  c.didOpen(uri2, "plaintext", doc.lines, 1)
  proc ask(meth: string, params: JsonNode): JsonNode =
    var got = false
    var answer: JsonNode
    c.request(meth, params, proc(res, error: JsonNode) =
      doAssert error == nil, $error
      answer = res
      got = true)
    c.waitUntil(got)
    answer
  let at = %*{"textDocument": {"uri": uri2}, "position": {"line": 1, "character": 3}}
  doAssert hoverLines(ask("textDocument/hover", at)) == @["hover for target"]
  let def = parseLocations(ask("textDocument/definition", at))
  doAssert def.len == 1 and def[0].path == pathOf(uri2) and (def[0].line, def[0].col) == (0, 4)
  let refs = parseLocations(ask("textDocument/references", at))
  doAssert refs.len == 2 and (refs[1].line, refs[1].col) == (1, 2), $refs
  doAssert runeCol(doc.lines[1], refs[1].col) == 2
  doc.cursor = (2, 3)
  doAssert applyEdits(doc, parseEdits(ask("textDocument/formatting",
    %*{"textDocument": {"uri": uri2}, "options": {"tabSize": 4, "insertSpaces": true}})))
  doAssert doc.text == "x = target\n漢 target(x)\nend" and doc.cursor == (2, 3)
  # A request unanswered past its deadline is dropped, its callback never run.
  var late = false
  c.request("test/hang", newJObject(), proc(res, error: JsonNode) = late = true)
  doAssert c.expire(10).len == 0
  sleep(30)
  doAssert c.expire(0.02) == @["test/hang"]
  doAssert c.expire(0.02).len == 0 and not late
  # An edit removing the words clears the diagnostics.
  let gen = c.generation
  c.didChange(uri, @["clean".toRunes], 2)
  c.waitUntil(c.generation > gen)
  doAssert c.diagnostics[uri].len == 0

if findExe("python3").len == 0:
  echo "note: python3 not found; live LSP round trips skipped"
else:
  let c = newClient("python3 " & fake, getTempDir(), "test")
  doAssert c.state == lsStarting, c.lastError
  doAssert c.logPath.endsWith("-" & $getCurrentProcessId() & ".log") and fileExists(c.logPath)
  roundTrip(c)
  shutdown(c)
  doAssert c.state == lsStopped and c.exitCode == 0, $c.exitCode
  doAssert not fileExists(c.logPath)

  # A document larger than a pipe sent while the server is blocked writing to us: the
  # write is queued instead of deadlocking, and goes out as poll drains the server.
  block:
    let big = newClient("python3 " & fake, getTempDir(), "test-big")
    big.initialize()
    big.waitUntil(big.state == lsReady)
    var lines: seq[seq[Rune]]
    for i in 0..<4000: lines.add "TODO ERROR TODO ERROR x".toRunes  # 96 KB, 16000 diagnostics
    let uri = uriOf(getTempDir() / "big.txt")
    big.didOpen(uri, "plaintext", lines, 1)
    sleep(300)  # the server is writing its diagnostics, which nobody reads yet
    let t0 = epochTime()
    big.didChange(uri, lines & @["TODO".toRunes], 2)
    doAssert epochTime() - t0 < 0.5
    big.waitUntil(big.diagnostics.getOrDefault(uri).len == 16001)
    shutdown(big)
    doAssert big.exitCode == 0

  when defined(linux):  # SIGPIPE is blocked here, and children get it as we inherited it
    proc sigpipe(status, field: string): bool =
      for line in status.splitLines:
        if line.startsWith(field & ":"): return (parseHexInt(line.split('\t')[^1]) and (1 shl 12)) != 0
    let own = readFile("/proc/self/status")
    let (child, _) = execCmdEx("cat /proc/self/status")
    doAssert sigpipe(own, "SigBlk") and not sigpipe(child, "SigBlk")
    doAssert sigpipe(child, "SigIgn") == sigpipe(own, "SigIgn")

  # The same over TCP, as Godot's GDScript server is reached.
  let port = 20000 + getCurrentProcessId() mod 20000
  let server = startProcess(findExe("python3"), args = [fake, "--tcp", $port])
  setServer("Test", "tcp://127.0.0.1:" & $port)
  while serverFor("Test").len == 0 and epochTime() < deadline: sleep(20)  # until it listens
  let t = newClient(serverFor("Test"), getTempDir(), "test-tcp")
  doAssert t.state == lsStarting, t.lastError
  roundTrip(t)
  shutdown(t)
  doAssert t.state == lsStopped
  server.terminate()
  discard server.waitForExit()
  server.close()

  # A server that exits fails its pending requests.
  let dead = newClient("python3 -c pass", getTempDir(), "test-dead")
  var failure = ""
  dead.initialize(proc(res, error: JsonNode) = failure = error{"message"}.getStr)
  dead.waitUntil(dead.state == lsFailed)
  doAssert failure == "Server exited" and dead.lastError == failure, failure
  shutdown(dead)
  doAssert dead.state == lsStopped

  # A missing executable and a refused port fail without raising.
  doAssert newClient("definitely-not-a-server-xyz", getTempDir()).state == lsFailed
  doAssert newClient("tcp://127.0.0.1:1", getTempDir()).state == lsFailed

doAssert epochTime() - started < 5
echo "All lsp checks passed"
