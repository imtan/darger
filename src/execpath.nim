## The PATH of the user's login shell for darger started from the Finder, Spotlight
## or the Dock, where macOS gives applications only /usr/bin:/bin:/usr/sbin:/sbin and
## `claude`, `rg`, `git` from Homebrew are "not found" (what exec-path-from-shell
## does for Emacs).
import std/[os, osproc, strutils]

const knownDirs = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", ".local/bin", ".bun/bin",
  ".cargo/bin", ".volta/bin", ".npm-global/bin", ".deno/bin", "go/bin", ".nimble/bin"]

proc loginPath*(shell: string): string =
  ## PATH as the login shell sets it (`shell -l -c 'printf %s "$PATH"'`); "" on failure.
  if shell.len == 0 or not fileExists(shell): return ""
  try:
    let (output, code) = execCmdEx(quoteShell(shell) & " -l -c " & quoteShell("printf %s \"$PATH\""),
      options = {poUsePath})
    if code == 0:
      # Some shells print banners; the PATH is the last line.
      for l in output.strip.splitLines:
        if ':' in l or l.startsWith("/"): result = l.strip
  except CatchableError: result = ""

proc mergedPath*(current, fromShell, home: string, exists: proc(dir: string): bool): string =
  ## The current PATH with the shell's entries and the usual tool directories (when
  ## they exist) added after it, each directory once.
  var dirs: seq[string]
  proc add(d: string) =
    if d.len > 0 and d notin dirs: dirs.add d
  for d in current.split(':'): add d
  for d in fromShell.split(':'): add d
  for d in knownDirs:
    let full = if d.isAbsolute: d else: home / d
    if exists(full): add full
  dirs.join(":")

proc fixPath*() =
  ## Sets PATH for this process from the login shell and the known directories.
  let merged = mergedPath(getEnv("PATH"), loginPath(getEnv("SHELL")), getHomeDir(), proc(d: string): bool = dirExists(d))
  if merged != getEnv("PATH"): putEnv("PATH", merged)
