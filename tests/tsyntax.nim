import std/[unicode, strutils, times]
import ../src/syntax

proc toLines(src: string): seq[seq[Rune]] =
  for line in src.split('\n'): result.add line.toRunes

proc face(path, src, needle: string, nth = 1): Face =
  ## The face of the first rune of the nth occurrence of needle.
  let lines = toLines(src)
  let faces = detect(path, $lines[0]).highlight(lines)
  var seen = 0
  let rows = src.split('\n')
  for n, line in rows:
    var at = line.find(needle)
    while at >= 0:
      inc seen
      if seen == nth: return faces[n][line[0..<at].runeLen]
      at = line.find(needle, at + 1)
  raise newException(KeyError, "not found: " & needle)

proc check(path, src: string, expect: openArray[(string, Face)]) =
  for (needle, f) in expect:
    let got = face(path, src, needle)
    doAssert got == f, path & ": " & needle & " is " & $got & ", expected " & $f

# Detection by extension (any case), file name and shebang.
doAssert detect("/a/b.nim", "").name == "Nim"
doAssert detect("X.PY", "").name == "Python"
doAssert detect("/p/Gemfile", "").name == "Ruby"
doAssert detect("a.tsx", "").name == "JS/TS"
doAssert detect("a.hpp", "").name == "C/C++"
doAssert detect("init.el", "").name == "Lisp"
doAssert detect("c.yml", "").name == "YAML"
doAssert detect("c.toml", "").name == "TOML"
doAssert detect("notes.org", "").name == "Org"
doAssert detect("run", "#!/usr/bin/env python3").name == "Python"
doAssert detect("run", "#!/bin/bash -e").name == "Shell"
doAssert detect("run", "#!/usr/bin/ruby").name == "Ruby"
doAssert detect("a.txt", "#!").name == "Text"
doAssert detect("", "").name == "Text"

# Shape: one face per rune per line, including Unicode.
let sample = "proc f(x: int) =\n  echo \"日本\" # コメント\n\n"
let shaped = detect("a.nim", "").highlight(toLines(sample))
doAssert shaped.len == toLines(sample).len
for n, line in toLines(sample): doAssert shaped[n].len == line.len
for row in detect("a.txt", "").highlight(toLines(sample)):
  for f in row: doAssert f == fPlain

check("a.nim", """
proc greet*(name: string): int =
  ## doc
  let x = 42 # note
  echo "hi\" there", 'c', 1'u8
  #[ block
  still ]# discard nil
  var s = r"C:\x"
  let t = TQ
multi "line"
TQ & $x
type
  Foo = object
  bar(Foo(), true)
  1..9""".replace("TQ", "\"\"\""), {"proc": fKeyword, "greet": fFnname, "string": fType, "## doc": fComment,
    "x =": fVariable, "42": fConstant, "# note": fComment, "echo": fBuiltin,
    "\"hi": fString, "there": fString, "'c'": fString, "1'u8": fConstant,
    "#[": fComment, "still": fComment, "discard": fKeyword, "nil": fConstant,
    "r\"C": fString, "multi": fString, "\"line": fString, "& $x": fPlain, "Foo =": fType,
    "bar": fFnname, "true": fConstant, "1..9": fConstant, "..9": fPlain})

check("a.py", "def run(self):\n    '''doc\n    more'''\n    return None  # c\nclass Foo:\n    print(f\"{x}\")",
  {"def": fKeyword, "run": fFnname, "more": fString, "return": fKeyword, "None": fConstant,
   "# c": fComment, "Foo": fType, "print": fBuiltin})

check("a.rb", "def hi\n  @name = :sym\n  puts \"x\" # c\nend\n=begin\nblock\n=end",
  {"def": fKeyword, "hi": fFnname, "@name": fVariable, ":sym": fConstant, "puts": fBuiltin,
   "\"x\"": fString, "# c": fComment, "block": fComment, "end": fKeyword})

