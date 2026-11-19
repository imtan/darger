import std/[unicode, strutils, sequtils]
import ../src/[dumbjump, syntax, grep]

proc lines(s: string): seq[seq[Rune]] =
  s.split('\n').mapIt(it.toRunes)
proc defs(s, name: string, path = "/p/test.nim"): seq[Hit] =
  definitions(lines(s), detect(path, ""), name, path)
proc yes(s, name, path: string, line = 0, col = -1) =
  let hits = defs(s, name, path)
  doAssert hits.len == 1, s & " => " & $hits
  doAssert hits[0].line == line, s & " => " & $hits
  if col >= 0: doAssert hits[0].col == col, s & " => " & $hits
proc no(s, name, path: string) =
  doAssert defs(s, name, path).len == 0, s & " => " & $defs(s, name, path)

for kind in ["proc", "func", "method", "iterator", "template", "macro", "converter"]:
  yes(kind & " needle*(x: int): int = x", "needle", "a.nim", col = kind.len + 1)
for kind in ["var", "let", "const"]:
  yes(kind & " needle = 1", "needle", "a.nim")
  yes(kind & "\n  needle = 1", "needle", "a.nim", 1, 2)
  yes(kind & "\n  other, needle: int", "needle", "a.nim", 1)
yes("type\n  Needle* = object\n    field*: int", "Needle", "a.nim", 1, 2)
yes("type\n  Needle = object\n    field*: int", "field", "a.nim", 2, 4)
yes("type Needle = object\n  other, field*: int", "field", "a.nim", 1)
yes("proc f*(\n    first, needle: int; other: string\n): int = needle", "needle", "a.nim", 1)
yes("proc f[T](needle: T = default(T)) = discard", "needle", "a.nim")
yes("for index, needle in pairs(xs):\n  echo needle", "needle", "a.nim")
yes("let 日本語 = 1", "日本語", "a.nim", col = 4)
for code in ["# let needle = 1", "#[\nlet needle = 1\n]#", "let s = \"let needle = 1\"",
    "let s = \"\"\"\nlet needle = 1\n\"\"\"", "echo needle", "foo(needle: 1)", "needle == 1"]:
  no(code, "needle", "a.nim")
for code in ["def needle(x): pass", "class needle: pass", "needle = 1", "needle: int = 1", "async def f(needle=1): pass"]:
  yes(code, "needle", "a.py")
yes("def f(\n    needle: int = 1,\n): pass", "needle", "a.py", 1)
no("# needle = 1\ns = '''\nneedle = 1\n'''\nprint(needle)\nneedle == 1", "needle", "a.py")
for code in ["function needle() {}", "export async function needle() {}", "class needle {}",
    "const needle = () => 1", "let needle = 1", "var needle;", "type needle = string;",
    "export interface needle {}", "  async needle(x: number): void {}", "function f(needle = 1) {}",
    "const f = function (needle) {};", "const f = (needle: number) => needle;", "const f = needle => needle;"]:
  yes(code, "needle", "a.ts")
no("// const needle = 1\n/*\nfunction needle() {}\n*/\nconst s = `\nlet needle = 1\n`;\nneedle();", "needle", "a.js")
for code in ["int needle = 1;", "void needle(int x) {}", "struct needle {};",
    "class needle {};", "typedef int needle;", "void f(int needle) {}"]:
  yes(code, "needle", "a.cpp")
no("return needle();\nprintf(needle);\n// int needle;\n/* int needle; */", "needle", "a.c")
for code in ["pub fn needle() {}", "pub(crate) fn needle() {}", "struct needle {}",
    "let mut needle = 1;", "static mut needle: i32 = 1;", "const needle: i32 = 1;", "fn f(needle: i32) {}"]:
  yes(code, "needle", "a.rs")
for code in ["func needle() {}", "func (s *Server) needle() {}", "type needle struct {}",
    "var needle int", "needle := 1", "func f(needle int) {}"]:
  yes(code, "needle", "a.go")
yes("var (\n  needle int\n)", "needle", "a.go", 1)
for code in ["needle() { :; }", "function needle { :; }", "needle=1", "local needle=1", "export needle=1", "readonly needle=1"]:
  yes(code, "needle", "a.sh")
for kind in ["defun", "defvar", "setq", "defcustom"]:
  yes("(" & kind & " needle-name nil)", "needle-name", "a.el")
no("; (defvar needle 1)\n(message \"(defvar needle 1)\")", "needle", "a.el")
for code in ["def needle(x)", "class needle", "needle = 1", "def f(needle)"]:
  yes(code, "needle", "a.rb")
yes("def needle?(x)", "needle?", "a.rb")
yes("@needle = 1", "@needle", "a.rb")
yes("function needle() {}", "needle", "a.unknown")
no("// function needle() {}\ns = \"function needle() {}\"", "needle", "a.unknown")

block symbols:
  doAssert symbolAt("(needle-name x)".toRunes, 7, "Lisp") == "needle-name"
  doAssert symbolAt("needle".toRunes, 6, "Nim") == "needle"
  doAssert symbolAt("日本語()".toRunes, 1, "Nim") == "日本語"
  doAssert symbolAt("   ".toRunes, 1, "Nim") == ""
block ranking:
  let source = "let needle = 1\nproc f(needle: int) =\n  let needle = 2\n  echo needle\nlet needle = 3"
  let all = defs(source, "needle")
  let ranked = rankDefinitions(all, "/p/test.nim", 3, 9, "needle")
  doAssert ranked.mapIt(it.line) == @[2, 1, 0, 4], $ranked
  doAssert rankDefinitions(all, "/p/test.nim", 2, 8, "needle").mapIt(it.line) == @[1, 0, 4]
  let mixed = all & @[Hit(path: "/q/a.nim"), Hit(path: "/p/z.nim"), Hit(path: "/p/a.nim")]
  let sorted = rankDefinitions(mixed & mixed, "/p/test.nim", 3, 9, "needle")
  doAssert sorted.len == 7
  doAssert sorted[4..6].mapIt(it.path) == @["/p/a.nim", "/p/z.nim", "/q/a.nim"]
block outline:
  let lines = "proc alpha(x: int) =\n  let beta = x\n  echo beta\nproc unfinished".splitLines.mapIt(it.toRunes)
  let hits = definitions(lines, detect("outline.nim", ""), "", "outline.nim", all = true)
  doAssert hits.len >= 3
  doAssert hits.anyIt(it.line == 0) and hits.anyIt(it.line == 1)
  doAssert definitions(lines, detect("outline.nim", ""), "", "outline.nim").len == 0
  discard definitions(@["proc".toRunes], detect("broken.nim", ""), "", "broken.nim", all = true)
echo "dumbjump ok"
