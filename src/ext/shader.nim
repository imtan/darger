## Background shader: a GLSL file (Shadertoy-style mainImage or a whole fragment
## shader) drawn under the text with the theme's background laid over it, as the
## NeoEmacs frame shader did. In a GLSL buffer C-c C-c applies the buffer, C-c C-o
## toggles between the picture alone and the dimmed background, C-c C-k clears it;
## saving the applied file, or changing it on disk, re-applies it, so a shader can be
## written while it runs. Compile errors go to the echo line and a *shader* buffer.
import std/[os, times, strutils, tables]
import opengl, windy
import ../[core, buffer, buffers, lisp, shadersrc]

const vertexSource = glslVersion & """

void main() {  // one triangle covering the viewport
  vec2 p = vec2(float(gl_VertexID & 1) * 4.0 - 1.0, float(gl_VertexID & 2) * 2.0 - 1.0);
  gl_Position = vec4(p, 0.0, 1.0);
}
"""

var
  program: GLuint          # 0 = none
  vao: GLuint
  shaderPath: string       # the file applied (re-applied when it changes), "" = applied from a buffer
  shaderStamp: Time
  started: float
  frame: int
  dimmed = true            # C-c C-o: false shows the picture alone
  checked: float

proc dim(): float32 =
  try: interp.env.values["background-shader-dim"].asNumber.float32
  except CatchableError, KeyError: 0.6'f32

proc compileStage(kind: GLenum, source: string): tuple[id: GLuint, log: string] =
  result.id = glCreateShader(kind)
  var src = allocCStringArray([source])
  defer: deallocCStringArray(src)
  glShaderSource(result.id, 1, src, nil)
  glCompileShader(result.id)
  var ok: GLint
  glGetShaderiv(result.id, GL_COMPILE_STATUS, addr ok)
  if ok == 0:
    var length: GLint
    glGetShaderiv(result.id, GL_INFO_LOG_LENGTH, addr length)
    var buf = newString(max(1, length))
    glGetShaderInfoLog(result.id, length, nil, cstring(buf))
    result.log = userLog(buf)
    glDeleteShader(result.id)
    result.id = 0

proc report(text: string) =
  ## The log in a *shader* buffer (reachable with C-x b), the first line in the echo area.
  var buf = reg.byName("*shader*")
  if buf == nil:
    buf = newBuffer()
    reg.add(buf, "*shader*")
  buf.snapshot()
  buf.splice(0, buf.text.runeLen, text)
  buf.cursor = (0, 0)
  buf.modified = false
  echoLine = text.splitLines[0]

proc drawBackground() =
  if program == 0: return
  let size = window.size
  glUseProgram(program)
  glUniform3f(glGetUniformLocation(program, "iResolution"), size.x.GLfloat, size.y.GLfloat, 1)
  glUniform1f(glGetUniformLocation(program, "iTime"), (epochTime() - started).GLfloat)
  let m = window.mousePos
  glUniform4f(glGetUniformLocation(program, "iMouse"), m.x.GLfloat, (size.y - m.y).GLfloat, 0, 0)
  glUniform1i(glGetUniformLocation(program, "iFrame"), frame.GLint)
  inc frame
  var previous: GLint  # boxy binds its vertex array once and expects it to stay bound
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING, addr previous)
  glBindVertexArray(vao)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glBindVertexArray(previous.GLuint)
  glUseProgram(0)

proc clearShader*() =
  if program != 0: glDeleteProgram(program)
  program = 0
  renderer.background = nil
  shaderPath = ""

proc applySource*(text: string, path = ""): bool =
  ## Compiles text as the background shader; false (with the log reported) when it fails.
  let (fs, log) = compileStage(GL_FRAGMENT_SHADER, fragmentSource(text))
  if fs == 0:
    report(log)
    return false
  let (vs, vlog) = compileStage(GL_VERTEX_SHADER, vertexSource)
  if vs == 0:
    glDeleteShader(fs)
    report("vertex shader: " & vlog)
    return false
  let prog = glCreateProgram()
  glAttachShader(prog, vs)
  glAttachShader(prog, fs)
  glLinkProgram(prog)
  glDeleteShader(vs)
  glDeleteShader(fs)
  var ok: GLint
  glGetProgramiv(prog, GL_LINK_STATUS, addr ok)
  if ok == 0:
    var length: GLint
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, addr length)
    var buf = newString(max(1, length))
    glGetProgramInfoLog(prog, length, nil, cstring(buf))
    glDeleteProgram(prog)
    report("link: " & buf.strip)
    return false
  if program != 0: glDeleteProgram(program)
  if vao == 0: glGenVertexArrays(1, addr vao)
  program = prog
  started = epochTime()
  frame = 0
  shaderPath = path
  if path.len > 0 and fileExists(path): shaderStamp = getLastModificationTime(path)
  renderer.background = drawBackground
  renderer.backgroundDim = if dimmed: dim() else: 0
  echoLine = "Shader applied" & (if path.len > 0: ": " & shortPath(path) else: "")
  true

proc applyFile*(path: string): bool =
  let full = expandTilde(path)
  if not fileExists(full):
    echoLine = "No such shader: " & path
    return false
  applySource(readFile(full), absolutePath(full))

proc applyBuffer*() =
  ## C-c C-c in a GLSL buffer: the buffer's text runs, and its file (when saved) is followed.
  discard applySource(core.b.text, core.b.path)

proc toggleDim*() =
  dimmed = not dimmed
  renderer.backgroundDim = if dimmed: dim() else: 0
  echoLine = if dimmed: "Shader behind the text" else: "Shader alone (C-c C-o to dim)"

tickHooks.add proc(): bool =
  if program == 0: return false
  result = true  # the picture moves: a frame every loop while a shader runs
  if epochTime() - checked < 1.0: return
  checked = epochTime()
  if shaderPath.len > 0 and fileExists(shaderPath) and getLastModificationTime(shaderPath) != shaderStamp:
    shaderStamp = getLastModificationTime(shaderPath)
    discard applySource(readFile(shaderPath), shaderPath)  # edited elsewhere: follow the file

saveHooks.add proc() =
  if program != 0 and core.b.path == shaderPath: discard applySource(core.b.text, core.b.path)

keyFilters.add proc(c: string): bool =
  # In a GLSL buffer, C-c C-c / C-c C-o / C-c C-k (the NeoEmacs keys) belong to the shader.
  if prefix != "C-c" or mode.len > 0 or lang.name != "GLSL" or c notin ["C-c", "C-o", "C-k"]: return false
  prefix = ""
  case c
  of "C-c": applyBuffer()
  of "C-o": toggleDim()
  else:
    clearShader()
    echoLine = "Shader cleared"
  true

interp.defPrimitive("background-shader", proc(args: seq[Value]): Value =
  ## (background-shader "path"): the file runs under the text; without a path, the current buffer.
  args.arity(0, 1)
  if args.len == 1: discard applyFile(args[0].asString)
  else: applyBuffer()
  nilValue())
interp.defPrimitive("background-shader-toggle", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if program == 0: echoLine = "No shader running" else: toggleDim()
  nilValue())
interp.defPrimitive("background-shader-clear", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  clearShader()
  echoLine = "Shader cleared"
  nilValue())

defaults.add """
(setq background-shader-dim 0.6)
"""
