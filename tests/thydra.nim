import std/strutils
import ../src/hydra

let heads = @[Head(key: "o", command: "other-window", hint: "other"),
              Head(key: "2", command: "split-window-below", hint: "split below"),
              Head(key: "3", command: "split-window-right", hint: "split right"),
              Head(key: "1", command: "delete-other-windows", hint: "only", exit: true),
              Head(key: "q", command: "", hint: "quit", exit: true)]
let lines = hintLines("windows", heads, 40)
doAssert lines[0] == "windows"
doAssert lines[1] == "[o] other        [2] split below", lines[1]   # columns of equal width, two per 40 cells
doAssert lines[2] == "[3] split right  [1] only"
doAssert lines[3] == "[q] quit"
doAssert lines[^1] == "other keys leave; 1 q run and leave"
doAssert hintLines("", heads[0..1], 80) == @["[o] other        [2] split below", "other keys leave"]
doAssert hintLines("t", @[]) == @["t"]
doAssert summary("zoom", @[Head(key: "g", hint: "in"), Head(key: "l", hint: "out")]) == "zoom  g:in  l:out"
let wide = hintLines("", @[Head(key: "a", hint: "日本語の説明"), Head(key: "b", hint: "x")], 40)
doAssert wide[0] == "[a] 日本語の説明  [b] x", wide[0]   # CJK width counted
echo "hydra ok"
