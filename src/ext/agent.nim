## Agents: a one-shot edit reviewed hunk by hunk (C-c a, review.nim), and a multi-turn
## chat per project root with a live transcript (C-c c, chat.nim).
import std/[os, osproc, tempfiles, strutils, unicode, times, tables, sequtils]
from windy import closeIme
import ../[core, buffer, buffers, render, lisp, review, chat, lsp, changes, ledger]

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
  chatBefore: Snapshot      # the chat root's files when the turn started
  agentChanged*: seq[string]  # files the last chat turn changed, relative to its root
  agentChangedRoot*: string
  chatRoot*: string
when defined(windows):
  var agentJob*: Handle
else:
  var agentGroup*: bool

var
  reviewSource = "Agent"  # what the proposed text is: the agent, the file on disk, git HEAD, a file
  reviewRequest = false   # the running agent answers a request for changes to the open review
  reviewExplain = false   # the running agent explains a hunk (x)
  reviewAsk = false       # the running agent answers a question about a hunk (X)
  reviewReadOnly = false  # a comparison (branch base -> buffer): nothing is taken, only understood
  afterReview*: proc()    # run once when the review closes (the understanding buffer comes back)
  onAgentResult*: proc(text: string)  # takes the next one-shot agent's output instead of a review
  askQuestion = ""
  explainHunk = -1
  explained: seq[bool]        # per hunk: an explanation was read
  explanations: seq[string]   # per hunk: the explanation
  explainBuf: Buffer          # *explain*, shown beside the review

proc resetUnderstanding() =
  explained = newSeq[bool](reviewState.hunks.len)
  explanations = newSeq[string](reviewState.hunks.len)

proc ledgerPath*(): string =
  let v = interp.env.values["understanding-ledger"]
  if v.kind == vNil: "" else: expandTilde(v.asString)

proc glossaryPath*(): string =
  let v = interp.env.values["glossary-file"]
  if v.kind == vNil: "" else: expandTilde(v.asString)

proc showExplain(text: string) =
  ## *explain* in the other pane (made by splitting when there is one), the review pane kept.
  if explainBuf == nil or explainBuf notin reg:
    explainBuf = newBuffer()
    reg.add(explainBuf, "*explain*")
  explainBuf.splice(0, explainBuf.text.runeLen, text)
  explainBuf.modified = false
  explainBuf.cursor = (0, 0)
  let other = otherPaneFor()
  if other != nil and other != pane:
    other.buf = explainBuf
    other.top = 0
    other.cursor = (0, 0)

proc currentRoot*(): string = rootFromDir(if b.path.len > 0: parentDir(b.path) else: getCurrentDir())

proc git*(root, args: string): tuple[output: string, ok: bool] =
  let (output, code) = execCmdEx("git -C " & quoteShell(root) & " " & args, options = {poUsePath})
  (strutils.strip(output), code == 0)

proc fileRev*(root, path: string): string =
  ## The file's last-change commit (short), "" outside git or for an uncommitted file.
  if root.len == 0 or not (dirExists(root / ".git") or fileExists(root / ".git")): return ""
  let (output, ok) = git(root, "log -1 --format=%h -- " & quoteShell(path))
  if ok: output else: ""

proc recordUnderstanding() =
  ## The ledger entries: for the agent's or the disk's proposal, every hunk taken
  ## (DONE when explained or attested, else TODO: debt); for a branch-base review,
  ## every hunk (the branch's own work, understood or not), with the file's commit.
  let path = ledgerPath()
  if path.len == 0 or reviewSource notin ["Agent", "file on disk", "branch base"]: return
  let root = currentRoot()
  let branch = branchOf(root)
  let rev = if b.path.len > 0: fileRev(root, b.path) else: ""
  var entries: seq[LedgerEntry]
  var shift = 0
  for i, h in reviewState.hunks:
    if reviewReadOnly or reviewState.decisions[i] == accepted:
      let (removed, added) = reviewState.hunkText(i)
      entries.add LedgerEntry(file: (if b.path.len > 0: b.path else: "(unnamed)"),
        line: (if reviewReadOnly: h.startB + 1 else: h.startA + shift + 1),
        project: extractFilename(root), source: reviewSource, removed: removed, added: added, branch: branch, rev: rev,
        explanation: (if i < explained.len and explained[i]: explanations[i] else: ""), at: now())
    if reviewState.decisions[i] == accepted: shift += h.insertedB - h.deletedA
  if entries.len == 0: return
  try: appendEntries(path, entries)
  except CatchableError as e: echoLine = "Ledger: " & e.msg

