## An asynchronous shell job with bounded reads and cancellation of its process group.
import std/[os, tempfiles, monotimes, times]
when defined(windows):
  import std/[osproc, streams, winlean]
  proc createJobObject(a: pointer, name: WideCString): Handle {.stdcall, importc: "CreateJobObjectW", dynlib: "kernel32".}
  proc assignProcessToJobObject(job, process: Handle): WINBOOL {.stdcall, importc: "AssignProcessToJobObject", dynlib: "kernel32".}
  proc terminateJobObject(job: Handle, code: uint32): WINBOOL {.stdcall, importc: "TerminateJobObject", dynlib: "kernel32".}
else:
  import std/posix

type CompileJob* = ref object
  directory: string
  output: File
  started: MonoTime
  finished*, cancelled*: bool
  code*: int
  when defined(windows):
    process: Process
    group: Handle
  else:
    pid: Pid

proc elapsed*(job: CompileJob): float = (getMonoTime() - job.started).inMilliseconds.float / 1000

proc stop*(job: CompileJob) =
  if job == nil or job.finished: return
  when defined(windows):
    if terminateJobObject(job.group, 137) == 0: raiseOSError(osLastError())
  else:
    if posix.kill(-job.pid, SIGKILL) != 0 and osLastError() != OSErrorCode(ESRCH):
      raiseOSError(osLastError())
  job.cancelled = true

proc poll*(job: CompileJob) =
  if job.finished: return
  when defined(windows):
    let code = job.process.peekExitCode()
    if code != -1:
      job.code = code
      job.finished = true
  else:
    var status: cint
    let pid = waitpid(job.pid, status, WNOHANG)
    if pid == job.pid:
      job.code = if WIFEXITED(status): WEXITSTATUS(status) else: 128 + WTERMSIG(status)
      job.finished = true
    elif pid < 0 and osLastError() != OSErrorCode(EINTR): raiseOSError(osLastError())

proc read*(job: CompileJob): string =
  # A regular file cannot fill a pipe and block the compiler. Bound work per UI tick.
  job.output.setFilePos(job.output.getFilePos())  # clear EOF when the file has grown
  result = newString(65536)
  let n = job.output.readBuffer(addr result[0], result.len)
  result.setLen(n)

proc close*(job: CompileJob) =
  if job == nil: return
  if not job.finished:
    job.stop()
    when defined(windows): discard job.process.waitForExit()
    else:
      var status: cint
      while waitpid(job.pid, status, 0) < 0 and osLastError() == OSErrorCode(EINTR): discard
  # A shell can exit while a background child still owns the output file.
  # Retire the whole job before dropping its output or starting a replacement.
  when defined(windows):
    discard terminateJobObject(job.group, 137)
    job.process.close()
    discard closeHandle(job.group)
  else: discard posix.kill(-job.pid, SIGKILL)
  if job.output != nil: job.output.close()
  # Only files created by this job are removed.
  removeFile(job.directory / "output")
  removeDir(job.directory)

proc startCompileJob*(command, root: string): CompileJob =
  result = CompileJob(directory: createTempDir("darger-compile-", ""), started: getMonoTime())
  let output = result.directory / "output"
  writeFile(output, "")
  try:
    when defined(windows):
      result.group = createJobObject(nil, nil)
      if result.group == 0: raiseOSError(osLastError())
      let shell = "set /p dargerCompileReady= >nul & (" & command & ") <NUL >\"" & output & "\" 2>&1"
      result.process = startProcess("cmd", workingDir = root, args = ["/d", "/s", "/c", shell], options = {poUsePath, poDaemon})
      let handle = openProcess(PROCESS_SET_QUOTA or PROCESS_TERMINATE, 0, DWORD(result.process.processID))
      if handle == 0: raiseOSError(osLastError())
      let assigned = assignProcessToJobObject(result.group, handle)
      let error = osLastError()
      discard closeHandle(handle)
      if assigned == 0: raiseOSError(error)
      result.process.inputStream.writeLine("ready")
      result.process.inputStream.flush()
    else:
      var actions: Tposix_spawn_file_actions
      var attributes: Tposix_spawnattr
      template checked(call: untyped) =
        let code = call
        if code != 0: raiseOSError(OSErrorCode(code))
      checked posix_spawn_file_actions_init(actions)
      defer: discard posix_spawn_file_actions_destroy(actions)
      checked posix_spawnattr_init(attributes)
      defer: discard posix_spawnattr_destroy(attributes)
      checked posix_spawnattr_setflags(attributes, POSIX_SPAWN_SETPGROUP)
      checked posix_spawnattr_setpgroup(attributes, 0)
      checked posix_spawn_file_actions_addopen(actions, 0, "/dev/null", O_RDONLY, Mode(0))
      checked posix_spawn_file_actions_addopen(actions, 1, output.cstring, O_WRONLY, Mode(0))
      checked posix_spawn_file_actions_adddup2(actions, 1, 2)
      # A separate shell keeps arbitrary compound commands inside the redirections.
      let shell = "cd " & quoteShell(root) & " && exec /bin/sh -c " & quoteShell(command)
      let args = allocCStringArray(["/bin/sh", "-c", shell])
      defer: deallocCStringArray(args)
      var env: seq[string]
      for key, value in envPairs(): env.add key & "=" & value
      let environment = allocCStringArray(env)
      defer: deallocCStringArray(environment)
      checked posix_spawn(result.pid, "/bin/sh", actions, attributes, args, environment)
    result.output = open(output, fmRead)
  except CatchableError:
    when defined(windows):
      if result.process != nil:
        result.process.kill()
        result.process.close()
      if result.group != 0:
        discard terminateJobObject(result.group, 137)
        discard closeHandle(result.group)
    else:
      if result.pid > 0:
        discard posix.kill(-result.pid, SIGKILL)
        var status: cint
        discard waitpid(result.pid, status, 0)
    removeFile(output)
    removeDir(result.directory)
    raise
