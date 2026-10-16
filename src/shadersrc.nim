## Background shader sources: a Shadertoy-style `mainImage` file, or a whole fragment
## shader, becomes the GLSL darger compiles; GL's error log gets the file's line numbers.
import std/[strutils, re]

const
  glslVersion* = "#version 410 core"
  header* = glslVersion & "\n" &
    "uniform vec3 iResolution;\n" &   # viewport in pixels (z = 1)
    "uniform float iTime;\n" &        # seconds since the shader was applied
    "uniform vec4 iMouse;\n" &        # pointer in pixels, origin bottom left (zw unused)
    "uniform int iFrame;\n" &
    "out vec4 darger_fragColor;\n"
  footer* = "\nvoid main() { mainImage(darger_fragColor, gl_FragCoord.xy); }\n"

proc headerLines*(): int =
  for c in header:
    if c == '\n': inc result

proc fragmentSource*(user: string): string =
  ## The user's text under the header; a `#version` of its own is dropped, and a file
  ## without `void main` gets the Shadertoy entry point appended.
  var body: seq[string]
  for line in user.splitLines:
    if line.strip.startsWith("#version"): body.add ""  # keep the line count
    else: body.add line
  result = header & body.join("\n")
  if not user.contains(re"void\s+main\s*\("): result.add footer

proc userLog*(log: string): string =
  ## GL's `ERROR: 0:12: ...` refers to the combined source; shift to the user's file.
  let shift = headerLines()
  var lines: seq[string]
  for line in log.strip.splitLines:
    var done = false
    for kind in ["ERROR", "WARNING"]:
      let prefix = kind & ": 0:"
      if line.startsWith(prefix):
        let rest = line[prefix.len..^1]
        let colon = rest.find(':')
        if colon > 0 and rest[0..<colon].allCharsInSet({'0'..'9'}):
          lines.add kind & ": line " & $max(1, parseInt(rest[0..<colon]) - shift) & ":" & rest[colon+1..^1]
          done = true
          break
    if not done: lines.add line
  lines.join("\n")