proc reviewMessage*(): string =
  let (removed, added) = reviewState.stats(currentHunk)
  let head = (if reviewReadOnly: "Understand " else: "Review ") & reviewSource & ": hunk " & $(currentHunk + 1) & "/" &
    $reviewState.hunks.len & " (-" & $removed & " +" & $added & ")"
  if reviewReadOnly: head & "  x:explain X:ask U:understood n/p l:list q:record ?:help"
  else: head & "  y:take k:keep u:undo n/p l:list r:request a:all q:done ?:help"

proc rebuildReview*() =
  let display = reviewState.view(currentHunk)
  reviewBuf = newBuffer(display.text)
  reviewBuf.path = b.path
  reviewColors = display.colors
  reviewBgs = display.bgs
  reviewBuf.cursor = (min(display.starts[currentHunk], reviewBuf.lines.high), 0)
  renderer.top = max(0, reviewBuf.cursor.line - 3)  # a few lines of context above the hunk
  renderer.left = 0
  echoLine = reviewMessage()

proc beginReviewText(proposed, source: string)  # forward: the review replaced in place

proc openReview() =
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

proc beginReview*(proposed: string, source = "Agent") =
  ## A hunk-by-hunk review of the current buffer against `proposed`: y takes the
  ## proposed version of a hunk, k keeps the buffer's. Any source can propose text.
  reviewSource = source
  reviewReadOnly = false
  reviewState = newReview(b.text, proposed)
  resetUnderstanding()
  if reviewState.hunks.len == 0:
    echoLine = source & ": no changes"
    return
  openReview()

proc beginComparison*(base: string, source: string) =
  ## The buffer as the outcome of work from `base` (a branch's base version): hunks
  ## read base -> buffer, nothing is taken; x, X and U build understanding, q records.
  reviewSource = source
  reviewReadOnly = true
  reviewState = newReview(base, b.text)
  resetUnderstanding()
  if reviewState.hunks.len == 0:
    echoLine = source & ": no changes"
    return
  openReview()

