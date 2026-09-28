import std/[os, tempfiles]

proc streamError(f: File): cint {.importc: "ferror", header: "<stdio.h>".}
when defined(windows):
  proc flushDisk(handle: FileHandle): int32 {.stdcall, importc: "FlushFileBuffers", dynlib: "kernel32".}
  proc setMode(fd, mode: cint): cint {.importc: "_setmode", header: "<io.h>".}
  var binaryMode {.importc: "_O_BINARY", header: "<fcntl.h>".}: cint
else:
  import std/posix

  proc resolveLinks(path: string): string =
    # Follow symlinks so a save replaces the real file, not the link.
    result = path
    var hops = 0
    while symlinkExists(result):
      inc hops
      if hops > 40: raise newException(IOError, "Too many levels of symbolic links: " & path)
      let link = expandSymlink(result)
      # Join against the physical parent: a lexical join would collapse ".." across
      # a symlinked directory and save to a different file than the kernel opens.
      result = if link.isAbsolute: link else: expandFilename(parentDir(result)) / link

proc checkedWrite*(f: File, data: string) =
  if data.len > 0 and f.writeBuffer(unsafeAddr data[0], data.len) != data.len:
    raise newException(IOError, "Short write")

proc atomicWrite*(path, data: string,
                  writer: proc(f: File, data: string) = checkedWrite) =
  var target = absolutePath(path)
  when not defined(windows): target = resolveLinks(target)
  if dirExists(target) or target[^1] in {DirSep, AltSep}:
    raise newException(IOError, "Is a directory: " & target)
  when not defined(windows):
    if fileExists(target) and access(target.cstring, W_OK) != 0:
      raise newException(IOError, "File is write-protected: " & target)
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
        let fd = f.getFileHandle().cint
        var st: Stat
        if stat(target.cstring, st) == 0:
          # chown before chmod: a successful chown clears setuid/setgid; EPERM as non-root is fine.
          # A foreign uid fails the whole call; then keep at least the group (uid -1 = unchanged).
          if fchown(fd, st.st_uid, st.st_gid) != 0: discard fchown(fd, not Uid(0), st.st_gid)
          if fchmod(fd, st.st_mode and Mode(0o7777)) != 0: raiseOSError(osLastError())
        else:
          let m = umask(0)
          discard umask(m)
          if fchmod(fd, Mode(0o666) and not m) != 0: raiseOSError(osLastError())
        if fsync(fd) != 0: raiseOSError(osLastError())
    finally:
      f.close()
    if getFileSize(temp) != data.len:
      raise newException(IOError, "Incomplete temporary file: " & target)
    moveFile(temp, target)
    when not defined(windows):
      # Make the rename durable; it already succeeded, so errors are ignored.
      let dfd = posix.open(parentDir(target).cstring, O_RDONLY)
      if dfd >= 0:
        discard fsync(dfd)
        discard posix.close(dfd)
  except:
    discard tryRemoveFile(temp)
    raise
