import std/[strutils, sequtils]
import ../src/[compilation, termtext]

for (text, path, line, col) in [
    ("src/main.nim(12, 5) Error: undeclared identifier", "src/main.nim", 11, 4),
    ("src/main.nim(2, 1) Warning: unused", "src/main.nim", 1, 0),
    ("/tmp/a.nim(3, 2) Hint: declared", "/tmp/a.nim", 2, 1),
    ("a.c:4:7: error: expected", "a.c", 3, 6),
    ("  --> src/main.rs:8:9", "src/main.rs", 7, 8),
    ("./main.go:3:2: undefined", "./main.go", 2, 1),
    ("src/a.ts:2:3: error TS123", "src/a.ts", 1, 2),
    ("src/a.ts(2,3): error TS123", "src/a.ts", 1, 2),
    ("  File \"my code/a.py\", line 6, in run", "my code/a.py", 5, 0),
    ("    at fn (/tmp/my code/a.js:6:10)", "/tmp/my code/a.js", 5, 9),
    ("    at /tmp/a.js:6:10", "/tmp/a.js", 5, 9),
    ("src/a.txt:22: message", "src/a.txt", 21, 0),
    ("日本語.nim(2, 3) Error: test", "日本語.nim", 1, 2)]:
  let hit = parseLocation(text, "/project", 8)
  let expected = if path.startsWith("/"): path else: "/project/" & path.replace("./", "")
  doAssert hit.path == expected and hit.line == line and hit.col == col and hit.row == 8, text & " -> " & $hit
doAssert parseLocation("a.nim(1, 1) Warning: unused", "/").severity == csWarning
doAssert parseLocation("a.nim(1, 1) Hint: unused", "/").severity == csHint
for text in ["", "ordinary text", "a:0:2: error", "a:2:0: error", "a(-1, 3) Error:",
             "a:9999999999999999999999999: error", "  File \"<stdin>\", line 3", "https://host/a:2:3:"]:
  doAssert parseLocation(text, "/").path == "", text
doAssert guessCommand(@[]) == "make"
for (name, command) in [("darger.nimble", "nimble build"), ("package.json", "npm test"),
    ("Cargo.toml", "cargo build"), ("go.mod", "go build ./..."), ("Makefile", "make")]:
  doAssert guessCommand([name]) == command
doAssert guessCommand(["Makefile", "package.json", "darger.nimble"]) == "nimble build"

var terminal: TermText
terminal.feed("\e[31msrc/a.nim(2,")
terminal.feed(" 1) Error: 日本")
terminal.feed("語\e[0m\r\n")
doAssert locations(terminal.text.splitLines, "/project").len == 1
var lines = toSeq(0..<500).mapIt("log " & $it)
lines[10] = "a.nim(21, 2) Error: early"
lines[300] = "b.nim(2, 1) Warning: late"
let errors = locations(lines, "/project")
let rows = failureRows(lines, errors)
doAssert rows.len == 200 and rows[^1] == 499
for row in 8..12: doAssert row in rows
doAssert failureRows(@[], @[]).len == 0
doAssert failureRows(lines, errors, 0).len == 0
let context = sourceContext("/project/a.nim", toSeq(1..100).mapIt("code " & $it).join("\n"), errors)
doAssert "1: code 1\n" in context and "41: code 41\n" in context and "42: code 42\n" notin context
let prompt = failurePrompt("nimble build", "/project", 1, lines, errors)
doAssert "Command: nimble build" in prompt and "Exit code: 1" in prompt
doAssert "a.nim(21, 2) Error: early" in prompt and "log 499" in prompt
echo "compilation locations, command guesses, terminal output and bounded failure context ok"