proc beginReviewText(proposed, source: string) =
  ## The open review's proposal replaced (decisions start over); closes it when nothing differs.
  reviewSource = source
  reviewState = newReview(b.text, proposed)
  resetUnderstanding()
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
  recordUnderstanding()
  let taken = applyDecisions()
  let proposed = reviewState.proposedText()
  let source = reviewSource
  reviewState = newReview(b.text, proposed)
  resetUnderstanding()
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
  elif reviewReadOnly:
    var understood = 0
    for e in explained:
      if e: inc understood
    recordUnderstanding()
    echoLine = "Recorded " & $reviewState.hunks.len & " hunks, " & $understood & " understood"
  else:
    let total = reviewState.hunks.len
    recordUnderstanding()
    echoLine = "Applied " & $applyDecisions() & " of " & $total & " hunks"
  mode = ""
  reviewBuf = nil
  reviewColors = @[]
  reviewBgs = @[]
  reviewState = Review()
  renderer.top = savedTop
  renderer.left = savedLeft
  if afterReview != nil:
    let f = afterReview
    afterReview = nil
    f()

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
  chatBefore = snapshot(session.root)
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
    if agentChat != nil:
      let root = agentChat.root
      discard updateChat(code)
      agentChanged = changedSince(chatBefore, root)
      agentChangedRoot = root
      chatBefore = Snapshot()
      if agentChanged.len > 0:
        let summary = "Agent changed " & $agentChanged.len & (if agentChanged.len == 1: " file" else: " files") &
          ": " & agentChanged[0..min(2, agentChanged.high)].join(", ") &
          (if agentChanged.len > 3: ", ..." else: "")
        echoLine = summary & "  (M-x agent-changes to review)"
        # Also in the transcript, where it stays after the echo line moves on.
        let transcript = agentChat.buf
        if transcript in reg:
          let point = transcript.cursor
          let text = strutils.strip(transcript.text, leading = false) & "\n\n> " & summary &
            " (M-x agent-changes to review)\n"
          transcript.splice(0, transcript.text.runeLen, text)
          transcript.modified = false
          transcript.cursor = (min(point.line, transcript.lines.high), 0)
    elif agentCancelled:
      reviewRequest = false
      reviewExplain = false
      reviewAsk = false
      onAgentResult = nil
      echoLine = "Agent cancelled"
    elif code != 0:
      reviewRequest = false
      reviewExplain = false
      reviewAsk = false
      onAgentResult = nil
      let errors = readFile(agentDir / "err.txt").splitLines()
      echoLine = if errors.len > 0 and errors[0].len > 0: errors[0] else: "Agent exited with code " & $code
    else:
      let text = cleanAgentOutput(readFile(agentDir / "out.txt"))
      if validateUtf8(text) != -1: raise newException(ValueError, "Agent output is not valid UTF-8")
      if agentBuf notin reg: raise newException(ValueError, "Agent: its buffer was killed")
      if onAgentResult != nil:
        let f = onAgentResult
        onAgentResult = nil
        f(text)
      elif reviewAsk:
        reviewAsk = false
        if explainHunk in 0..<explained.len:
          explained[explainHunk] = true
          let qa = "Q: " & askQuestion & "\nA: " & strutils.strip(text)
          explanations[explainHunk] = if explanations[explainHunk].len > 0 and
              explanations[explainHunk] != "(understood by the reviewer)":
            strutils.strip(explanations[explainHunk]) & "\n\n" & qa
            else: qa
          showExplain("Hunk " & $(explainHunk + 1) & "\n\n" & explanations[explainHunk] & "\n")
        let glossary = glossaryPath()
        let terms = glossaryTerms(text)
        if glossary.len > 0 and terms.len > 0:
          try:
            let old = if fileExists(glossary): readFile(glossary) else: ""
            writeFile(glossary, mergeGlossary(old, terms))
          except CatchableError as e: echoLine = "Glossary: " & e.msg
        echoLine = "Answered about hunk " & $(explainHunk + 1)
      elif reviewExplain:
        reviewExplain = false
        if explainHunk in 0..<explained.len:
          explained[explainHunk] = true
          explanations[explainHunk] = text
        showExplain("Hunk " & $(explainHunk + 1) & "\n\n" & strutils.strip(text) & "\n")
        let glossary = glossaryPath()
        let terms = glossaryTerms(text)
        if glossary.len > 0 and terms.len > 0:
          try:
            let old = if fileExists(glossary): readFile(glossary) else: ""
            writeFile(glossary, mergeGlossary(old, terms))
          except CatchableError as e: echoLine = "Glossary: " & e.msg
        echoLine = "Explained hunk " & $(explainHunk + 1) & (if terms.len > 0: "; " & $terms.len & " terms to the glossary" else: "")
      elif reviewRequest:
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

const explainInstructions =
    "Explain in plain language, in the reviewer's language if the file suggests one (Japanese for Japanese text): " &
    "what the hunk changes, why one would make this change, and what to watch out for. Then list every domain-specific " &
    "or technical term the hunk relies on as Org description items, one per line, exactly in the form `- term :: definition`. " &
    "Output plain text with those items; no code fences, no headings.\n"

proc explainCurrentHunk*() =
  ## x: the agent explains the current hunk (what, why, and the domain terms in it as
  ## `- term :: definition`); the hunk counts as understood when taken afterwards.
  if mode != "review": raise newException(ValueError, "No review is open")
  if agentProcess != nil: raise newException(ValueError, "Agent already running")
  let command = interp.env.values["agent-command"].asString
  if strutils.strip(command).len == 0: raise newException(ValueError, "agent-command is empty")
  let (removed, added) = reviewState.hunkText(currentHunk)
  agentBuf = b
  reviewExplain = true
  explainHunk = currentHunk
  launchAgent(command,
    "A reviewer is deciding whether to take one hunk of a proposed change to a text file and wants to understand it. " &
    explainInstructions &
    "File path: " & (if b.path.len > 0: b.path else: "(unnamed)") & "\n" &
    "--- HUNK: LINES REMOVED ---\n" & removed & "--- HUNK: LINES ADDED ---\n" & added &
    "--- WHOLE PROPOSED FILE (context) ---\n" & reviewState.proposedText() & "\n--- END ---\n")
  showExplain("Explaining hunk " & $(currentHunk + 1) & "...")
  echoLine = "Agent: explaining hunk " & $(currentHunk + 1) & "..."

