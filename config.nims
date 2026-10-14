switch("nimcache", "nimcache")
switch("define", "nimPreviewCheckedClose")

when defined(linux):
  # windy == 0.5.0 X11 fixes (see patches/windy/README.md); re-check on any windy bump
  patchFile("windy", "x11", thisDir() & "/patches/windy/x11")
  patchFile("windy", "xevent", thisDir() & "/patches/windy/xevent")

when defined(macosx):
  # windy == 0.5.0 AppKit fixes: key window focus, files opened via Finder / open -a
  patchFile("windy", "platform", thisDir() & "/patches/windy/macos/platform")

when defined(windows):
  # GUI subsystem: no console window behind the editor. Tests keep theirs for output.
  if projectName() == "darger": switch("app", "gui")
