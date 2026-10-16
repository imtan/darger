## M-x shell: a comint-style shell buffer. The shell runs on a pty (src/pty.nim) with
## echo off; its output, with escapes and carriage returns applied (src/termtext.nim),
## fills the top of *shell*, and what you type after it is sent with Enter. C-c C-c
## interrupts, C-d at an empty input sends end-of-file. Slice 1 of the terminal: line
## mode, no colours, no full-screen programs.
when not defined(windows):
  import std/[os, strutils, unicode, tables, sequtils]
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

  # ---- M-x term: the screen model in a buffer, every key sent raw (char mode)
  type Terminal* = ref object
    buf*: Buffer
    pty*: Pty
    screen*: Screen
    size: tuple[cols, rows: int]
    lineMode*: bool    ## C-c C-j: the buffer is edited as text and Enter sends the input
    shown: string      ## the text the screen last put in the buffer (line mode keeps typing after it)

  var terminals*: seq[Terminal]

  proc terminalOf*(buf: Buffer): Terminal =
    for t in terminals:
      if t.buf == buf: return t

  proc terminalNamed*(name: string): Terminal = terminalOf(reg.byName(name))

  proc paneSizeOf(t: Terminal): tuple[cols, rows: int] =
    for p in layout.leaves:
      if (p == pane and core.b == t.buf) or (p != pane and p.buf == t.buf):
        return (max(20, p.w), max(5, p.h - 1))
    t.size

  proc showScreen(t: Terminal) =
    ## The buffer = scrollback above the screen; the buffer cursor is the terminal's. In
    ## line mode the input typed after the screen's text survives new output, after it.
    let back = t.screen.scrollbackLines
    # Line mode shows the screen only down to its cursor row (trailing padding dropped),
    # so the input is typed right after the prompt, as in Emacs' term line mode.
    var rows = t.screen.lines
    if t.lineMode and t.screen.row < rows.len:
      rows.setLen(t.screen.row + 1)
      rows[^1] = rows[^1].strip(leading = false)
    let text = (back & rows).join("\n")
    let pending = if t.lineMode: inputAfter(t.shown, t.buf.text) else: ""
    t.buf.splice(0, t.buf.text.runeLen, text & pending)
    t.shown = text
    if pending.len > 0:
      t.buf.cursor = (t.buf.lines.high, t.buf.lines[^1].len)
    else:
      let line = min(back.len + t.screen.row, t.buf.lines.high)
      t.buf.cursor = (line, min(t.screen.runeIndex(t.screen.row, t.screen.col), t.buf.lines[line].len))
    t.buf.modified = false
    if core.b == t.buf: renderer.top = max(renderer.top, back.len - max(0, renderer.rows - t.screen.rows))

  proc setLineMode(t: Terminal, on: bool) =
    ## Line mode (C-c C-j): the buffer is ordinary text, SKK and every editing key
    ## work, Enter sends what was typed after the screen's text; char mode (C-c C-k)
    ## gives the keys back to the program and drops any unsent input.
    t.lineMode = on
    t.showScreen()
    echoLine = if on: "Line mode: edit, Enter sends the line (C-c C-k for char mode)"
               else: "Char mode: keys go to the program (C-c C-j for line mode)"

  proc startTerminal*(name, command, dir: string): Terminal =
    ## A terminal buffer called `name` running `command` in `dir` (an existing live one is reused).
    result = terminalNamed(name)
    if result != nil and result.pty != nil and not result.pty.exited: return
    if result == nil:
      result = Terminal(buf: reg.byName(name))
      if result.buf == nil:
        result.buf = newBuffer()
        reg.add(result.buf, name)
      terminals.add result
    if result.pty != nil: result.pty.close()
    if renderer.frameCols == 0:
      renderer.resize(window, core.b)
      layoutPanes()
    result.size = (max(20, renderer.cols), max(5, renderer.rows))
    result.screen = initScreen(result.size.cols, result.size.rows)
    result.buf.splice(0, result.buf.text.runeLen, "")
    try:
      result.pty = spawn(command, dir, result.size.cols, result.size.rows,
        [("TERM", "xterm-256color"), ("COLORTERM", ""), ("INSIDE_DARGER", "1")])
    except OSError as e:
      result.pty = nil
      echoLine = e.msg
    result.showScreen()

  proc openTerm*(command = "") =
    ## M-x term: *terminal* running the shell, or `command`, in the current file's directory.
    let dir = if core.b.path.len > 0: parentDir(core.b.path) else: getCurrentDir()
    let t = startTerminal("*terminal*", if command.len > 0: command else: shellCommand(), dir)
    switchTo(t.buf)

  proc send*(t: Terminal, text: string, paste = false) =
    ## Text to the program; `paste` wraps it in bracketed-paste marks so newlines do not submit.
    if t == nil or t.pty == nil or t.pty.exited: return
    if paste: t.pty.write("\x1b[200~" & text & "\x1b[201~")
    else: t.pty.write(text)

  tickHooks.add proc(): bool =
    for t in terminals:
      if t.pty == nil: continue
      let size = t.paneSizeOf
      if size != t.size:
        t.size = size
        t.screen.resize(size.cols, size.rows)
        t.pty.resize(size.cols, size.rows)
        t.showScreen()
        result = true
      let data = t.pty.read()
      if data.len > 0:
        t.screen.feed(data)
        t.showScreen()
        result = true
      if t.pty.exited:
        t.screen.feed("\r\n[Process finished" & (if t.pty.status != 0: " (exit " & $t.pty.status & ")" else: "") & "]\r\n")
        t.showScreen()
        t.pty.close()
        t.pty = nil
        result = true

  proc liveTerminal(): Terminal =
    ## The current buffer's terminal with a live program, outside prompts, in either mode.
    if mode.len > 0: return nil
    result = terminalOf(core.b)
    if result != nil and (result.pty == nil or result.pty.exited): result = nil

  proc activeTerminal(): Terminal =
    ## The terminal taking the keys: a live one in char mode.
    result = liveTerminal()
    if result != nil and result.lineMode: result = nil

  proc sendInput(t: Terminal) =
    ## Line mode's Enter (term-send-input): the input typed after the screen's text
    ## goes to the program with a newline; the program echoes it.
    let input = inputAfter(t.shown, t.buf.text)
    t.buf.splice(t.shown.runeLen, t.buf.text.runeLen, "")
    t.pty.write(input & "\r")

  keyFilters.add proc(c: string): bool =
    # Both modes: C-c C-j / C-c C-k switch, as term-mode-map has them. Line mode: Enter sends.
    let t = liveTerminal()
    if t == nil: return false
    if prefix == "C-c" and c in ["C-j", "C-k"]:
      prefix = ""
      t.setLineMode(c == "C-j")
      return true
    if t.lineMode and prefix.len == 0 and c in ["enter", "C-m"]:
      t.sendInput()
      return true
    false

  runeFilters.add proc(r: Rune): bool =
    let t = activeTerminal()
    if t == nil or prefix.len > 0: return false
    t.pty.write($r)
    true
  keyFilters.add proc(c: string): bool =
    # Char mode: every key goes to the program but the C-x and C-c prefixes (and M-x,
    # M-:), which stay the editor's; C-c C-c sends a C-c, as in Emacs term.
    let t = activeTerminal()
    if t == nil: return false
    if prefix == "C-c" and c == "C-c":
      prefix = ""
      t.pty.write("\x03")
      return true
    if prefix.len > 0 or c in ["C-x", "C-c", "M-x", "M-:", "C-g"]: return false
    let bytes = keySequence(c, shift())
    if bytes.len == 0: return false
    t.pty.write(bytes)
    true
  escapeHooks.add proc(): bool = activeTerminal() != nil  # Escape reaches the program

  proc screenRows(buf: Buffer, values: seq[seq[int8]]): seq[seq[int8]] =
    ## Per-rune values of the screen laid under the buffer's lines (the scrollback has none).
    let t = terminalOf(buf)
    if t == nil or buf.lines.len == 0: return
    let back = t.screen.scrollbackLines.len
    for n, line in buf.lines:
      var row = newSeq[int8](line.len)
      if n >= back and n - back < values.len:
        for i in 0..<min(line.len, values[n - back].len): row[i] = values[n - back][i]
      result.add row

  faceProviders.add proc(buf: Buffer): seq[seq[Face]] =
    let t = terminalOf(buf)
    if t == nil: return
    for row in screenRows(buf, t.screen.colors):
      var faces = newSeq[Face](row.len)
      for i, c in row:
        if c > 0: faces[i] = Face(ord(fAnsi0) + c - 1)
      result.add faces
  backProviders.add proc(buf: Buffer): seq[seq[int8]] =
    let t = terminalOf(buf)
    if t != nil: result = screenRows(buf, t.screen.backgrounds)
  markProviders.add proc(buf: Buffer): seq[seq[int8]] =
    let t = terminalOf(buf)
    if t != nil: result = screenRows(buf, t.screen.underlines)

  killHooks.add proc(buf: Buffer) =
    let t = terminalOf(buf)
    if t != nil:
      if t.pty != nil: t.pty.close()
      terminals.delete(terminals.find(t))
  exitHooks.add proc() =
    for t in terminals:
      if t.pty != nil: t.pty.close()
  modifiedIgnore.add proc(buf: Buffer): bool = terminalOf(buf) != nil
  block:
    let previous = modeLineHook
    modeLineHook = proc(): string =
      result = if previous != nil: previous() else: ""
      let t = terminalOf(core.b)
      if t != nil: result.add(if t.lineMode: " [Line]" else: " [Char]")
  noGutter.add proc(buf: Buffer): bool = terminalOf(buf) != nil  # the program owns every column

  mouseFilters.add proc(p: Pane, cx, cy, button: int, pressed: bool): bool =
    ## A program that asked for mouse reports gets clicks and wheel notches on its screen
    ## cells; on the alternate screen without reports the wheel becomes arrow keys.
    let buf = if p == pane: core.b else: p.buf
    let t = terminalOf(buf)
    if t == nil or t.pty == nil or t.pty.exited or t.lineMode: return false
    let top = if p == pane: renderer.top else: p.top
    let row = top + (cy - p.y) - t.screen.scrollbackLines.len
    let col = cx - p.x
    if cy - p.y >= p.h - 1 or row notin 0..<t.screen.rows or col notin 0..<t.screen.cols: return false
    if t.screen.mouse != 0:
      if pressed or t.screen.mouse >= 1000:
        t.pty.write(t.screen.mouseReport(button, col, row, release = not pressed))
      return true
    if t.screen.alt and button in [64, 65] and pressed:
      t.pty.write(if button == 64: "\x1b[A" else: "\x1b[B")
      return true
    false

  interp.defPrimitive("term", proc(args: seq[Value]): Value =
    ## (term) runs the shell, (term "command args") that program, in *terminal*.
    args.arity(0, 1)
    openTerm(if args.len == 1: args[0].asString else: "")
    nilValue())

  interp.defPrimitive("term-send-input", proc(args: seq[Value]): Value =
    args.arity(0, 0)
    let t = liveTerminal()
    if t == nil: echoLine = "Not a running terminal buffer"
    else: t.sendInput()
    nilValue())
  proc switchMode(on: bool) =
    let t = terminalOf(core.b)
    if t == nil: echoLine = "Not a terminal buffer"
    else: t.setLineMode(on)
  interp.defPrimitive("term-line-mode", proc(args: seq[Value]): Value =
    args.arity(0, 0)
    switchMode(true)
    nilValue())
  interp.defPrimitive("term-char-mode", proc(args: seq[Value]): Value =
    args.arity(0, 0)
    switchMode(false)
    nilValue())

  interp.defPrimitive("shell", proc(args: seq[Value]): Value =
    args.arity(0, 0)
    shell()
    nilValue())

  defaults.add """
(setq shell-file-name "")
(global-set-key "C-c s" 'shell)
"""
