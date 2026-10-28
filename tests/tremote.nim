import std/[strutils, os]
import ../src/[remote, buffer, complete, chat, project, vcline, buffers]

doAssert parseRemote("/ssh:user@host:/a b").get == RemotePath(host: "user@host", path: "/a b")
doAssert parseRemote("/ssh:h:~/x").get.path == "~/x"
for path in ["/a", "/ssh::/x", "/ssh:h:x", "/ssh:-o:/x", "/ssh:h;evil:/x"]:
  doAssert not isRemote(path)
doAssert remoteParent("/ssh:h:/a/b") == "/ssh:h:/a/"
doAssert remoteParent("/ssh:h:/a/") == "/ssh:h:/"
doAssert remoteParent("/ssh:h:/") == "/ssh:h:/"
doAssert remoteParent("/ssh:h:~/x") == "/ssh:h:~/"
doAssert remoteJoin("/ssh:h:/a/", "b c") == "/ssh:h:/a/b c"
doAssert remoteJoin("/ssh:h:~/a", "b") == "/ssh:h:~/a/b"
let command = catCommand("/a b/'$(x)")
doAssert command == "cat " & quoteShell("/a b/'$(x)")
doAssert sshArgs("u@h", command) == @["ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=auto", "-o", "ControlPersist=120", "-o", "ControlPath=~/.ssh/darger-%C", "-o", "ConnectTimeout=8", "u@h", command]
doAssert catCommand("~/a b") == "cat \"$HOME\"/" & quoteShell("a b")
doAssert quoteShell("/a b") in writeCommand("/a b")
doAssert quoteShell("/a b") in statCommand("/a b")
doAssert mkdirCommand("~/a b") == "mkdir -p \"$HOME\"/" & quoteShell("a b")
doAssert listCommand("/a b") == "LC_ALL=C ls -lA " & quoteShell("/a b")
let entries = parseLsLines("""total 16
-rw-r--r-- 1 user group 123 Oct 21 12:34 file with spaces.txt
drwxr-xr-x@ 3 user staff 96 Oct 20 2025 a dir
lrwxr-xr-x 1 root root 8 Jan 1 09:00 my link -> some target
-rw-r--r--+ 1 user staff 42 May  2 2024 bsd file
""")
doAssert entries.len == 4
doAssert entries[0] == ("file with spaces.txt", false, 123'i64, "Oct 21 12:34")
doAssert entries[1] == ("a dir", true, 96'i64, "Oct 20 2025")
doAssert entries[2].name == "my link"
doAssert entries[3].name == "bsd file"
doAssert parseLsLines("garbage\n-rw bad").len == 0
for raw in ["", "no final newline", "line\r\n", "\xEF\xBB\xBFbom"]:
  doAssert bufferFromBytes(raw, "/ssh:h:/file").fileBytes == raw
try:
  discard bufferFromBytes("\xFF", "/ssh:h:/file")
  doAssert false
except ValueError: discard
let path = "/ssh:h:~/test"
remoteLoad = proc(path: string): Buffer = bufferFromBytes("\xEF\xBB\xBFhello\r\n", path)
let b = loadBuffer(path)
var reg: Registry
reg.add b
doAssert reg.byPath(path) == b
doAssert reg.byPath("/ssh:other:~/test") == nil
doAssert b.path == path and b.bom and b.crlf and b.text == "hello\n"
b.insert("x")
remoteSave = proc(buf: Buffer, path: string): bool =
  doAssert buf.fileBytes == "\xEF\xBB\xBFxhello\r\n"
  true
b.save()
doAssert not b.modified
b.insert("y")
remoteSave = proc(buf: Buffer, path: string): bool = false
try:
  b.save()
  doAssert false
except IOError: discard
doAssert b.modified
b.revert()
doAssert b.text == "hello\n" and not b.modified
remoteList = proc(dir: string): seq[string] = @["b", ".hidden", "a/"]
doAssert listDir("/ssh:h:/") == @["a/", "b"]
doAssert listDir("/ssh:h:/", true) == @[".hidden", "a/", "b"]
doAssert splitInput("/ssh:h:~/a/b") == ("/ssh:h:~/a/", "b")
doAssert rootFromDir(path) == path
doAssert projectFiles(path).len == 0
var cache: BranchCache
doAssert cache.branchFor(path, 0) == ""
echo "remote ok"
