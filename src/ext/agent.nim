## Agents: a one-shot edit reviewed hunk by hunk (C-c a, review.nim), and a multi-turn
## chat per project root with a live transcript (C-c c, chat.nim).
import std/[os, osproc, tempfiles, strutils, unicode, times, tables]
from windy import closeIme
import ../[core, buffer, buffers, render, lisp, review, chat, syntax, lsp]

when defined(windows):
  import std/[winlean, streams]
  proc createJobObject(attributes: pointer, name: WideCString): Handle {.stdcall, importc: "CreateJobObjectW", dynlib: "kernel32".}
  proc assignProcessToJobObject(job, process: Handle): WINBOOL {.stdcall, importc: "AssignProcessToJobObject", dynlib: "kernel32".}
  proc terminateJobObject(job: Handle, code: uint32): WINBOOL {.stdcall, importc: "TerminateJobObject", dynlib: "kernel32".}
else:
  import std/posix

type
  ChatSession* = ref object
    root*, id*: string
    buf*: Buffer
    started*: bool
    turn*: Turn

var chats*: Table[string, ChatSession]
proc chatFor*(buf: Buffer): ChatSession =
  for session in chats.values:
    if session.buf == buf: return session

var
  agentProcess*: Process
  agentDir*: string
  agentCancelled* = false
  agentStartedAt*: float
  agentReadSize*: int64
  agentOutput*: ChatOutput
  reviewState*: Review
  reviewBuf*: Buffer
  reviewColors*: seq[int8]
  reviewBgs*: seq[seq[int8]]
  currentHunk*, savedTop*, savedLeft*: int
  agentBuf*: Buffer
  agentChat*: ChatSession
  chatRoot*: string
when defined(windows):
  var agentJob*: Handle
else:
  var agentGroup*: bool

var
  reviewSource = "Agent"  # what the proposed text is: the agent, the file on disk, git HEAD, a file
  reviewRequest = false   # the running agent answers a request for changes to the open review

proc reviewMessage*(): string =
  let (removed, added) = reviewState.stats(currentHunk)
  "Review " & reviewSource & ": hunk " & $(currentHunk + 1) & "/" & $reviewState.hunks.len &
    " (-" & $removed & " +" & $added & ")  y:take k:keep u:undo n/p l:list r:request a:all q:done ?:help"

proc rebuildReview*() =
  let display = reviewState.view(currentHunk)
  reviewBuf = newBuffer(display.text)
  reviewBuf.path = b.path
  reviewColors = display.colors
  reviewBgs = display.bgs
  reviewBuf.cursor = (min(display.starts[currentHunk], reviewBuf.lines.high), 0)
  renderer.top = reviewBuf.cursor.line
  renderer.left = 0
  echoLine = reviewMessage()

proc beginReviewText(proposed, source: string)  # forward: the review replaced in place

proc beginReview*(proposed: string, source = "Agent") =
  ## A hunk-by-hunk review of the current buffer against `proposed`: y takes the
  ## proposed version of a hunk, k keeps the buffer's. Any source can propose text.
  reviewSource = source
  reviewState = newReview(b.text, proposed)
  if reviewState.hunks.len == 0:
    echoLine = source & ": no changes"
    return
  closeOverlay()  # the agent finished while the manual or dashboard was open
  b.finish()
  savedTop = renderer.top
  savedLeft = renderer.left
  currentHunk = 0
  mode = "review"
  prefix = ""
  matchStart = -1
  window.closeIme()
  rebuildReview()

proc beginReviewText(proposed, source: string) =
  ## The open review's proposal replaced (decisions start over); closes it when nothing differs.
  reviewSource = source
  reviewState = newReview(b.text, proposed)
  if reviewState.hunks.len == 0:
    mode = ""
    reviewBuf = nil
  else:
    currentHunk = 0
    rebuildReview()

proc applyDecisions(): int =
  ## The accepted hunks into the buffer; returns how many.
  let text = reviewState.appliedText()
  for decision in reviewState.decisions:
    if decision == accepted: inc result
  if text != b.text:
    let point = b.offset(b.cursor)
    b.snapshot()
    b.splice(0, b.text.runeLen, text)
    b.cursor = b.point(point)
    b.finish()

proc applyAndContinue() =
  ## w: the decisions so far go into the buffer; the pending hunks stay under review.
  let taken = applyDecisions()
  let proposed = reviewState.proposedText()
  let source = reviewSource
  reviewState = newReview(b.text, proposed)
  reviewSource = source
  if reviewState.hunks.len == 0:
    mode = ""
    reviewBuf = nil
    echoLine = "Applied " & $taken & " hunks; nothing left to review"
    return
  currentHunk = min(currentHunk, reviewState.hunks.high)
  rebuildReview()
  echoLine = "Applied " & $taken & " hunks; " & $reviewState.hunks.len & " left"

