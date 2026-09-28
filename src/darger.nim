import std/[os, osproc, tempfiles, strutils, times, unicode, tables, sets]
import windy, vmath
import buffer, render, skk, lisp, review

const
  bufferCommands = ["forward", "backward", "next-line", "previous-line", "bol", "eol",
    "bob", "eob", "indent", "forward-word", "backward-word", "newline", "tab", "open-line",
    "delete", "backspace", "kill-line", "kill-word", "backward-kill-word", "mark", "exchange",
    "whole", "kill-region", "copy-region", "yank", "yank-pop", "undo", "transpose",
    "upcase", "downcase", "capitalize", "quit"]
  defaultBindings = """
(global-set-key "C-f" 'forward)
(global-set-key "right" 'forward)
(global-set-key "C-b" 'backward)
(global-set-key "left" 'backward)
(global-set-key "C-n" 'next-line)
(global-set-key "down" 'next-line)
(global-set-key "C-p" 'previous-line)
(global-set-key "up" 'previous-line)
(global-set-key "C-a" 'bol)
(global-set-key "home" 'bol)
(global-set-key "C-e" 'eol)
(global-set-key "end" 'eol)
(global-set-key "M-f" 'forward-word)
(global-set-key "M-b" 'backward-word)
(global-set-key "M-<" 'bob)
(global-set-key "C-home" 'bob)
(global-set-key "M->" 'eob)
(global-set-key "C-end" 'eob)
(global-set-key "M-m" 'indent)
(global-set-key "enter" 'newline)
(global-set-key "C-m" 'newline)
(global-set-key "C-j" 'newline)
(global-set-key "tab" 'tab)
(global-set-key "C-i" 'tab)
(global-set-key "backspace" 'backspace)
(global-set-key "C-h" 'backspace)
(global-set-key "C-d" 'delete)
(global-set-key "delete" 'delete)
(global-set-key "C-k" 'kill-line)
(global-set-key "C-o" 'open-line)
(global-set-key "C-t" 'transpose)
(global-set-key "M-d" 'kill-word)
(global-set-key "M-backspace" 'backward-kill-word)
(global-set-key "M-u" 'upcase)
(global-set-key "M-l" 'downcase)
(global-set-key "M-c" 'capitalize)
(global-set-key "C-SPC" 'mark)
(global-set-key "C-@" 'mark)
(global-set-key "C-x C-x" 'exchange)
(global-set-key "C-w" 'kill-region)
(global-set-key "M-w" 'copy-region)
(global-set-key "C-y" 'yank)
(global-set-key "M-y" 'yank-pop)
(global-set-key "C-x h" 'whole)
(global-set-key "C-/" 'undo)
(global-set-key "C-_" 'undo)
(global-set-key "C-x u" 'undo)
(global-set-key "C-c a" 'agent-prompt)
(setq agent-command "claude -p --output-format text")
"""

when defined(windows):
  import std/[winlean, streams]
  proc getKeyState(key: int32): int16 {.stdcall, importc: "GetKeyState", dynlib: "user32".}
  proc createJobObject(attributes: pointer, name: WideCString): Handle {.stdcall, importc: "CreateJobObjectW", dynlib: "kernel32".}
  proc assignProcessToJobObject(job, process: Handle): WINBOOL {.stdcall, importc: "AssignProcessToJobObject", dynlib: "kernel32".}
  proc terminateJobObject(job: Handle, code: uint32): WINBOOL {.stdcall, importc: "TerminateJobObject", dynlib: "kernel32".}
else:
  import std/posix

var b = newBuffer()
var startupMessage: string
if paramCount() > 0:
  try: b = loadBuffer(paramStr(1))
  except CatchableError as e: startupMessage = e.msg

var
  window = newWindow("darger", ivec2(1000, 720), vsync = true)
window.makeContextCurrent()
window.runeInputEnabled = true
var renderer: Renderer
try: renderer = newRenderer()
except CatchableError as e:
  stderr.writeLine(e.msg)
  window.close()
  quit(1)
