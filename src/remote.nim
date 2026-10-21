## Remote path syntax and shell commands; no network or filesystem I/O.
import std/[options, strutils, os]
export options

type
  RemotePath* = object
    host*, path*: string
  RemoteEntry* = tuple[name: string, isDir: bool, size: int64, time: string]

proc parseRemote*(p: string): Option[RemotePath] =
  if not p.startsWith("/ssh:"): return none(RemotePath)
  let colon = p.find(':', 5)
  if colon <= 5: return none(RemotePath)
  let host = p[5..<colon]
  let path = p[colon+1..^1]
  if host[0] == '-' or not (path.startsWith("/") or path.startsWith("~/")): return none(RemotePath)
  for c in host:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '-', '_', '@'}: return none(RemotePath)
  if '\0' in path: return none(RemotePath)
  some(RemotePath(host: host, path: path))

proc isRemote*(p: string): bool = parseRemote(p).isSome
proc remoteString*(host, path: string): string = "/ssh:" & host & ":" & path
proc remoteParent*(p: string): string =
  let r = parseRemote(p).get
  var path = r.path
  while path.len > 1 and path.endsWith('/') and path != "~/": path.setLen(path.len - 1)
  let cut = path.rfind('/')
  remoteString(r.host, path[0..cut])
proc remoteJoin*(dir, name: string): string =
  let r = parseRemote(dir).get
  remoteString(r.host, r.path & (if r.path.endsWith('/'): "" else: "/") & name)

proc sshArgs*(host, remoteCommand: string): seq[string] =
  @["ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=auto", "-o", "ControlPersist=120",
    "-o", "ControlPath=~/.ssh/darger-%C", "-o", "ConnectTimeout=8", host, remoteCommand]

proc shellPath(path: string): string =
  if path.startsWith("~/"): "\"$HOME\"/" & quoteShell(path[2..^1])
  else: quoteShell(path)
proc catCommand*(path: string): string = "cat " & shellPath(path)
proc writeCommand*(path: string): string =
  # $$ is expanded on the remote host, making the sibling temporary unique per shell.
  let p = shellPath(path)
  "p=" & p & "; t=\"$p.darger-$$\"; (umask 077; set -C; : > \"$t\") && " &
    "{ trap 'rm -f \"$t\"' 0; if [ -e \"$p\" ]; then cp -p \"$p\" \"$t\" || exit; fi; " &
    "cat > \"$t\" && mv -f \"$t\" \"$p\"; }"
proc listCommand*(path: string): string = "LC_ALL=C ls -lA " & shellPath(path)
proc statCommand*(path: string): string =
  let p = shellPath(path)
  "[ -d " & p & " ] && echo dir || ([ -e " & p & " ] && echo file || echo none)"

proc parseLsLines*(output: string): seq[RemoteEntry] =
  for line in output.splitLines:
    if line.len == 0 or line[0] notin {'-', 'd', 'l'}: continue
    var fields: seq[string]
    var pos = 0
    for i in 0..<8:
      while pos < line.len and line[pos] in {' ', '\t'}: inc pos
      let start = pos
      while pos < line.len and line[pos] notin {' ', '\t'}: inc pos
      fields.add line[start..<pos]
    while pos < line.len and line[pos] in {' ', '\t'}: inc pos
    if pos >= line.len: continue
    var name = line[pos..^1]
    if line[0] == 'l':
      let arrow = name.rfind(" -> ")
      if arrow >= 0: name.setLen(arrow)
    if name in [".", ".."]: continue
    try:
      result.add (name, line[0] == 'd', parseBiggestInt(fields[4]), fields[5..7].join(" "))
    except ValueError: discard