proc finishReview*(cancel = false) =
  if cancel: echoLine = "Review cancelled"
  else:
    let total = reviewState.hunks.len
    echoLine = "Applied " & $applyDecisions() & " of " & $total & " hunks"
  mode = ""
  reviewBuf = nil
  reviewColors = @[]
  reviewBgs = @[]
  reviewState = Review()
  renderer.top = savedTop
  renderer.left = savedLeft

proc cleanAgentFiles*() =
  if agentDir.len == 0: return
  try:
    for name in ["prompt.txt", "out.txt", "err.txt"]:
      let path = agentDir / name
      if fileExists(path): removeFile(path)
    removeDir(agentDir)
  except OSError as e: echoLine = "Agent cleanup: " & e.msg
  agentDir = ""

proc launchAgent*(command, input: string, workingDir = "") =
  if agentProcess != nil: raise newException(ValueError, "Agent already running")
  agentDir = createTempDir("darger-agent-", "")
  try:
    when defined(windows):
      agentJob = createJobObject(nil, nil)
      if agentJob == 0: raiseOSError(osLastError())
    writeFile(agentDir / "prompt.txt", input)
    when defined(windows):
      let redirected = command & " < \"" & agentDir / "prompt.txt" & "\" > \"" &
        agentDir / "out.txt" & "\" 2> \"" & agentDir / "err.txt" & "\""
      # Gate the CLI until cmd.exe belongs to the job, so no child escapes cancellation.
      agentProcess = startProcess("cmd /d /s /c \"set /p dargerAgentReady= >nul & " & redirected & "\"",
        workingDir = workingDir, options = {poEvalCommand, poUsePath, poDaemon})
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
      agentProcess = startProcess("/bin/sh", workingDir = workingDir, args = ["-c", shell], options = {poUsePath})
    agentCancelled = false
    agentStartedAt = epochTime()
    agentReadSize = -1
    agentOutput = ChatOutput()
    agentBuf = b
    echoLine = "Agent running 0:00"
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

proc startAgent*(instruction: string) =
  if agentProcess != nil: raise newException(ValueError, "Agent already running")
  let command = interp.env.values["agent-command"].asString
  if strutils.strip(command).len == 0: raise newException(ValueError, "agent-command is empty")
  # ponytail: full-file round trips are unsuitable for huge files; add region-only input if needed.
  launchAgent(command,
    "You are editing a text file. Apply the instruction to the file and output ONLY the complete new file content. No explanations, no code fences.\n" &
    "File path: " & (if b.path.len > 0: b.path else: "(unnamed)") & "\n" &
    "Instruction: " & instruction & "\n--- FILE START ---\n" & b.text & "\n--- FILE END ---\n")

proc currentChatRoot*(): string =
  let session = chatFor(b)
  if session != nil: session.root
  elif b.path.len > 0: rootOf(b.path)
  else: rootFromDir(getCurrentDir())

proc setChatText*(session: ChatSession, text: string): bool {.discardable.} =
  if session.buf.text == text: return false
  let point = session.buf.cursor
  let follow = b == session.buf and point.line == session.buf.lines.high
  session.buf.splice(0, session.buf.text.runeLen, text)  # no undo snapshot for live output
  session.buf.modified = false
  session.buf.regionActive = false
  session.buf.markSet = false
  let line = if follow: session.buf.lines.high else: min(point.line, session.buf.lines.high)
  session.buf.cursor = (line, min(point.col, session.buf.lines[line].len))
  session.buf.finish()
  true

proc sendChat*(message: string) =
  var session = chats.getOrDefault(chatRoot)
  if message.len == 0:
    if session != nil: switchTo(session.buf)
    return
  if agentProcess != nil: raise newException(ValueError, "Agent already running")
  let variable = if session != nil and session.started: "agent-chat-resume-command" else: "agent-chat-command"
  let command = interp.env.values[variable].asString
  if strutils.strip(command).len == 0: raise newException(ValueError, variable & " is empty")
  if session == nil:
    session = ChatSession(root: chatRoot, id: sessionId(), buf: newBuffer())
  launchAgent(expandId(command, session.id), message, session.root)
  agentChat = session
  chats[chatRoot] = session
  reg.add(session.buf, "*agent " & extractFilename(chatRoot) & "*")
  session.turn = appendTurn(session.buf.text, session.root, message)
  session.setChatText(session.turn.text)
  switchTo(session.buf)
  session.buf.cursor = (session.buf.lines.high, 0)