let inputMethod = newSkk()
var
  echo, prefix, mode, prompt: string
  mini = newBuffer()
  running = true
  suppressRune = false
  recenterCycle = 0
  isearch: ISearch
  lastSearch: string
  matchStart = -1
  pendingPath: string
  highSurrogate = 0
  interp = newInterp()
  keymap: Table[string, Value]
  prefixKeys = toHashSet(["C-x", "M-g"])
  agentProcess: Process
  agentDir: string
  agentCancelled = false
  reviewState: Review
  reviewBuf: Buffer
  reviewColors: seq[int8]
  currentHunk, savedTop, savedLeft: int
when defined(windows):
  var agentJob: Handle
else:
  var agentGroup: bool
echo = startupMessage

proc ctrl(): bool = window.buttonDown[KeyLeftControl] or window.buttonDown[KeyRightControl]
proc alt(): bool = window.buttonDown[KeyLeftAlt] or window.buttonDown[KeyRightAlt]
proc shift(): bool = window.buttonDown[KeyLeftShift] or window.buttonDown[KeyRightShift]

proc keypadNavigation(): bool =
  when defined(windows): (getKeyState(0x90) and 1) == 0
  else: not window.buttonToggle[KeyNumLock]

proc chord(key: Button): string =
  var name = case key
    of KeySpace: "SPC"
    of NumpadEnter: "enter"
    of Numpad0..Numpad9:
      if keypadNavigation(): ["insert", "end", "down", "pagedown", "left", "", "right", "home", "up", "pageup"][ord(key)-ord(Numpad0)]
      else: $char(ord('0')+ord(key)-ord(Numpad0))
    of NumpadDecimal: (if keypadNavigation(): "delete" else: ".")
    of KeySemicolon: (if shift(): ":" else: ";")
    of KeySlash: "/"
    of KeyMinus: (if shift(): "_" else: "-")
    of KeyComma: (if shift(): "<" else: ",")
    of KeyPeriod: (if shift(): ">" else: ".")
    of Key2: (if shift(): "@" else: "2")
    else: ($key).replace("Key", "").toLowerAscii
  if alt(): name = "M-" & name
  if ctrl(): name = "C-" & name
  name

proc beginMini(kind, label: string, initial = "") =
  b.finish()
  mode = kind
  prompt = label
  mini = newBuffer(initial)
  mini.cursor = (0, mini.lines[0].len)
  echo = ""
  prefix = ""

proc reviewMessage(): string =
  "Review hunk " & $(currentHunk + 1) & "/" & $reviewState.hunks.len &
    "  y:accept k:skip a:all q:done"

proc rebuildReview() =
  let display = reviewState.view(currentHunk)
  reviewBuf = newBuffer(display.text)
  reviewBuf.path = b.path
  reviewColors = display.colors
  reviewBuf.cursor = (min(display.starts[currentHunk], reviewBuf.lines.high), 0)
  renderer.top = reviewBuf.cursor.line
  renderer.left = 0
  echo = reviewMessage()

proc beginReview(proposed: string) =
  reviewState = newReview(b.text, proposed)
  if reviewState.hunks.len == 0:
    echo = "Agent: no changes"
    return
  b.finish()
  savedTop = renderer.top
  savedLeft = renderer.left
  currentHunk = 0
  mode = "review"
  prefix = ""
  matchStart = -1
  window.closeIme()
  rebuildReview()

proc finishReview(cancel = false) =
  if cancel: echo = "Review cancelled"
  else:
    let text = reviewState.appliedText()
    var count = 0
    for decision in reviewState.decisions:
      if decision == accepted: inc count
    if text != b.text:
      let point = b.offset(b.cursor)
      b.snapshot()
      b.splice(0, b.text.runeLen, text)
      b.cursor = b.point(point)
      b.finish()
    echo = "Applied " & $count & " of " & $reviewState.hunks.len & " hunks"
  mode = ""
  reviewBuf = nil
  reviewColors = @[]
  reviewState = Review()
  renderer.top = savedTop
  renderer.left = savedLeft