check("a.gd", "extends Node\nfunc _ready():\n\tvar speed = 1.5\n\tprint(\"go\") # c",
  {"extends": fKeyword, "Node": fType, "_ready": fFnname, "speed": fVariable, "1.5": fConstant,
   "\"go\"": fString, "# c": fComment})

check("a.ts", "function add(a: number) {\n  /* multi\n  line */ const s = `tpl\n${a}`\n  return null // c\n}",
  {"function": fKeyword, "add": fFnname, "number": fType, "multi": fComment, "line": fComment,
   "const": fKeyword, "`tpl": fString, "${a}`": fString, "null": fConstant, "// c": fComment})

check("a.c", "#include <stdio.h>\nint main(void) {\n  char c = 'x'; /* c */\n  printf(\"%d\\n\", 10);\n}",
  {"#include": fBuiltin, "<stdio": fString, "int": fType, "main": fFnname, "'x'": fString,
   "/* c": fComment, "printf": fBuiltin, "\"%d": fString, "10": fConstant})

check("a.rs", "fn longest<'a>(x: &'a str) -> String {\n  /* a /* nested */ still */\n  println!(\"{}\", x);\n  let c = 'z';\n}",
  {"fn": fKeyword, "longest": fFnname, "'a>": fPlain, "str": fType, "String": fType,
   "still": fComment, "println!": fBuiltin, "\"{}\"": fString, "'z'": fString})

check("a.go", "package main\nfunc main() {\n\ts := `raw\nline`\n\tfmt.Println(len(s), nil)\n}",
  {"package": fKeyword, "main()": fFnname, "`raw": fString, "line`": fString,
   "Println": fFnname, "len": fBuiltin, "nil": fConstant})

check("a.sh", "#!/bin/sh\nif [ -n \"$HOME\" ]; then\n  echo ${USER} $1 # c\nfi\nx=a#b",
  {"#!/bin": fComment, "if": fKeyword, "\"$HOME": fString, "echo": fBuiltin, "${USER}": fVariable,
   "$1": fVariable, "# c": fComment, "fi": fKeyword, "#b": fPlain})

check("init.el", "(defun my-fn (arg)\n  \"Doc\nstring.\"\n  (setq x (my-helper \"%s\" arg)) ; c\n  (use-package foo :ensure t))",
  {"defun": fKeyword, "my-fn": fFnname, "arg)": fPlain, "\"Doc": fString, "string.": fString,
   "setq": fKeyword, "my-helper": fFnname, "; c": fComment, "use-package": fKeyword,
   ":ensure": fConstant, "t))": fConstant})

check("a.json", "{\n  \"key\": \"value\",\n  \"n\" : -1.5, \"ok\": true, \"z\": null\n}",
  {"\"key\"": fVariable, "\"value\"": fString, "\"n\"": fVariable, "1.5": fConstant,
   "true": fConstant, "null": fConstant})

check("a.yaml", "# top\nname: \"x\"\nsteps:\n  - run-on: yes # c\n  - 'q'",
  {"# top": fComment, "name": fVariable, "\"x\"": fString, "run-on": fVariable, "yes": fConstant,
   "# c": fComment, "'q'": fString})

check("a.toml", "[package]\nversion = \"1.0\"\nport = 8080",
  {"[package]": fKeyword, "version": fVariable, "\"1.0\"": fString, "8080": fConstant})

check("a.md", "# Title\ntext `code` and [link](http://u) **bold** *em*\n* item\n```nim\nproc x\n```\nafter",
  {"# Title": fKeyword, "text": fPlain, "`code`": fString, "[link]": fVariable, "(http": fComment,
   "**bold**": fConstant, "*em*": fConstant, "* item": fPlain, "```nim": fComment,
   "proc x": fString, "after": fPlain})