proc updateChat*(code = -1): bool =
  let session = agentChat
  if session.buf notin reg:
    if code != -1: echoLine = "Agent: transcript was killed; reply dropped"
    return
  let path = agentDir / "out.txt"
  if fileExists(path) and getFileSize(path) > agentReadSize:
    let output = readFile(path)
    agentReadSize = output.len.int64
    let activity = agentOutput.activity
    try:
      # ponytail: reparse the grown file; use incremental parsing if long runs make this costly.
      agentOutput = renderOutput(output)
    except ValueError as e:
      if not agentOutput.isError:
        if agentOutput.reply.len > 0: agentOutput.reply.add "\n\n"
        agentOutput.reply.add "(failed: " & e.msg & ")"
      agentOutput.isError = true
    result = activity != agentOutput.activity
  elif code == -1: return false
  var reply = strutils.strip(agentOutput.reply.replace("\r\n", "\n"), leading = false)
  var ending: string
  if code == -1: ending = "..."
  elif agentCancelled: ending = "(cancelled)"
  elif code != 0 and not agentOutput.isError:  # else the stream already said why
    let errors = readFile(agentDir / "err.txt")
    ending = "(failed: " & (if validateUtf8(errors) == -1: failureLine(errors, code)
                           else: "exit code " & $code) & ")"
  elif not agentOutput.isError: session.started = true
  # claude refuses a --session-id it has seen, even from a run that failed or was cancelled
  if code != -1 and not session.started: session.id = sessionId()
  if ending.len > 0:
    if reply.len > 0: reply.add "\n\n"
    reply.add ending
  # ponytail: rebuild the sent transcript; track a moving span if in-flight transcript editing is needed.
  if session.setChatText(replaceReply(session.turn, reply)): result = true
  if code != -1:
    echoLine = if b == session.buf: "" else: "Agent replied (C-c c Enter to read)"

proc cancelAgent*() =
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
  echoLine = "Agent cancelling..."

proc cleanAgentOutput*(text: string): string =
  result = text.replace("\r\n", "\n")
  let tail = strutils.strip(result, leading = false)
  if tail.endsWith("```") and (tail.len == 3 or tail[^4] == '\n'):
    result = tail[0..<tail.len - 3]
    if result.startsWith("```"):
      let newline = result.find('\n')
      if newline >= 0: result = result[newline + 1..^1]

proc pollAgent*(): bool =
  if agentProcess == nil: return false
  let code = agentProcess.peekExitCode()
  if code == -1:
    return if agentChat != nil: updateChat() else: false
  result = true
  agentProcess.close()
  agentProcess = nil
  when defined(windows):
    discard closeHandle(agentJob)
    agentJob = 0
  try:
    if agentChat != nil: discard updateChat(code)
    elif agentCancelled:
      reviewRequest = false
      echoLine = "Agent cancelled"
    elif code != 0:
      reviewRequest = false
      let errors = readFile(agentDir / "err.txt").splitLines()
      echoLine = if errors.len > 0 and errors[0].len > 0: errors[0] else: "Agent exited with code " & $code
    else:
      let text = cleanAgentOutput(readFile(agentDir / "out.txt"))
      if validateUtf8(text) != -1: raise newException(ValueError, "Agent output is not valid UTF-8")
      if agentBuf notin reg: raise newException(ValueError, "Agent: its buffer was killed")
      if reviewRequest:
        # The answer to a request for changes: the new proposal replaces the review's.
        reviewRequest = false
        if mode == "review" and b == agentBuf:
          let at = currentHunk
          beginReviewText(text, "Agent")
          if mode == "review":
            currentHunk = min(at, reviewState.hunks.high)
            rebuildReview()
            echoLine = "Agent changed the proposal: " & $reviewState.hunks.len & " hunks"
          else: echoLine = "Agent: the new proposal has no changes"
        else: echoLine = "Agent answered, but the review was closed"
      else:
        abandonLine()
        switchTo(agentBuf)  # review the buffer the instruction was about
        beginReview(text)
  except CatchableError as e: echoLine = e.msg
  finally:
    agentChat = nil
    cleanAgentFiles()