proc cleanAgentFiles() =
  if agentDir.len == 0: return
  try:
    for name in ["prompt.txt", "out.txt", "err.txt"]:
      let path = agentDir / name
      if fileExists(path): removeFile(path)
    removeDir(agentDir)
  except OSError as e: echo = "Agent cleanup: " & e.msg
  agentDir = ""

proc startAgent(instruction: string) =
  if agentProcess != nil: raise newException(ValueError, "Agent already running")
  let command = interp.env.values["agent-command"].asString
  if strutils.strip(command).len == 0: raise newException(ValueError, "agent-command is empty")
  agentDir = createTempDir("darger-agent-", "")
  try:
    when defined(windows):
      agentJob = createJobObject(nil, nil)
      if agentJob == 0: raiseOSError(osLastError())
    # ponytail: full-file round trips are unsuitable for huge files; add region-only input if needed.
    writeFile(agentDir / "prompt.txt",
      "You are editing a text file. Apply the instruction to the file and output ONLY the complete new file content. No explanations, no code fences.\n" &
      "File path: " & (if b.path.len > 0: b.path else: "(unnamed)") & "\n" &
      "Instruction: " & instruction & "\n--- FILE START ---\n" & b.text & "\n--- FILE END ---\n")
    when defined(windows):
      let redirected = command & " < \"" & agentDir / "prompt.txt" & "\" > \"" &
        agentDir / "out.txt" & "\" 2> \"" & agentDir / "err.txt" & "\""
      # Gate the CLI until cmd.exe belongs to the job, so no child escapes cancellation.
      agentProcess = startProcess("cmd /d /s /c \"set /p dargerAgentReady= >nul & " & redirected & "\"",
        options = {poEvalCommand, poUsePath, poDaemon})
      let handle = openProcess(PROCESS_SET_QUOTA or PROCESS_TERMINATE, 0, DWORD(agentProcess.processID))
      if handle == 0: raiseOSError(osLastError())
      let assigned = assignProcessToJobObject(agentJob, handle)
      let error = osLastError()
      discard closeHandle(handle)
      if assigned == 0: raiseOSError(error)
      agentProcess.inputStream.writeLine("ready")
      agentProcess.inputStream.flush()
    else:
      let redirected = command & " < " & quoteShell(agentDir / "prompt.txt") &
        " > " & quoteShell(agentDir / "out.txt") & " 2> " & quoteShell(agentDir / "err.txt")
      let setsid = findExe("setsid")
      agentGroup = setsid.len > 0
      let shell = if agentGroup: "exec " & quoteShell(setsid) & " /bin/sh -c " & quoteShell(redirected)
                  else: redirected
      # ponytail: without setsid (e.g. macOS), cancellation only stops the shell; install setsid for group cleanup.
      agentProcess = startProcess("/bin/sh", args = ["-c", shell], options = {poUsePath})
    agentCancelled = false
    echo = "Agent running..."
  except CatchableError:
    if agentProcess != nil:
      agentProcess.kill()
      agentProcess.close()
      agentProcess = nil
    when defined(windows):
      if agentJob != 0:
        discard terminateJobObject(agentJob, 1)
        discard closeHandle(agentJob)
        agentJob = 0
    cleanAgentFiles()
    raise

proc cancelAgent() =
  if agentProcess == nil or agentCancelled: return
  when defined(windows):
    # Killing only cmd.exe leaves the CLI running; stop its job's descendants too.
    if terminateJobObject(agentJob, 1) == 0: raiseOSError(osLastError())
  else:
    if agentProcess.peekExitCode() == -1:
      let pid = Pid(agentProcess.processID)
      if posix.kill(if agentGroup: -pid else: pid, SIGTERM) != 0:
        let error = osLastError()
        if error != OSErrorCode(ESRCH): raiseOSError(error)
        # Cancellation may arrive before setsid has established the group.
        if agentGroup and posix.kill(pid, SIGTERM) != 0 and osLastError() != OSErrorCode(ESRCH):
          raiseOSError(osLastError())
  agentCancelled = true
  echo = "Agent cancelling..."

