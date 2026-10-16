## M-x shell: a comint-style shell buffer. The shell runs on a pty (src/pty.nim) with
## echo off; its output, with escapes and carriage returns applied (src/termtext.nim),
## fills the top of *shell*, and what you type after it is sent with Enter. C-c C-c
## interrupts, C-d at an empty input sends end-of-file. Slice 1 of the terminal: line
## mode, no colours, no full-screen programs.
when not defined(windows):
  import std/[os, strutils, unicode, tables]
  import ../[core, buffer, buffers, lisp, pty, termtext, termscreen, syntax, render]

  var
    shellBuf: Buffer
    proc1: Pty
    term: TermText
    outputLen: int   # runes of process output at the top of the buffer; input follows
    sentSize: tuple[cols, rows: int]  # the window size the process has

  proc shellCommand(): string =
    let configured = interp.env.values["shell-file-name"].asString
    if configured.len > 0: configured elif getEnv("SHELL").len > 0: getEnv("SHELL") else: "/bin/sh"

  proc showOutput() =
    ## The buffer's output part follows the process; the input being typed stays after it.
    if shellBuf == nil: return
    let text = term.text
    let newLen = text.runeLen
    let point = shellBuf.offset(shellBuf.cursor)
    let follow = point >= outputLen  # at or after the input start: ride along with the output
    shellBuf.splice(0, min(outputLen, shellBuf.text.runeLen), text)  # no undo snapshot for live output
    shellBuf.cursor = shellBuf.point(if follow: point + newLen - outputLen else: point)
    outputLen = newLen
    shellBuf.modified = false

  proc startShell(dir: string) =
    if renderer.frameCols == 0:  # from ~/.darger.el, before the first frame: size the panes now
      renderer.resize(window, core.b)
      layoutPanes()
    term = TermText()
    outputLen = 0
    shellBuf.splice(0, shellBuf.text.runeLen, "")
    try:
      sentSize = (max(20, renderer.cols), max(5, renderer.rows))
      proc1 = spawn(shellCommand(), dir, sentSize.cols, sentSize.rows,
        [("TERM", "dumb"), ("INSIDE_DARGER", "1"), ("PAGER", "cat")])
    except OSError as e:
      proc1 = nil
      echoLine = e.msg

  proc shell*() =
    ## Shows *shell*, starting the shell when none runs (in the current file's directory).
    let dir = if core.b.path.len > 0: parentDir(core.b.path) else: getCurrentDir()
    if shellBuf == nil or shellBuf notin reg:
      shellBuf = newBuffer()
      reg.add(shellBuf, "*shell*")
    switchTo(shellBuf)
    if proc1 == nil or proc1.exited:
      if proc1 != nil: proc1.close()
      startShell(dir)
    shellBuf.cursor = shellBuf.point(shellBuf.text.runeLen)

  proc paneSize(): tuple[cols, rows: int] =
    ## The pane showing *shell* (the selected one when it does), else the last size.
    for p in layout.leaves:
      if (p == pane and core.b == shellBuf) or (p != pane and p.buf == shellBuf):
        return (max(20, p.w), max(5, p.h - 1))
    sentSize

  tickHooks.add proc(): bool =
    if proc1 == nil: return false
    let size = paneSize()
    if size != sentSize:  # the pane was split, resized or zoomed: the process learns its new size
      sentSize = size
      proc1.resize(size.cols, size.rows)
    let data = proc1.read()
    if data.len > 0:
      term.feed(data)
      term.trim(400_000)
      showOutput()
      result = true
    if proc1.exited:
      term.feed("\nProcess shell finished" & (if proc1.status != 0: " (exit " & $proc1.status & ")" else: "") & "\n")
      showOutput()
      proc1.close()
      proc1 = nil
      result = true

  keyFilters.add proc(c: string): bool =
    if mode.len > 0 or shellBuf == nil or core.b != shellBuf or proc1 == nil: return false
    let input = $core.b.text.toRunes[min(outputLen, core.b.text.runeLen)..^1]
    if prefix.len == 0 and c in ["enter", "C-m"]:
      proc1.write(input & "\n")
      # The pty does not echo: the input line stays as typed and the output follows it.
      let endOffset = core.b.text.runeLen
      core.b.splice(endOffset, endOffset, "\n")
      outputLen = core.b.text.runeLen
      term.feed(input & "\n")  # the output text keeps the command line, as comint does
      core.b.cursor = core.b.point(outputLen)
      core.b.modified = false
      return true
    if prefix.len == 0 and c == "C-d" and input.len == 0:
      proc1.write("\x04")
      return true
    if prefix == "C-c" and c == "C-c":
      prefix = ""
      proc1.write("\x03")
      return true
    false

  faceProviders.add proc(buf: Buffer): seq[seq[Face]] =
    ## The process output keeps its SGR colours; the command being typed is plain.
    if buf != shellBuf or buf.lines.len == 0: return
    let colors = term.faces
    for n, line in buf.lines:
      var row = newSeq[Face](line.len)
      if n < colors.len:
        for i in 0..<min(line.len, colors[n].len):
          if colors[n][i] > 0: row[i] = Face(ord(fAnsi0) + colors[n][i] - 1)
      result.add row

  killHooks.add proc(buf: Buffer) =
    if buf == shellBuf:
      if proc1 != nil: proc1.close()
      proc1 = nil
      shellBuf = nil
  exitHooks.add proc() =
    if proc1 != nil: proc1.close()
  modifiedIgnore.add proc(buf: Buffer): bool = buf == shellBuf

  # ---- M-x term: the screen model shown in *terminal*, every key sent raw (char mode)
  var
    termBuf: Buffer
    procT: Pty
    screen: Screen
    termSize: tuple[cols, rows: int]

  proc termPaneSize(): tuple[cols, rows: int] =
    for p in layout.leaves:
      if (p == pane and core.b == termBuf) or (p != pane and p.buf == termBuf):
        return (max(20, p.w), max(5, p.h - 1))
    termSize

  proc showScreen() =
    ## *terminal* = scrollback above the screen; the buffer cursor is the terminal's.
    if termBuf == nil: return
    let back = screen.scrollbackLines
    let text = (back & screen.lines).join("\n")
    termBuf.splice(0, termBuf.text.runeLen, text)
    let line = min(back.len + screen.row, termBuf.lines.high)
    termBuf.cursor = (line, min(screen.col, termBuf.lines[line].len))
    termBuf.modified = false
    if core.b == termBuf: renderer.top = max(renderer.top, back.len - max(0, renderer.rows - screen.rows))

  proc openTerm*(command = "") =
    ## Shows *terminal*, starting `command` (default: the shell) on a pty when none runs.
    let dir = if core.b.path.len > 0: parentDir(core.b.path) else: getCurrentDir()
    if termBuf == nil or termBuf notin reg:
      termBuf = newBuffer()
      reg.add(termBuf, "*terminal*")
    switchTo(termBuf)
    if procT == nil or procT.exited:
      if procT != nil: procT.close()
      if renderer.frameCols == 0:
        renderer.resize(window, core.b)
        layoutPanes()
      termSize = (max(20, renderer.cols), max(5, renderer.rows))
      screen = initScreen(termSize.cols, termSize.rows)
      termBuf.splice(0, termBuf.text.runeLen, "")
      try:
        procT = spawn(if command.len > 0: command else: shellCommand(), dir, termSize.cols, termSize.rows,
          [("TERM", "xterm-256color"), ("COLORTERM", ""), ("INSIDE_DARGER", "1")])
      except OSError as e:
        procT = nil
        echoLine = e.msg
      showScreen()

  tickHooks.add proc(): bool =
    if procT == nil: return false
    let size = termPaneSize()
    if size != termSize:
      termSize = size
      screen.resize(size.cols, size.rows)
      procT.resize(size.cols, size.rows)
      showScreen()
      result = true
    let data = procT.read()
    if data.len > 0:
      screen.feed(data)
      showScreen()
      result = true
    if procT.exited:
      screen.feed("\r\n[Process term finished" & (if procT.status != 0: " (exit " & $procT.status & ")" else: "") & "]\r\n")
      showScreen()
      procT.close()
      procT = nil
      result = true

  proc termActive(): bool = termBuf != nil and core.b == termBuf and procT != nil and mode.len == 0

  runeFilters.add proc(r: Rune): bool =
    if not termActive() or prefix.len > 0: return false
    procT.write($r)
    true
  keyFilters.add proc(c: string): bool =
    # Char mode: every key goes to the program but the C-x and C-c prefixes (and M-x,
    # M-:), which stay the editor's; C-c C-c sends a C-c, as in Emacs term.
    if not termActive(): return false
    if prefix == "C-c" and c == "C-c":
      prefix = ""
      procT.write("\x03")
      return true
    if prefix.len > 0 or c in ["C-x", "C-c", "M-x", "M-:", "C-g"]: return false
    let bytes = keySequence(c, shift())
    if bytes.len == 0: return false
    procT.write(bytes)
    true
  escapeHooks.add proc(): bool = termActive()  # Escape reaches the program

  faceProviders.add proc(buf: Buffer): seq[seq[Face]] =
    if buf != termBuf or buf.lines.len == 0: return
    let back = screen.scrollbackLines.len
    let colors = screen.colors
    for n, line in buf.lines:
      var row = newSeq[Face](line.len)
      if n >= back and n - back < colors.len:
        for i in 0..<min(line.len, colors[n - back].len):
          if colors[n - back][i] > 0: row[i] = Face(ord(fAnsi0) + colors[n - back][i] - 1)
      result.add row

  killHooks.add proc(buf: Buffer) =
    if buf == termBuf:
      if procT != nil: procT.close()
      procT = nil
      termBuf = nil
  exitHooks.add proc() =
    if procT != nil: procT.close()
  modifiedIgnore.add proc(buf: Buffer): bool = buf == termBuf

  interp.defPrimitive("term", proc(args: seq[Value]): Value =
    ## (term) runs the shell, (term "command args") that program, in *terminal*.
    args.arity(0, 1)
    openTerm(if args.len == 1: args[0].asString else: "")
    nilValue())

  interp.defPrimitive("shell", proc(args: seq[Value]): Value =
    args.arity(0, 0)
    shell()
    nilValue())

  defaults.add """
(setq shell-file-name "")
(global-set-key "C-c s" 'shell)
"""
