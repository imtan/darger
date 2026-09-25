import std/[os, tempfiles]

proc streamError(f: File): cint {.importc: "ferror", header: "<stdio.h>".}
when defined(windows):
  proc flushDisk(handle: FileHandle): int32 {.stdcall, importc: "FlushFileBuffers", dynlib: "kernel32".}
  proc setMode(fd, mode: cint): cint {.importc: "_setmode", header: "<io.h>".}
  var binaryMode {.importc: "_O_BINARY", header: "<fcntl.h>".}: cint
else:
  import std/posix

proc checkedWrite*(f: File, data: string) =
  if data.len > 0 and f.writeBuffer(unsafeAddr data[0], data.len) != data.len:
    raise newException(IOError, "Short write")

proc atomicWrite*(path, data: string,
                  writer: proc(f: File, data: string) = checkedWrite) =
  let target = absolutePath(path)
  if dirExists(target) or target[^1] in {DirSep, AltSep}:
    raise newException(IOError, "Is a directory: " & target)
  let (f, temp) = createTempFile(".darger-", ".tmp", parentDir(target))
  try:
    try:
      when defined(windows):
        if setMode(f.getFileHandle().cint, binaryMode) == -1:
          raise newException(IOError, "Cannot set binary file mode")
      writer(f, data)
      f.flushFile()
      if streamError(f) != 0 or f.getFileSize() != data.len:
        raise newException(IOError, "Incomplete write: " & target)
      when defined(windows):
        if flushDisk(f.getOsFileHandle()) == 0: raiseOSError(osLastError())
      else:
        if fsync(f.getFileHandle()) != 0: raiseOSError(osLastError())
    finally:
      f.close()
    if getFileSize(temp) != data.len:
      raise newException(IOError, "Incomplete temporary file: " & target)
    moveFile(temp, target)
  except:
    discard tryRemoveFile(temp)
    raise
