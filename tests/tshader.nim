import std/strutils
import ../src/shadersrc

let toy = "void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n  fragColor = vec4(1.0);\n}\n"
let src = fragmentSource(toy)
doAssert src.startsWith(glslVersion & "\n")
doAssert "uniform float iTime;" in src and "out vec4 darger_fragColor;" in src
doAssert src.endsWith(footer)  # a mainImage file gets the entry point
doAssert src.count("#version") == 1

let full = "#version 330\nout vec4 c;\nvoid main() { c = vec4(0.0); }\n"
let compiled = fragmentSource(full)
doAssert compiled.count("#version") == 1 and compiled.startsWith(glslVersion)  # ours replaces theirs
doAssert "void main() { c = vec4(0.0); }" in compiled and footer notin compiled
doAssert compiled.splitLines.len == full.splitLines.len + headerLines()  # line count kept for the log

let log = "ERROR: 0:" & $(headerLines() + 3) & ": 'foo' : undeclared identifier\nWARNING: 0:" & $(headerLines() + 1) & ": unused\n"
doAssert userLog(log) == "ERROR: line 3: 'foo' : undeclared identifier\nWARNING: line 1: unused"
doAssert userLog("ERROR: 0:2: in the header") == "ERROR: line 1: in the header"
echo "shader source ok"
