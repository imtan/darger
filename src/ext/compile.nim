## Emacs-style compilation, source navigation and reviewed agent follow-up.
import std/[os, strutils, unicode, tables, sets]
import ../[core, buffer, buffers, lisp, syntax, remote, chat, compilation, compilejob, termtext]
import agent

var
  compilationBuf*: Buffer
  compilationJob*: CompileJob
  compileCommand*, compileRoot*: string
  output: TermText
  outputLines: seq[string]
  errors: seq[CompileLocation]
  colors: seq[seq[Face]]
  selected = -1
  exitCode = 0
  completed, cancelled, offerAgent, restartConfirmed: bool
  seconds: float
  promptRoot, restartCommand, restartRoot: string

proc compilationDiagnostics*(): seq[tuple[location: CompileLocation, message: string]] =
  for error in errors:
    result.add (error, (if error.row < outputLines.len: outputLines[error.row] else: ""))

proc projectDirectory(): string =
  if b == compilationBuf and compileRoot.len > 0: return compileRoot
  let dir = if b.path.len > 0: parentDir(b.path) else: getCurrentDir()
  if isRemote(b.path): return b.path
  result = rootFromDir(dir)
  if result != normalizedPath(absolutePath(dir)) or
      dirExists(result / ".git") or fileExists(result / ".git"): return
  var candidate = result
  while candidate.len > 0:
    for name in buildFiles:
      if fileExists(candidate / name): return candidate
    let parent = parentDir(candidate)
    if parent == candidate: break
    candidate = parent

proc defaultCommand(root: string): string =
  if compileCommand.len > 0: return compileCommand
  var files: seq[string]
  for name in buildFiles:
    if fileExists(root / name): files.add name
  guessCommand(files)

proc refresh() =
  if compilationBuf == nil: return
  outputLines = output.text.splitLines
  errors = locations(outputLines, compileRoot)
  let text = "Compilation in " & compileRoot & "\n" & compileCommand &
    "\ng: recompile  Enter: visit  a: ask agent  C-c C-k: stop\n" & output.text &
    (if completed: "\n\nCompilation " & (if cancelled: "stopped" else: "finished") &
      " (exit code " & $exitCode & ", " & formatFloat(seconds, ffDecimal, 2) & "s)\n" else: "")
  let point = compilationBuf.cursor
  let follow = point.line == compilationBuf.lines.high
  compilationBuf.splice(0, compilationBuf.text.runeLen, text)
  compilationBuf.modified = false
  compilationBuf.cursor = if follow: (compilationBuf.lines.high, 0)
                          else: (min(point.line, compilationBuf.lines.high), point.col)
  compilationBuf.finish()
  colors = @[]
  for line in compilationBuf.lines: colors.add newSeq[Face](line.len)
  for error in errors:
    let face = case error.severity
      of csError: fAnsi1
      of csWarning: fAnsi3
      of csHint: fComment
    for color in colors[error.row + 3].mitems: color = face

proc startCompilation(command, root: string) =
  if strutils.strip(command).len == 0: return
  if isRemote(root):
    echoLine = "Remote compilation is not supported"
    return
  try:
    let job = startCompileJob(command, root)
    compilationJob = job
  except CatchableError as e:
    echoLine = "Compile: " & e.msg
    return
  compileCommand = command
  compileRoot = root
  restartCommand = ""
  restartConfirmed = false
  completed = false
  cancelled = false
  offerAgent = false
  selected = -1
  output = TermText()
  if compilationBuf == nil or compilationBuf notin reg:
    compilationBuf = newBuffer()
    reg.add(compilationBuf, "*compilation*")
    setReadOnly(compilationBuf, true)
    for (key, command) in [("g", "recompile"), ("a", "compile-ask-agent"),
        ("enter", "compile-visit-error"), ("C-m", "compile-visit-error"),
        ("C-j", "compile-visit-error"), ("C-c C-k", "compile-stop")]:
      setLocalKey(compilationBuf, key, symbol(command))
  refresh()
  switchTo(compilationBuf)
  echoLine = "Compilation running"

proc requestCompilation(command, root: string) =
  if strutils.strip(command).len == 0: return
  if compilationJob != nil:
    restartConfirmed = false
    restartCommand = command
    restartRoot = root
    beginMini("compile-restart", "Stop running compilation and restart? (y/n) ")
  else: startCompilation(command, root)

proc askAgent() =
  if compilationJob != nil or not completed or cancelled or exitCode == 0:
    echoLine = "No failed compilation to send"
    return
  var prompt = failurePrompt(compileCommand, compileRoot, exitCode, outputLines, errors)
  var seen: HashSet[string]
  for error in errors:
    if error.path in seen: continue
    seen.incl error.path
    try:
      var source: Buffer
      for slot in reg.slots:
        if slot.buf.path == error.path: source = slot.buf
      let text = if source != nil: source.text else: readFile(error.path)
      prompt.add sourceContext(error.path, text, errors)
    except CatchableError as e:
      prompt.add "\nSource unavailable: " & error.path & " (" & e.msg & ")\n"
  try:
    chatRoot = compileRoot
    sendChat(prompt)
    offerAgent = false
  except CatchableError as e: echoLine = e.msg

