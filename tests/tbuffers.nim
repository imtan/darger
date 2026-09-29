import std/os
import ../src/[buffer, buffers]

proc file(path: string): Buffer =
  result = newBuffer()
  result.path = path

var reg: Registry
doAssert reg.other == nil
let scratch = newBuffer()
reg.add scratch
reg.touch scratch
doAssert reg.names == @["*scratch*"]
doAssert reg.other == nil

let a = file("/p/src/darger.nim")
let c = file("/p/tests/darger.nim")
let n = file("/p/README.md")
reg.add a
doAssert reg.displayName(a) == "darger.nim"
reg.add c
reg.add n
doAssert reg.displayName(a) == "darger.nim<src>"
doAssert reg.displayName(c) == "darger.nim<tests>"
doAssert reg.displayName(n) == "README.md"

# MRU: added buffers start least recent; touch moves to the front.
doAssert reg.names == @["*scratch*", "darger.nim<src>", "darger.nim<tests>", "README.md"]
reg.touch n
reg.touch a
doAssert reg.current == a
doAssert reg.other == n
doAssert reg.names[0..1] == @["darger.nim<src>", "README.md"]

# Deeper uniquify when parents match; identical paths fall back to <N>.
let d = file("/q/src/darger.nim")
reg.add d
doAssert reg.displayName(a) == "darger.nim<p/src>"
doAssert reg.displayName(d) == "darger.nim<q/src>"
doAssert reg.displayName(c) == "darger.nim<tests>"
reg.remove d
doAssert reg.displayName(a) == "darger.nim<src>"

# Several scratch-like buffers and a typed name.
let s2 = newBuffer()
reg.add s2
doAssert reg.displayName(s2) == "*scratch*<2>"
let named = newBuffer()
reg.add(named, "notes")
doAssert reg.displayName(named) == "notes"
doAssert reg.byName("notes") == named
doAssert reg.byName("*scratch*<2>") == s2
doAssert reg.byName("nope") == nil

# remove keeps the remaining order; other() follows MRU.
reg.remove a
doAssert reg.current == n
doAssert reg.displayName(c) == "darger.nim"
doAssert reg.names == @["README.md", "*scratch*", "darger.nim", "*scratch*<2>", "notes"]
doAssert reg.other == scratch

# Creation-order cycling wraps.
doAssert reg.cycle(scratch, 1) == c
doAssert reg.cycle(scratch, -1) == named
doAssert reg.cycle(named, 1) == scratch

# byPath compares normalized absolute paths.
let rel = file(absolutePath("sub/x.txt"))
reg.add rel
doAssert reg.byPath("sub/../sub/x.txt") == rel
doAssert reg.byPath("/p/README.md") == n
doAssert reg.byPath("/p/other") == nil
doAssert reg.len == 6
echo "buffers ok"