proc cleanAgentOutput(text: string): string =
  result = text.replace("\r\n", "\n")
  let tail = strutils.strip(result, leading = false)
  if tail.endsWith("```") and (tail.len == 3 or tail[^4] == '\n'):
    result = tail[0..<tail.len - 3]
    if result.startsWith("```"):
      let newline = result.find('\n')
      if newline >= 0: result = result[newline + 1..^1]

proc pollAgent(): bool =
  if agentProcess == nil: return false
  let code = agentProcess.peekExitCode()
  if code == -1: return false
  result = true
  agentProcess.close()
  agentProcess = nil
  when defined(windows):
    discard closeHandle(agentJob)
    agentJob = 0
  try:
    if agentCancelled: echo = "Agent cancelled"
    elif code != 0:
      let errors = readFile(agentDir / "err.txt").splitLines()
      echo = if errors.len > 0 and errors[0].len > 0: errors[0] else: "Agent exited with code " & $code
    else:
      let text = cleanAgentOutput(readFile(agentDir / "out.txt"))
      if validateUtf8(text) != -1: raise newException(ValueError, "Agent output is not valid UTF-8")
      beginReview(text)
  except CatchableError as e: echo = e.msg
  finally: cleanAgentFiles()

proc quitEditor() =
  if mode == "review": finishReview(true)
  if b.modified: beginMini("exit", "Modified buffers exist; exit anyway? (y or n) ")
  else: running = false

proc syncSearch() =
  let state = isearch.state
  mini = newBuffer(state.query)
  mini.cursor.col = mini.lines[0].len
  matchStart = if state.failing: -1 else: state.matchStart
  prompt = (if state.failing: "Failing " elif state.wrapped: "Wrapped " else: "") &
    (if state.direction > 0: "I-search: " else: "I-search backward: ")

proc search(next = false, direction = 0) =
  let query = if next and mini.text.len == 0: lastSearch else: mini.text
  b.searchStep(isearch, query, next, direction)
  syncSearch()

proc runCommand(name: string): Value =
  if name notin bufferCommands: raise newException(LispError, "Unknown buffer command: " & name)
  echo = b.command(name, if name == "yank" and b.kills.len == 0: getClipboardString() else: "")
  if b.last in ["kill", "copy"] and b.kills.len > 0: setClipboardString(b.kills[0])
  nilValue()

proc registerCommand(name: string) =
  interp.defPrimitive(name, proc(args: seq[Value]): Value =
    args.arity(0, 0)
    runCommand(name))

for name in bufferCommands: registerCommand(name)
interp.defPrimitive("global-set-key", proc(args: seq[Value]): Value =
  args.arity(2, 2)
  let key = args[0].asString
  if key.len == 0 or args[1].kind notin {vSymbol, vLambda, vPrimitive}:
    raise newException(LispError, "Expected key and symbol or function")
  keymap[key] = args[1]
  let tokens = strutils.splitWhitespace(key)
  if tokens.len > 1: prefixKeys.incl tokens[0]
  args[1])
interp.defPrimitive("insert", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  b.insert(args[0].asString)
  nilValue())
interp.defPrimitive("message", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  echo = args[0].asString
  args[0])
interp.defPrimitive("command", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  runCommand(args[0].asString))
interp.defPrimitive("agent", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  startAgent(args[0].asString)
  nilValue())
interp.defPrimitive("agent-prompt", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  beginMini("agent", "Agent: ")
  nilValue())
discard interp.evalString(defaultBindings, "<default-bindings>")
let initPath = getHomeDir() / ".darger.el"
if fileExists(initPath):
  try: discard interp.evalFile(initPath)
  except CatchableError as e: echo = e.msg