proc visitError(index: int) =
  if index < 0 or index >= errors.len:
    echoLine = "No more compilation locations"
    return
  let error = errors[index]
  if not fileExists(error.path):
    echoLine = "Compilation source unavailable: " & error.path
    return
  let origin = b
  let point = b.cursor
  let top = renderer.top
  let left = renderer.left
  try:
    visit(error.path)
    pushXref(origin, point, top, left)
    let line = clamp(error.line, 0, b.lines.high)
    b.cursor = (line, clamp(error.col, 0, b.lines[line].len))
    selected = index
    echoLine = outputLines[error.row]
  except CatchableError as e: echoLine = e.msg

proc pollCompilation*(): bool =
  if compilationJob != nil:
    let job = compilationJob
    job.poll()
    let chunk = job.read()
    if chunk.len > 0:
      output.feed(chunk)
      result = true
    # Drain large final output over several ticks before reporting the exit.
    if job.finished and chunk.len < 65536:
      seconds = job.elapsed
      exitCode = job.code
      cancelled = job.cancelled
      completed = true
      job.close()
      compilationJob = nil
      let setting = interp.env.values.getOrDefault("compile-ask-agent-on-failure")
      offerAgent = compilationBuf != nil and not cancelled and exitCode != 0 and setting != nil and setting.kind != vNil
      result = true
    if result: refresh()
    if compilationJob == nil and restartConfirmed and restartCommand.len > 0:
      let command = restartCommand
      let root = restartRoot
      restartCommand = ""
      startCompilation(command, root)
  if offerAgent and mode.len == 0:
    offerAgent = false
    beginMini("compile-agent", "エージェントに送りますか？ (y/n) ")
    result = true

definePrompt(Prompt(kind: "compile-command", text: true, onAccept: proc(value: string): bool =
  if strutils.strip(value).len == 0: return false
  requestCompilation(value, promptRoot)
  true))
definePrompt(Prompt(kind: "compile-restart", onAccept: proc(value: string): bool =
  case value.toLowerAscii
  of "y", "yes":
    restartConfirmed = true
    if compilationJob != nil: compilationJob.stop()
    else:
      let command = restartCommand
      restartCommand = ""
      startCompilation(command, restartRoot)
  of "n", "no": restartCommand = ""
  else: return false
  true, onCancel: proc() = restartCommand = ""))
definePrompt(Prompt(kind: "compile-agent", onAccept: proc(value: string): bool =
  case value.toLowerAscii
  of "y", "yes": askAgent()
  of "n", "no": discard
  else: return false
  true))

interp.defPrimitive("compile", proc(args: seq[Value]): Value =
  args.arity(0, 1)
  promptRoot = projectDirectory()
  if isRemote(promptRoot): echoLine = "Remote compilation is not supported"
  elif args.len == 1: requestCompilation(args[0].asString, promptRoot)
  else: beginMini("compile-command", "Compile command: ", defaultCommand(promptRoot))
  nilValue())
interp.defPrimitive("recompile", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if compileCommand.len == 0:
    promptRoot = projectDirectory()
    beginMini("compile-command", "Compile command: ", defaultCommand(promptRoot))
  else: requestCompilation(compileCommand, compileRoot)
  nilValue())
interp.defPrimitive("compile-stop", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  restartCommand = ""
  if compilationJob != nil: compilationJob.stop()
  else: echoLine = "No compilation running"
  nilValue())
interp.defPrimitive("compile-ask-agent", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  askAgent()
  nilValue())
interp.defPrimitive("compile-visit-error", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if b == compilationBuf:
    for i, error in errors:
      if error.row + 3 == b.cursor.line:
        visitError(i)
        break
  nilValue())
for (name, direction) in [("next-error", 1), ("previous-error", -1)]:
  closureScope:
    let direction = direction
    interp.defPrimitive(name, proc(args: seq[Value]): Value =
      args.arity(0, 0)
      visitError(if selected < 0: (if direction > 0: 0 else: errors.high) else: selected + direction)
      nilValue())

faceProviders.add proc(buf: Buffer): seq[seq[Face]] =
  if buf == compilationBuf and buf != nil: colors else: @[]
modeNameProviders.add proc(buf: Buffer): string =
  if buf == compilationBuf and buf != nil: "Compilation" else: ""
busyHooks.add proc(): bool = compilationJob != nil
tickHooks.add pollCompilation
cancelHooks.add proc() =
  restartCommand = ""
  if compilationJob != nil: compilationJob.stop()
killHooks.add proc(buf: Buffer) =
  if buf == compilationBuf:
    if compilationJob != nil: compilationJob.stop()
    compilationBuf = nil
    restartCommand = ""
    offerAgent = false
exitHooks.add proc() =
  if compilationJob != nil:
    compilationJob.close()
    compilationJob = nil

defaults.add """
(global-set-key "M-g n" 'next-error)
(global-set-key "M-g p" 'previous-error)
(global-set-key "C-x `" 'next-error)
(setq compile-ask-agent-on-failure nil)
"""