proc repayUnderstanding*() =
  ## Explain the nearest recorded debt for this file, regardless of branch.
  if b.path.len == 0:
    echoLine = "Current buffer has no file path"
    return
  if agentProcess != nil: raise newException(ValueError, "Agent already running")
  let path = ledgerPath()
  let old = if path.len > 0 and fileExists(path): readFile(path) else: ""
  let index = debtNear(old, b.path, b.cursor.line + 1)
  if index < 0:
    echoLine = "No understanding debt recorded for this file"
    return
  let entry = entries(old)[index]
  let command = interp.env.values["agent-command"].asString
  if strutils.strip(command).len == 0: raise newException(ValueError, "agent-command is empty")
  let root = currentRoot()
  let glossary = glossaryPath()
  let lines = b.text.splitLines
  let center = min(entry.line - 1, lines.high)
  let context = lines[max(0, center - 40)..min(lines.high, center + 40)].join("\n")
  onAgentResult = proc(text: string) =
    showExplain(text)
    writeFile(path, markDone(readFile(path), entry.file, entry.line, text))
    let terms = glossaryTerms(text)
    if glossary.len > 0 and terms.len > 0:
      let previous = if fileExists(glossary): readFile(glossary) else: ""
      writeFile(glossary, mergeGlossary(previous, terms))
    echoLine = "Repaid " & shortPath(entry.file, 50) & ":" & $entry.line
  try:
    launchAgent(command,
      "A reviewer wants to understand a previously recorded change to a text file. " & explainInstructions &
      "File path: " & entry.file & ":" & $entry.line & "\n" &
      "--- RECORDED HUNK (diff) ---\n" & entryHunk(old, index) &
      "--- CURRENT FILE (context) ---\n" & context & "\n--- END ---\n", root)
  except CatchableError:
    onAgentResult = nil
    raise
  showExplain("Explaining debt " & entry.file & ":" & $entry.line & "...")
  echoLine = "Agent: explaining understanding debt..."

interp.defPrimitive("understanding-repay", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  repayUnderstanding()
  nilValue())

proc askAboutHunk*(question: string) =
  ## X: a follow-up question about the current hunk; the answer joins the explanation
  ## shown in *explain* and recorded in the ledger.
  if mode != "review": raise newException(ValueError, "No review is open")
  if agentProcess != nil: raise newException(ValueError, "Agent already running")
  let command = interp.env.values["agent-command"].asString
  if strutils.strip(command).len == 0: raise newException(ValueError, "agent-command is empty")
  let (removed, added) = reviewState.hunkText(currentHunk)
  let sofar = if currentHunk < explanations.len: explanations[currentHunk] else: ""
  agentBuf = b
  reviewAsk = true
  askQuestion = question
  explainHunk = currentHunk
  launchAgent(command,
    "A reviewer is trying to understand one hunk of a proposed change to a text file and asks a question about it. " &
    "Answer it directly and plainly, in the reviewer's language; define any domain term you use as `- term :: definition` " &
    "lines at the end. No code fences, no headings.\n" &
    "File path: " & (if b.path.len > 0: b.path else: "(unnamed)") & "\n" &
    "Question: " & question & "\n" &
    (if sofar.len > 0: "--- EXPLANATION GIVEN SO FAR ---\n" & sofar & "\n" else: "") &
    "--- HUNK: LINES REMOVED ---\n" & removed & "--- HUNK: LINES ADDED ---\n" & added &
    "--- WHOLE PROPOSED FILE (context) ---\n" & reviewState.proposedText() & "\n--- END ---\n")
  showExplain((if sofar.len > 0: "Hunk " & $(currentHunk + 1) & "\n\n" & strutils.strip(sofar) & "\n\n" else: "") &
    "Q: " & question & "\nA: ...")
  echoLine = "Agent: answering about hunk " & $(currentHunk + 1) & "..."

