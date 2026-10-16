## M-x shell: a comint-style shell buffer. The shell runs on a pty (src/pty.nim) with
## echo off; its output, with escapes and carriage returns applied (src/termtext.nim),
## fills the top of *shell*, and what you type after it is sent with Enter. C-c C-c
## interrupts, C-d at an empty input sends end-of-file. Slice 1 of the terminal: line
## mode, no colours, no full-screen programs.
when not defined(windows):
  import std/[os, strutils, unicode, tables]
  import ../[core, buffer, buffers, lisp, pty, termtext, syntax, render]

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

  interp.defPrimitive("shell", proc(args: seq[Value]): Value =
    args.arity(0, 0)
    shell()
    nilValue())

  defaults.add """
(setq shell-file-name "")
(global-set-key "C-c s" 'shell)
"""
