import std/[os, strutils]
import ../src/execpath

let merged = mergedPath("/usr/bin:/bin", "/opt/x/bin:/usr/bin:/home/u/.local/bin", "/home/u",
  proc(d: string): bool = d in ["/opt/homebrew/bin", "/home/u/.cargo/bin"])
doAssert merged == "/usr/bin:/bin:/opt/x/bin:/home/u/.local/bin:/opt/homebrew/bin:/home/u/.cargo/bin", merged
doAssert mergedPath("/usr/bin", "", "/h", proc(d: string): bool = false) == "/usr/bin"
doAssert loginPath("") == "" and loginPath("/no/such/shell") == ""
when defined(macosx) or defined(linux):
  let p = loginPath("/bin/sh")
  doAssert p.len > 0 and "/usr/bin" in p.split(':'), p
echo "execpath ok"