proc confirmMini() =
  let value = mini.text
  let kind = mode
  if kind == "search" and value.len > 0: lastSearch = value
  case kind
  of "agent": startAgent(value)
  of "eval", "execute":
    try:
      if kind == "eval": echo = $interp.evalString(value, "<minibuffer>")
      else: discard interp.call(symbol(value), @[])
    except LispError as e:
      echo = if e.line == 0: "<minibuffer>:1: " & e.msg else: e.msg
  of "find":
    if value.len == 0: return
    if b.modified:
      pendingPath = value
      beginMini("replace", "Buffer modified; discard changes? (y or n) ")
      return
    let loaded = loadBuffer(value)
    loaded.kills = b.kills
    b = loaded
    renderer.top = 0
    renderer.left = 0
  of "replace":
    if value.toLowerAscii == "y":
      let loaded = loadBuffer(pendingPath)
      loaded.kills = b.kills
      b = loaded
      renderer.top = 0
      renderer.left = 0
    elif value.toLowerAscii != "n":
      echo = "Please answer y or n"
      return
  of "write":
    if value.len == 0: return
    if fileExists(value) and absolutePath(value) != b.path:
      pendingPath = value
      beginMini("overwrite", "File exists; overwrite? (y or n) ")
      return
    b.save(value)
    echo = "Wrote " & b.path
  of "overwrite":
    if value.toLowerAscii == "y":
      b.save(pendingPath)
      echo = "Wrote " & b.path
    elif value.toLowerAscii != "n":
      echo = "Please answer y or n"
      return
  of "goto":
    let line = parseInt(value)
    if line < 1: raise newException(ValueError, "Line number must be positive")
    b.cursor = (min(line-1, b.lines.high), 0)
  of "exit":
    if value.toLowerAscii == "y": running = false
    elif value.toLowerAscii != "n":
      echo = "Please answer y or n"
      return
  else: discard
  mode = ""
  matchStart = -1
  b.finish()

proc editMini(c: string): bool =
  let cmd = case c
    of "backspace", "C-h": "backspace"
    of "tab", "C-i": "tab"
    of "C-a", "home": "bol"
    of "C-e", "end": "eol"
    of "C-f", "right": "forward"
    of "C-b", "left": "backward"
    of "C-k": "kill-line"
    of "C-y": "yank"
    else: ""
  if cmd.len == 0: return false
  if cmd == "yank":
    let s = if b.kills.len > 0: b.kills[0] else: getClipboardString()
    mini.insert(s.replace("\r", "").replace("\n", " "))
  else:
    discard mini.command(cmd)
    if cmd == "kill-line" and mini.last == "kill":
      b.kills.insert(mini.kills[0], 0)
      b.yankIndex = 0
      if b.kills.len > 60: b.kills.setLen(60)
      setClipboardString(b.kills[0])
  if mode == "search": search()
  true

proc target(): Buffer = (if mode.len > 0: mini else: b)

proc skkOn(): bool =
  # ponytail: one SKK state serves the buffer and the text minibuffers; y/n and goto prompts bypass it.
  inputMethod.enabled and mode in ["", "find", "write", "search"] and
    window.imeCompositionString.len == 0

proc following(): Rune =
  ## The character after the cursor, so SKK's ")" can step over a "）".
  let t = target()
  if t.cursor.col < t.lines[t.cursor.line].len: t.lines[t.cursor.line][t.cursor.col] else: Rune(0)

proc applySkk(res: SkkResult): bool =
  ## Inserts the engine's text like typed input; true when SKK consumed the key.
  let t = target()
  t.insert(res.text, true)
  if res.move != 0: t.cursor = t.point(t.offset(t.cursor) + res.move)
  if mode == "search" and res.text.len > 0: search()
  if res.consumed: echo = res.echo
  recenterCycle = 0
  res.consumed