proc requestChanges*(instruction: string) =
  ## r: the reviewer's instruction for the current hunk goes to the agent with the
  ## whole proposal and that hunk; its complete new text replaces the proposal.
  if mode != "review": raise newException(ValueError, "No review is open")
  let command = interp.env.values["agent-command"].asString
  if strutils.strip(command).len == 0: raise newException(ValueError, "agent-command is empty")
  let (removed, added) = reviewState.hunkText(currentHunk)
  agentBuf = b
  reviewRequest = true
  launchAgent(command,
    "You proposed a new version of a text file. A reviewer asks for a change to one hunk of it. " &
    "Apply the request to the proposed version (keep everything else as proposed) and output ONLY the " &
    "complete new file content. No explanations, no code fences.\n" &
    "File path: " & (if b.path.len > 0: b.path else: "(unnamed)") & "\n" &
    "Request: " & instruction & "\n" &
    "--- HUNK: LINES THE PROPOSAL REMOVES ---\n" & removed &
    "--- HUNK: LINES THE PROPOSAL ADDS ---\n" & added &
    "--- PROPOSED FILE START ---\n" & reviewState.proposedText() & "\n--- PROPOSED FILE END ---\n")
  echoLine = "Agent: changing hunk " & $(currentHunk + 1) & "..."

definePrompt(Prompt(kind: "review-request", text: true, over: "review", onAccept: proc(value: string): bool =
  if strutils.strip(value).len == 0: return false
  try: requestChanges(value)
  except CatchableError as e: echoLine = e.msg
  true))
interp.defPrimitive("review-request-changes", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  requestChanges(args[0].asString)
  nilValue())

var hunkRows: seq[string]
definePrompt(Prompt(kind: "review-hunks", text: true, over: "review", candidates: proc(): seq[string] = hunkRows,
  onAccept: proc(value: string): bool =
    let i = hunkRows.find(value)
    if i >= 0 and i < reviewState.hunks.len:
      currentHunk = i
      rebuildReview()
    true))

proc dispatchReview*(c: string) =
  case c
  of "C-g":
    for hook in cancelHooks: hook()
    finishReview(true)
  of "n": currentHunk = min(currentHunk + 1, reviewState.hunks.high)
  of "p": currentHunk = max(currentHunk - 1, 0)
  of "y", "k":
    reviewState.decisions[currentHunk] = if c == "y": accepted else: rejected
    currentHunk = min(currentHunk + 1, reviewState.hunks.high)
  of "u": reviewState.decisions[currentHunk] = pending
  of "A":
    for decision in reviewState.decisions.mitems:
      if decision == pending: decision = rejected
    finishReview()
    return
  of "w":
    applyAndContinue()
    return
  of "r":
    if agentProcess != nil: echoLine = "Agent already running"
    else: beginMini("review-request", "Request changes to hunk " & $(currentHunk + 1) & ": ")
    return
  of "l":
    hunkRows = @[]
    for i in 0..<reviewState.hunks.len: hunkRows.add reviewState.hunkLabel(i)
    beginMini("review-hunks", "Hunk: ")
    return
  of "?":
    echoLine = "y: take the proposed hunk  k: keep the buffer's  u: undo the decision  " &
      "n / p: move  l: list  r: ask the agent to change this hunk  w: apply so far, go on  " &
      "a / A: take / keep all pending and finish  q / Enter: apply decisions  C-g: cancel"
    return
  of "a":
    for decision in reviewState.decisions.mitems:
      if decision == pending: decision = accepted
    finishReview()
    return
  of "enter", "C-m", "C-j", "q":
    finishReview()
    return
  else:
    echoLine = c & " is undefined"
    return
  if mode == "review": rebuildReview()

interp.defPrimitive("agent", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  startAgent(args[0].asString)
  nilValue())

interp.defPrimitive("agent-prompt", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  beginMini("agent", "Agent: ")
  nilValue())

interp.defPrimitive("agent-chat", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  chatRoot = currentChatRoot()
  beginMini("chat", "Agent chat (" & extractFilename(chatRoot) & "): ")
  nilValue())

interp.defPrimitive("agent-chat-new", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let session = chats.getOrDefault(currentChatRoot())
  if session != nil:
    if agentChat == session and agentProcess != nil:
      raise newException(ValueError, "Agent already running")
    session.id = sessionId()
    session.started = false
    session.turn = Turn()
    session.setChatText("")
  nilValue())

reviewHook = proc(proposed, source: string) = beginReview(proposed, source)

proc reviewAgainst(path, source: string) =
  ## The buffer reviewed against the file at `path`, read as a buffer would be.
  if b.path.len == 0 and source == "file on disk":
    echoLine = "Buffer has no file"
    return
  try: beginReview(loadBuffer(path).text, source)
  except CatchableError as e: echoLine = e.msg