definePrompt(Prompt(kind: "review-ask", text: true, over: "review", onAccept: proc(value: string): bool =
  if strutils.strip(value).len == 0: return false
  try: askAboutHunk(value)
  except CatchableError as e: echoLine = e.msg
  true))
interp.defPrimitive("review-ask", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  askAboutHunk(args[0].asString)
  nilValue())

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

proc reviewChanged(rel: string) =
  ## A file the agent changed: against the buffer's own text when it differs from the
  ## disk, else against git HEAD, else just visited.
  let path = agentChangedRoot / rel
  if not fileExists(path):
    echoLine = rel & " was deleted"
    return
  visit(path)
  if loadBuffer(path).text != b.text: beginReview(loadBuffer(path).text, "file on disk")
  else:
    let (output, code) = execCmdEx("git -C " & quoteShell(agentChangedRoot) & " show HEAD:" & quoteShell(rel),
      options = {poUsePath})
    if code == 0: beginReview(output.replace("\r\n", "\n"), "git HEAD")
    else: echoLine = rel & ": new file (nothing to compare)"

definePrompt(Prompt(kind: "agent-changes", text: true, candidates: proc(): seq[string] = agentChanged,
  onAccept: proc(value: string): bool =
    if value in agentChanged: reviewChanged(value)
    true))
interp.defPrimitive("agent-changes", proc(args: seq[Value]): Value =
  ## The files the last chat turn changed; Enter opens the file in a review.
  args.arity(0, 0)
  if agentChanged.len == 0: echoLine = "The last agent chat turn changed no files"
  else: beginMini("agent-changes", "Agent changed (" & extractFilename(agentChangedRoot) & "): ")
  nilValue())

# The ledger and the glossary outside a review

var debtRows: seq[tuple[label, file: string, line: int]]
definePrompt(Prompt(kind: "understanding-debt", text: true, candidates: proc(): seq[string] =
    debtRows.mapIt(it.label),
  onAccept: proc(value: string): bool =
    for e in debtRows:
      if e.label == value:
        try:
          visit(e.file)
          b.cursor = (min(e.line - 1, b.lines.high), 0)
        except CatchableError as err: echoLine = err.msg
        break
    true))
proc listDebt(allBranches: bool) =
  let path = ledgerPath()
  if path.len == 0 or not fileExists(path):
    echoLine = "No understanding ledger yet (reviews write " & (if path.len > 0: shortPath(path) else: "none") & ")"
    return
  let text = readFile(path)
  let branch = if allBranches: "" else: branchOf(currentRoot())
  debtRows = debtEntries(text, branch)
  let (debt, understood) = debtCount(text)
  let where = if branch.len > 0: " on " & branch else: ""
  if debtRows.len == 0:
    echoLine = "No understanding debt" & where & " (" & $debt & " open elsewhere, " & $understood & " understood)"
    return
  beginMini("understanding-debt", "Debt" & where & " (" & $debtRows.len & " open, " & $understood & " understood): ")

interp.defPrimitive("understanding-debt", proc(args: seq[Value]): Value =
  ## The ledger's TODO entries of the current branch (all outside git); Enter visits the spot.
  args.arity(0, 0)
  listDebt(false)
  nilValue())
interp.defPrimitive("understanding-debt-all", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  listDebt(true)
  nilValue())

# Branch debt: the files this branch changed from its base that no DONE entry of the
# branch attests to (at the file's current commit); each opens a review against the base.
var
  branchRows: seq[string]
  branchFiles: seq[tuple[rel, base: string]]
  branchRoot*: string

type BranchFile* = object
  rel*: string
  plus*, minus*: int
  dirty*: bool        ## uncommitted changes in the working tree
  understood*: bool   ## a DONE entry of the branch attests to it at its current commit