proc dispatch(c: string) =
  if c == "C-g":
    if agentProcess != nil: cancelAgent()
    if mode == "review":
      finishReview(true)
      return
    if mode == "search": b.cursor = isearch.origin
    mode = ""
    prefix = ""
    matchStart = -1
    echo = if agentCancelled and agentProcess != nil: "Agent cancelling..." else: ""
    discard b.command("quit")
    return
  if mode == "review":
    case c
    of "n": currentHunk = min(currentHunk + 1, reviewState.hunks.high)
    of "p": currentHunk = max(currentHunk - 1, 0)
    of "y", "k":
      reviewState.decisions[currentHunk] = if c == "y": accepted else: rejected
      currentHunk = min(currentHunk + 1, reviewState.hunks.high)
    of "a":
      for decision in reviewState.decisions.mitems:
        if decision == pending: decision = accepted
      finishReview()
      return
    of "enter", "C-m", "C-j", "q":
      finishReview()
      return
    else:
      echo = c & " is undefined"
      return
    rebuildReview()
    return
  if mode == "search":
    if c in ["C-s", "C-r"]:
      search(true, if c == "C-s": 1 else: -1)
      return
    if c in ["backspace", "C-h"]:
      b.searchBackspace(isearch)
      syncSearch()
      return
    if c == "C-y":
      discard editMini(c)
      return
    confirmMini()
    if c in ["enter", "C-m", "C-j"]: return
  if mode.len > 0:
    if c in ["enter", "C-m", "C-j"]: confirmMini()
    elif not editMini(c): echo = c & " is undefined"
    return
  let full = if prefix.len > 0: prefix & " " & c else: c
  prefix = ""
  if full in prefixKeys:
    prefix = full
    echo = full & "-"
    b.finish()
    return
  if full != "C-l": recenterCycle = 0
  if full in keymap:
    let fn = keymap[full]
    if fn.kind == vSymbol and fn.str in bufferCommands:
      discard runCommand(fn.str)
    else:
      discard interp.call(fn, @[])
    return
  b.finish()
  case full
  of "M-:": beginMini("eval", "Eval: ")
  of "M-x": beginMini("execute", "M-x ")
  of "C-x C-j":
    let message = if inputMethod.loaded: "" else: inputMethod.loadDefaults()
    discard applySkk(inputMethod.toggle())
    if message.len > 0: echo = message
  of "C-v", "pagedown", "M-v", "pageup":
    let direction = if full in ["C-v", "pagedown"]: 1 else: -1
    if direction > 0 and renderer.top + renderer.rows > b.lines.high:
      echo = "End of buffer"
      return
    if direction < 0 and renderer.top == 0:
      echo = "Beginning of buffer"
      return
    let delta = direction * max(1, renderer.rows-2)
    b.vertical(delta)
    renderer.top = clamp(renderer.top + delta, 0, max(0, b.lines.len-renderer.rows))
  of "C-l":
    let row = case recenterCycle
      of 0: renderer.rows div 2
      of 1: 0
      else: renderer.rows - 1
    renderer.top = max(0, b.cursor.line - row)
    recenterCycle = (recenterCycle + 1) mod 3
  of "M-g g", "M-g M-g": beginMini("goto", "Goto line: ")
  of "C-x C-s":
    if b.path.len == 0: beginMini("write", "Write file: ", getCurrentDir() & DirSep)
    else:
      b.save()
      echo = "Wrote " & b.path
  of "C-x C-f":
    beginMini("find", "Find file: ", (if b.path.len > 0: parentDir(b.path) else: getCurrentDir()) & DirSep)
  of "C-x C-w": beginMini("write", "Write file: ", b.path)
  of "C-x C-c": quitEditor()
  of "C-s", "C-r":
    isearch = b.startSearch(if full == "C-s": 1 else: -1)
    matchStart = -1
    beginMini("search", if isearch.state.direction > 0: "I-search: " else: "I-search backward: ")
  else: echo = full & " is undefined"

var dirty = true  # set by every input callback; the loop only redraws when it is set

window.onButtonPress = proc(key: Button) =
  dirty = true
  if key in {KeyLeftControl, KeyRightControl, KeyLeftAlt, KeyRightAlt,
             KeyLeftShift, KeyRightShift, KeyLeftSuper, KeyRightSuper,
             KeyCapsLock, KeyNumLock, KeyScrollLock, KeyPause, KeyMenu, KeyPrintScreen,
             KeyInsert, KeyEscape} or key < Key0: return
  if window.imeCompositionString.len > 0:
    if key == KeyG and ctrl():
      window.closeIme()
      dispatch("C-g")
    return
  echo = ""
  let printable = key in {Key0..KeyZ, KeyBacktick, KeyMinus, KeyEqual,
    KeyLeftBracket, KeyRightBracket, KeyBackslash, KeySemicolon,
    KeyApostrophe, KeyComma, KeyPeriod, KeySlash, KeySpace, NumpadAdd..NumpadEqual} or
    (key in {Numpad0..Numpad9, NumpadDecimal} and not keypadNavigation())
  suppressRune = prefix.len > 0 and printable and not ctrl() and not alt()
  if not ctrl() and not alt() and prefix.len == 0 and printable: return
  try:
    let c = chord(key)
    if c.len == 0 or c == "insert": return
    if c == "C-g" and agentProcess != nil:
      dispatch(c)
      return
    if prefix.len == 0 and c in ["enter", "backspace", "tab", "C-j", "C-g"] and skkOn():
      let key = case c
        of "enter": skEnter
        of "backspace": skBackspace
        of "tab": skTab
        of "C-j": skCtrlJ
        else: skCtrlG
      if applySkk(inputMethod.feed(key)): return
    dispatch(c)
  except CatchableError as e: echo = e.msg