interp.defPrimitive("diff-buffer-with-file", proc(args: seq[Value]): Value =
  ## The buffer against its file on disk: y takes the file's version of a hunk.
  args.arity(0, 0)
  reviewAgainst(b.path, "file on disk")
  nilValue())
interp.defPrimitive("review-file", proc(args: seq[Value]): Value =
  ## (review-file "other") compares the buffer with another file; no argument asks for one.
  args.arity(0, 1)
  if args.len == 0: beginMini("review-file", "Review against file: ")
  else: reviewAgainst(expandTilde(args[0].asString), shortPath(expandTilde(args[0].asString)))
  nilValue())
definePrompt(Prompt(kind: "review-file", text: true, paths: true, onAccept: proc(value: string): bool =
  if value.len == 0: return false
  reviewAgainst(value, shortPath(value))
  true))
interp.defPrimitive("vc-review", proc(args: seq[Value]): Value =
  ## The buffer against the file as committed (git HEAD): y takes the committed version.
  args.arity(0, 0)
  if b.path.len == 0:
    echoLine = "Buffer has no file"
    return nilValue()
  let root = rootFromDir(parentDir(b.path))
  if not (dirExists(root / ".git") or fileExists(root / ".git")):
    echoLine = "Not in a git repository: " & shortPath(b.path)
    return nilValue()
  let rel = relativePath(b.path, root).replace('\\', '/')
  let (output, code) = execCmdEx("git -C " & quoteShell(root) & " show HEAD:" & quoteShell(rel), options = {poUsePath})
  if code != 0:
    echoLine = "git: " & strutils.strip(output).splitLines()[0]
    return nilValue()
  beginReview(output.replace("\r\n", "\n"), "git HEAD")
  nilValue())

defineMode(core.Mode(name: "review", tag: "[Review]", editing: true, buffer: proc(): Buffer = reviewBuf,
  colors: proc(): seq[int8] = reviewColors, bgs: proc(): seq[seq[int8]] = reviewBgs,
  message: proc(): string = reviewMessage() & (if echoLine != reviewMessage(): "  " & echoLine else: ""),
  onKey: dispatchReview, onClose: proc() = finishReview(true)))

definePrompt(Prompt(kind: "agent", text: true, onAccept: proc(value: string): bool =
  startAgent(value)
  true))

definePrompt(Prompt(kind: "chat", text: true, onAccept: proc(value: string): bool =
  sendChat(value)
  true))

messageHooks.add proc(): string =
  if agentProcess == nil: return ""
  let elapsed = max(0, int(epochTime() - agentStartedAt))
  (if agentCancelled: "Agent cancelling..."
   else: "Agent running " & $(elapsed div 60) & ":" & align($(elapsed mod 60), 2, '0') &
     (if agentOutput.activity.len > 0: "  " & agentOutput.activity else: "")) &
    (if echoLine.endsWith("Agent already running"): "  " & echoLine else: "")

exitHooks.add proc() =
  if agentProcess == nil: return
  cancelAgent()
  when not defined(windows):
    # A CLI that ignores TERM would block waitForExit forever; hard-kill like TerminateJobObject.
    let deadline = epochTime() + 1.5  # total exit (grace + SIGKILL + reap) stays under 2 s
    while agentProcess.peekExitCode() == -1 and epochTime() < deadline: sleep(20)
    let pid = Pid(agentProcess.processID)
    if agentGroup: discard posix.kill(-pid, SIGKILL)  # the sh leader may be gone while the CLI ignored TERM; ESRCH is fine
    elif agentProcess.peekExitCode() == -1: discard posix.kill(pid, SIGKILL)
  discard agentProcess.waitForExit()
  agentProcess.close()
  when defined(windows): discard closeHandle(agentJob)
  cleanAgentFiles()
cancelHooks.add proc() =
  if agentProcess != nil: cancelAgent()
killHooks.add proc(buf: Buffer) =
  let session = chatFor(buf)
  if session != nil: chats.del(session.root)
modifiedIgnore.add proc(buf: Buffer): bool = chatFor(buf) != nil
langHints.add proc(buf: Buffer): string = (if chatFor(buf) != nil: "chat.md" else: "")
busyHooks.add proc(): bool = agentProcess != nil
tickHooks.add pollAgent
argCommands.add "agent"
defaults.add """
(global-set-key "C-c a" 'agent-prompt)
(global-set-key "C-c c" 'agent-chat)
(setq agent-command "claude -p --output-format text")
(setq agent-chat-command "claude -p --output-format stream-json --verbose --session-id {id}")
(setq agent-chat-resume-command "claude -p --output-format stream-json --verbose --resume {id}")
"""