proc branchChanges*(root, branch, base: string): tuple[mergeBase: string, files: seq[BranchFile], error: string] =
  ## The branch's work: files changed since the merge base with `base`, with +/- line
  ## counts, in three git calls for the whole list (numstat, the dirty files, and the
  ## last-change commits of the files the ledger knows), so large branches stay quick.
  result.mergeBase = base
  if branch != base:
    let (mb, ok) = git(root, "merge-base " & quoteShell(base) & " HEAD")
    if ok and mb.len > 0: result.mergeBase = mb
  let (numstat, ok) = git(root, "diff --numstat " & quoteShell(result.mergeBase))
  if not ok:
    result.error = numstat.splitLines()[0]
    return
  var dirty: seq[string]
  let (dirtyOut, _) = git(root, "diff --name-only")
  for l in dirtyOut.splitLines:
    if l.len > 0: dirty.add l
  var understood: seq[tuple[file, rev: string]]
  let ledger = ledgerPath()
  if ledger.len > 0 and fileExists(ledger): understood = understoodRevs(readFile(ledger), branch)
  for l in numstat.splitLines:
    let parts = l.split('\t')
    if parts.len < 3: continue
    var f = BranchFile(rel: parts[2], dirty: parts[2] in dirty)
    f.plus = try: parseInt(parts[0]) except ValueError: 0   # "-" for binary files
    f.minus = try: parseInt(parts[1]) except ValueError: 0
    let path = root / f.rel
    if not f.dirty and understood.anyIt(it.file == path):
      let rev = fileRev(root, path)   # only for files the ledger attests to
      f.understood = (path, rev) in understood
    result.files.add f

proc plusMinus*(f: BranchFile): string =
  result = (if f.plus > 0: "+" & $f.plus else: "") & (if f.plus > 0 and f.minus > 0: " " else: "") &
    (if f.minus > 0: "-" & $f.minus else: "")
  if result.len == 0: result = "±0"

proc baseBranch*(root: string): string =
  let v = interp.env.values["understanding-base-branch"]
  if v.kind != vNil and v.asString.len > 0: return v.asString
  for name in ["main", "master", "develop"]:
    if git(root, "rev-parse --verify --quiet " & name).ok: return name
  ""

proc reviewBranchFile*(rel, base: string) =
  let path = branchRoot / rel
  if not fileExists(path):
    echoLine = rel & " was deleted on this branch"
    return
  visit(path)
  let (output, ok) = git(branchRoot, "show " & quoteShell(base & ":" & rel))
  if not ok:
    echoLine = rel & ": new on this branch (no base version)"
    beginComparison("", "branch base")
    return
  beginComparison(output.replace("\r\n", "\n") & "\n", "branch base")

definePrompt(Prompt(kind: "branch-debt", text: true, candidates: proc(): seq[string] = branchRows,
  onAccept: proc(value: string): bool =
    let i = branchRows.find(value)
    if i >= 0: reviewBranchFile(branchFiles[i].rel, branchFiles[i].base)
    true))
interp.defPrimitive("branch-debt", proc(args: seq[Value]): Value =
  ## The work of this branch still to understand: files changed from the base branch
  ## (merge base with main / master / understanding-base-branch) without a DONE entry
  ## for this branch at the file's current commit, plus uncommitted changes.
  args.arity(0, 0)
  branchRoot = currentRoot()
  if not (dirExists(branchRoot / ".git") or fileExists(branchRoot / ".git")):
    echoLine = "Not in a git repository"
    return nilValue()
  let branch = branchOf(branchRoot)
  let base = baseBranch(branchRoot)
  if base.len == 0:
    echoLine = "No base branch found (setq understanding-base-branch \"name\")"
    return nilValue()
  let changes = branchChanges(branchRoot, branch, base)
  if changes.error.len > 0:
    echoLine = "git: " & changes.error
    return nilValue()
  branchRows = @[]
  branchFiles = @[]
  var skipped = 0
  for f in changes.files:
    if f.understood:
      inc skipped
      continue
    branchRows.add f.rel & "  " & plusMinus(f) & (if f.dirty: "  (uncommitted)" else: "")
    branchFiles.add (f.rel, changes.mergeBase)
  if branchRows.len == 0:
    echoLine = if skipped > 0: "Branch " & branch & ": all " & $skipped & " changed files understood"
               else: "Branch " & branch & ": no changes from " & base
    return nilValue()
  beginMini("branch-debt", "Branch " & branch & " vs " & base & " (" & $branchRows.len & " files to understand" &
    (if skipped > 0: ", " & $skipped & " done" else: "") & "): ")
  nilValue())
