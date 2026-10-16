## A child process on a pseudo-terminal (POSIX): spawn with the pty's echo off, read what
## is available without blocking, write, notice the exit. Windows has no pty here.
when not defined(windows):
  import std/[posix, os, strutils, termios]

  type Pty* = ref object
    fd*: cint
    pid*: Pid
    exited*: bool
    status*: int   ## the exit code once exited

  when defined(macosx):
    proc forkpty(amaster: ptr cint, name: cstring, termp: pointer, winp: pointer): Pid
      {.importc, header: "<util.h>".}
    const TIOCSWINSZ = 0x80087467'u
  else:
    {.passL: "-lutil".}
    proc forkpty(amaster: ptr cint, name: cstring, termp: pointer, winp: pointer): Pid
      {.importc, header: "<pty.h>".}
    const TIOCSWINSZ = 0x5414'u
  type WinSize {.importc: "struct winsize", header: "<sys/ioctl.h>".} = object
    ws_row, ws_col, ws_xpixel, ws_ypixel: cushort
  proc ioctl(fd: cint, request: culong, arg: pointer): cint {.importc, header: "<sys/ioctl.h>", varargs.}

  proc spawn*(command: string, dir: string, cols, rows: int, env: openArray[(string, string)]): Pty =
    ## Runs `command` (split on spaces) on a new pty in `dir` with the extra environment.
    var master: cint
    let pid = forkpty(addr master, nil, nil, nil)
    if pid < 0: raise newException(OSError, "forkpty failed: " & $strerror(errno))
    if pid == 0:
      # The child: no echo (the editor shows what was typed), the window size, then exec.
      var t: Termios
      if tcGetAttr(0, addr t) == 0:
        t.c_lflag = t.c_lflag and not Cflag(ECHO)
        discard tcSetAttr(0, TCSANOW, addr t)
      var ws = WinSize(ws_row: rows.cushort, ws_col: cols.cushort)
      discard ioctl(0, TIOCSWINSZ.culong, addr ws)
      if dir.len > 0: discard chdir(dir.cstring)
      for (k, v) in env: putEnv(k, v)
      let args = allocCStringArray(command.splitWhitespace)
      discard execvp(args[0], args)
      stderr.writeLine "cannot run " & command & ": " & $strerror(errno)
      quit(127)
    discard fcntl(master, F_SETFL, fcntl(master, F_GETFL) or O_NONBLOCK)
    Pty(fd: master, pid: pid)

  proc checkExit(p: Pty) =
    if p.exited: return
    var status: cint
    if waitpid(p.pid, status, WNOHANG) == p.pid:
      p.exited = true
      p.status = if WIFEXITED(status): WEXITSTATUS(status) else: 128 + WTERMSIG(status)

  proc read*(p: Pty): string =
    ## Everything the process has written since the last call; "" when nothing (or exited).
    if p.fd < 0: return
    var buf: array[16384, char]
    while true:
      let n = posix.read(p.fd, addr buf[0], buf.len)
      if n > 0:
        result.add buf.toOpenArray(0, n - 1).join("")
        if n < buf.len: break
      else:
        if n < 0 and errno == EAGAIN: break
        # EOF, or EIO once the child is gone (Linux)
        p.checkExit()
        if n == 0 or p.exited or errno == EIO:
          if not p.exited: p.checkExit()
          break
        break
    p.checkExit()

  proc write*(p: Pty, s: string) =
    if p.fd < 0 or p.exited: return
    var off = 0
    while off < s.len:
      let n = posix.write(p.fd, unsafeAddr s[off], s.len - off)
      if n <= 0: break
      off += n

  proc resize*(p: Pty, cols, rows: int) =
    if p.fd < 0: return
    var ws = WinSize(ws_row: rows.cushort, ws_col: cols.cushort)
    discard ioctl(p.fd, TIOCSWINSZ.culong, addr ws)

  proc close*(p: Pty) =
    ## Hangs the process up (SIGHUP, as a closed terminal does) and closes the pty.
    if p.fd >= 0:
      if not p.exited: discard kill(p.pid, SIGHUP)
      discard posix.close(p.fd)
      p.fd = -1