window.onRune = proc(rune: Rune) =
  dirty = true
  if ctrl() or alt() or int(rune) < 32 or int(rune) == 127: return
  if suppressRune:
    suppressRune = false
    return
  # Windy's Windows WM_CHAR callback exposes UTF-16 surrogate code units.
  var scalar = int(rune)
  if scalar in 0xD800..0xDBFF:
    highSurrogate = scalar
    return
  if scalar in 0xDC00..0xDFFF:
    if highSurrogate == 0: return
    scalar = 0x10000 + (highSurrogate - 0xD800) * 1024 + scalar - 0xDC00
  highSurrogate = 0
  if scalar > 0x10FFFF: return
  echo = ""
  try:
    if mode == "review":
      dispatch($Rune(scalar))
      return
    if prefix.len > 0:
      dispatch($Rune(scalar))
      return
    if skkOn() and applySkk(if scalar == 32: inputMethod.feed(skSpace)
                           else: inputMethod.feed(Rune(scalar), following())): return
    if mode.len > 0:
      mini.insert($Rune(scalar), true)
      if mode == "search": search()
    else:
      recenterCycle = 0
      b.insert($Rune(scalar), true)
  except CatchableError as e: echo = e.msg

window.onImeChange = proc() =
  dirty = true
  if mode == "review":
    if window.imeCompositionString.len > 0: window.closeIme()
    return
  if window.imeCompositionString.len > 0:
    prefix = ""
    suppressRune = false
    highSurrogate = 0
    b.finish()

window.onCloseRequest = proc() = quitEditor()

proc redraw() =
  if not running or window.closed or window.minimized or window.size.x == 0 or window.size.y == 0: return
  let displayed = if mode == "review": reviewBuf else: b
  renderer.resize(window, displayed)
  let skkShown = skkOn()
  # The candidate page lives in echo; a command that cleared echo brings it back.
  let message = if agentProcess != nil:
      (if agentCancelled: "Agent cancelling..." else: "Agent running...")
    elif mode == "review": reviewMessage() & (if echo != reviewMessage(): "  " & echo else: "")
    elif echo.len == 0 and skkShown: inputMethod.page() else: echo
  let miniText = prompt & mini.text & (if message.len > 0: "  [" & message & "]" else: "")
  renderer.draw(window, displayed, message, miniText,
    if mode.len > 0 and mode != "review": prompt.runeLen + mini.cursor.col else: -1,
    if mode == "search": matchStart else: -1,
    if mode == "search": mini.text.runeLen else: 0,
    if skkShown: inputMethod.preedit() else: "",
    if mode == "review": "[Review]" else: inputMethod.tag(), reviewColors)

window.onResize = redraw
var lastDraw = 0.0
while running and not window.closed:
  pollEvents()
  try:
    if pollAgent(): dirty = true
  except CatchableError as e:
    echo = e.msg
  # ponytail: redraw after input or every 250 ms; an unconditional per-frame redraw kept ~2 cores busy while idle
  if dirty or epochTime() - lastDraw > 0.25:
    redraw()
    dirty = false
    lastDraw = epochTime()
  else:
    sleep(8)
if agentProcess != nil:
  cancelAgent()
  discard agentProcess.waitForExit()
  agentProcess.close()
  when defined(windows): discard closeHandle(agentJob)
  cleanAgentFiles()
window.close()