check("a.org", "* TODO Heading\n#+title: T\nsee [[https://x][x]] and =verb= ~code~ *b*\n#+BEGIN_SRC nim\necho 1\n#+end_src\nplain",
  {"* TODO": fKeyword, "TODO": fConstant, "Heading": fKeyword, "#+title": fComment,
   "[[https": fVariable, "=verb=": fString, "~code~": fString, "*b*": fConstant,
   "#+BEGIN": fComment, "echo 1": fString, "#+end_src": fComment, "plain": fPlain})

# Regressions: tokens that used to flip string/code parity for the rest of the file.
check("init.el", "(eq c ?\\\")\n(setq x 1) ; c\n(eq c ?\")\n(foo ?\\; ?a)\n(bar)",
  {"?\\\"": fConstant, "setq": fKeyword, "; c": fComment, "?\")": fConstant, "foo": fFnname,
   "?\\;": fConstant, "?a": fConstant, "bar": fFnname})
check("a.nim", "let s = r\"\"\"\nproc x = 1\n\"\"\"\nlet y = 2",
  {"proc x": fString, "let y": fKeyword, "2": fConstant})
check("a.md", "````\n```\ninside\n````\nafter", {"inside": fString, "after": fPlain})
check("a.md", "1. Install:\n    ```sh\n    # install deps\n    ```\n    # not heading\n~~~\nx\n~~~\ny",
  {"```sh": fComment, "# install": fString, "# not": fPlain, "x": fString, "y": fPlain})
check("a.sh", "cat <<EOF\nDon't do that\nEOF\necho hi # c\ncat <<-'END'\n\tit's\n\tEND\necho $'it\\'s'\necho after",
  {"EOF": fString, "Don't": fString, "echo hi": fBuiltin, "# c": fComment, "'END'": fString,
   "it's": fString, "$'it": fString, "echo after": fBuiltin})
check("a.sh", "echo $((1<<2))\ny=1", {"y=": fPlain})
check("a.yaml", "name: Don't panic\nnext: 1", {"Don't": fPlain, "next": fVariable})
check("a.toml", "desc = \"\"\"\nhello = world\n\"\"\"\nlit = '''\na = b\n'''\nport = 1",
  {"hello": fString, "a = b": fString, "port": fVariable, "1": fConstant})
check("a.rb", "v=begin\n  1\nrescue\nend", {"1": fConstant, "rescue": fKeyword})
check("a.org", "#+begin_src org\n#+begin_example\nx\n#+end_example\nstill src\n#+END_SRC\nplain",
  {"still": fString, "#+END_SRC": fComment, "plain": fPlain})
check("a.py", "x = 1e-3 + 1.5E+10 - 0xE-1", {"-3": fConstant, "+10": fConstant, "-1": fPlain})

# Unmatched emphasis and '[' openers stay linear on a long line.
let longMd = toLines("*a [".repeat(20_000))
let longOrg = toLines("=a [[".repeat(15_000))
let t0 = cpuTime()
discard detect("a.md", "").highlight(longMd)
discard detect("a.org", "").highlight(longOrg)
doAssert cpuTime() - t0 < 0.5, "long markdown/org lines took " & $(cpuTime() - t0) & " s"

# Speed: O(total runes), a 3000-line file in a few ms (release); the bound is loose for debug.
var big: seq[string]
for i in 0..<750:
  big.add "proc f" & $i & "*(x: int): string = # comment " & $i
  big.add "  let s = \"string with \\\" escape\" & $x"
  big.add "  #[ block\n  ]# echo 12_345, 'c', nil"
let bigLines = toLines(big.join("\n"))
doAssert bigLines.len == 3000
let lang = detect("big.nim", "")
let start = cpuTime()
let bigFaces = lang.highlight(bigLines)
let elapsed = cpuTime() - start
doAssert bigFaces.len == 3000
doAssert elapsed < 0.5, "highlighting 3000 lines took " & $elapsed & " s"
echo "3000 lines in ", formatFloat(elapsed * 1000, ffDecimal, 1), " ms"
echo "All syntax checks passed"
