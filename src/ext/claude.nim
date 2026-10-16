## Claude Code in a terminal, with the user's Emacs bindings: C-c C c starts it in a
## side window for the project (or focuses it), C-c C t hides / shows that window,
## C-c C n starts a new session, C-c C r sends the region, C-c C f asks about the file.
when not defined(windows):
  import std/[os, strutils, unicode, tables]
  import ../[core, buffer, buffers, lisp, chat]
  import term

  proc claudeRoot(): string =
    ## The project: the nearest directory with .git above the file, else its directory.
    let dir = if core.b.path.len > 0: parentDir(core.b.path) else: getCurrentDir()
    rootFromDir(dir)

  proc claudeName(root: string): string = "*claude-code: " & extractFilename(root) & "*"

  proc paneShowing(buf: Buffer): Pane =
    for p in layout.leaves:
      if (if p == pane: core.b else: p.buf) == buf: return p

  proc showAside(buf: Buffer) =
    ## buf in a side window on the right (split when there is one window), selected.
    let shown = paneShowing(buf)
    if shown != nil:
      selectPane(shown)
      return
    if layout.leaves.len == 1:
      splitPane(false)
      selectPane(layout.next(pane, 1))
    else: selectPane(layout.next(pane, 1))
    switchTo(buf)

  proc claudeTerminal(start: bool): Terminal =
    let root = claudeRoot()
    let name = claudeName(root)
    result = terminalNamed(name)
    if (result == nil or result.pty == nil or result.pty.exited) and start:
      result = startTerminal(name, interp.env.values["claude-command"].asString, root)

  proc claudeCode*() =
    ## C-c C c: Claude Code for this project in the side window.
    let t = claudeTerminal(true)
    if t != nil: showAside(t.buf)

  proc claudeToggle*() =
    ## C-c C t: hide the side window showing Claude Code, or show it.
    let t = claudeTerminal(false)
    let shown = if t != nil: paneShowing(t.buf) else: nil
    if shown == nil:
      claudeCode()
    elif layout.leaves.len == 1:
      let other = reg.other
      if other != nil: switchTo(other)
    else:
      let keep = pane
      selectPane(shown)
      deletePane()
      if keep != shown and keep in layout.leaves: selectPane(keep)

  proc claudeNew*() =
    ## C-c C n: a fresh session: the old terminal goes, a new one starts.
    let t = claudeTerminal(false)
    if t != nil: killBuffer(t.buf)
    claudeCode()

  proc claudeSend(text: string, paste: bool) =
    let origin = core.b
    let t = claudeTerminal(true)
    if t == nil: return
    t.send(text, paste)
    t.send("\r")
    showAside(t.buf)
    echoLine = "Sent to Claude Code"
    discard origin

  proc claudeSendRegion*() =
    ## C-c C r: the region (pasted, so its newlines do not submit) followed by Enter.
    if not core.b.regionActive:
      echoLine = "No region"
      return
    let (a, z) = core.b.region
    if z <= a:
      echoLine = "No region"
      return
    claudeSend($core.b.text.toRunes[a..<z], paste = true)

  proc claudeSendFile*() =
    ## C-c C f: asks about the current file by its path relative to the project.
    if core.b.path.len == 0:
      echoLine = "Buffer has no file"
      return
    let rel = relativePath(core.b.path, claudeRoot())
    claudeSend("このファイルを見てください: " & rel, paste = false)

  interp.defPrimitive("claude-code", proc(args: seq[Value]): Value =
    args.arity(0, 0)
    claudeCode()
    nilValue())
  interp.defPrimitive("claude-code-toggle", proc(args: seq[Value]): Value =
    args.arity(0, 0)
    claudeToggle()
    nilValue())
  interp.defPrimitive("claude-code-new", proc(args: seq[Value]): Value =
    args.arity(0, 0)
    claudeNew()
    nilValue())
  interp.defPrimitive("claude-code-send-region", proc(args: seq[Value]): Value =
    args.arity(0, 0)
    claudeSendRegion()
    nilValue())
  interp.defPrimitive("claude-code-send-file", proc(args: seq[Value]): Value =
    args.arity(0, 0)
    claudeSendFile()
    nilValue())

  defaults.add """
(setq claude-command "claude")
(global-set-key "C-c C c" 'claude-code)
(global-set-key "C-c C t" 'claude-code-toggle)
(global-set-key "C-c C n" 'claude-code-new)
(global-set-key "C-c C r" 'claude-code-send-region)
(global-set-key "C-c C f" 'claude-code-send-file)
"""