interp.defPrimitive("understanding-ledger", proc(args: seq[Value]): Value =
  ## Opens the ledger file itself (Org).
  args.arity(0, 0)
  let path = ledgerPath()
  if path.len == 0: echoLine = "understanding-ledger is nil"
  else: visit(path)
  nilValue())

var glossaryRows: seq[string]
definePrompt(Prompt(kind: "glossary", text: true, candidates: proc(): seq[string] = glossaryRows,
  onAccept: proc(value: string): bool =
    echoLine = value
    true))
interp.defPrimitive("glossary", proc(args: seq[Value]): Value =
  ## The terms explanations collected, `term :: definition`, to look one up.
  args.arity(0, 0)
  let path = glossaryPath()
  if path.len == 0 or not fileExists(path):
    echoLine = "No glossary yet (explanations in reviews fill " & (if path.len > 0: shortPath(path) else: "none") & ")"
    return nilValue()
  glossaryRows = @[]
  for (term, definition) in glossaryTerms(readFile(path)): glossaryRows.add term & " :: " & definition
  if glossaryRows.len == 0:
    echoLine = "The glossary has no terms yet"
    return nilValue()
  beginMini("glossary", "Term: ")
  nilValue())

proc dispatchReview*(c: string)  # forward: the review's keys, also driven from Lisp

for (name, key) in [("review-take", "y"), ("review-keep", "k"), ("review-next", "n"), ("review-previous", "p"),
                    ("review-finish", "q"), ("review-explain-hunk", "x"), ("review-attest", "U")]:
  closureScope:
    let key = key
    interp.defPrimitive(name, proc(args: seq[Value]): Value =
      ## The review's keys as commands, so an init file or an agent can drive a review.
      args.arity(0, 0)
      if mode != "review": echoLine = "No review is open"
      else: dispatchReview(key)
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
  if reviewReadOnly and c in ["y", "k", "a", "A", "w", "r"]:
    echoLine = "A comparison: nothing to take. x explains, X asks, U marks understood, q records"
    return
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
  of "x":
    try: explainCurrentHunk()
    except CatchableError as e: echoLine = e.msg
    return
  of "X":
    if agentProcess != nil: echoLine = "Agent already running"
    else: beginMini("review-ask", "Ask about hunk " & $(currentHunk + 1) & ": ")
    return
  of "U":
    # Attested: the reviewer understands this hunk without an explanation.
    if currentHunk < explained.len:
      explained[currentHunk] = true
      if explanations[currentHunk].len == 0: explanations[currentHunk] = "(understood by the reviewer)"
    echoLine = "Hunk " & $(currentHunk + 1) & " marked understood"
    currentHunk = min(currentHunk + 1, reviewState.hunks.high)
  of "l":
    hunkRows = @[]
    for i in 0..<reviewState.hunks.len: hunkRows.add reviewState.hunkLabel(i)
    beginMini("review-hunks", "Hunk: ")
    return
  of "?":
    echoLine = "y: take the proposed hunk  k: keep the buffer's  u: undo the decision  " &
      "n / p: move  l: list  x: explain this hunk  X: ask a question about it  U: I understand it  " &
      "r: ask the agent to change it  w: apply so far, go on  " &
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
(setq understanding-ledger "~/.darger-understanding.org")
(setq understanding-base-branch nil)
(setq glossary-file "~/.darger-glossary.org")
(global-set-key "C-c c" 'agent-chat)
(setq agent-command "claude -p --output-format text")
(setq agent-chat-command "claude -p --output-format stream-json --verbose --session-id {id}")
(setq agent-chat-resume-command "claude -p --output-format stream-json --verbose --resume {id}")
"""
