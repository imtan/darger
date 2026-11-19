## Bounded non-blocking stdio transport. Protocol stdout and diagnostic stderr stay separate.
import std/[os, osproc]
when not defined(windows): import std/posix
import acp

type AcpProcess* = ref object
  process: Process
  input*, errors*: string
  output: string

proc startAcpProcess*(command, root: string): AcpProcess =
  when defined(windows):
    raise newException(IOError, "ACP stdio currently requires POSIX")
  else:
    result = AcpProcess(process: startProcess("/bin/sh", workingDir = root,
      args = ["-c", "exec " & command], options = {poUsePath, poDaemon}))
    for fd in [result.process.inputHandle, result.process.outputHandle, result.process.errorHandle]:
      if fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK) < 0: raiseOSError(osLastError())

proc send*(p: AcpProcess, text: string) =
  if p.output.len + text.len > maxAcpMessage * 2: raise newException(IOError, "ACP output queue full")
  p.output.add text & "\n"

proc poll*(p: AcpProcess): bool =
  when not defined(windows):
    # The editor's LSP transport blocks SIGPIPE; do so here for standalone use too.
    var signals, previous: Sigset
    discard sigemptyset(signals)
    discard sigaddset(signals, SIGPIPE)
    discard pthread_sigmask(SIG_BLOCK, signals, previous)
    if p.output.len > 0:
      let n = posix.write(p.process.inputHandle, addr p.output[0], min(65536, p.output.len))
      if n > 0: p.output = p.output[n..^1]
      elif n < 0 and errno notin [EAGAIN, EWOULDBLOCK, EINTR]: raiseOSError(osLastError())
    var received = false
    for fd in [p.process.outputHandle, p.process.errorHandle]:
      var chunk = newString(65536)
      let n = posix.read(fd, addr chunk[0], chunk.len)
      if n > 0:
        received = true
        chunk.setLen(n)
        if fd == p.process.outputHandle: p.input.add chunk
        else:
          p.errors.add chunk
          discard trimOutput(p.errors, 65536)
      elif n < 0 and errno notin [EAGAIN, EWOULDBLOCK, EINTR]: raiseOSError(osLastError())
    result = p.process.peekExitCode() == -1 or received

proc close*(p: AcpProcess) =
  if p == nil or p.process == nil: return
  when not defined(windows):
    discard posix.kill(-Pid(p.process.processID), SIGKILL)
  if p.process.peekExitCode() == -1: p.process.kill()
  discard p.process.waitForExit()
  p.process.close()
  p.process = nil
