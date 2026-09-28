switch("nimcache", "nimcache")
switch("define", "nimPreviewCheckedClose")

when defined(linux):
  # windy == 0.5.0 X11 fixes (see patches/windy/README.md); re-check on any windy bump
  patchFile("windy", "x11", thisDir() & "/patches/windy/x11")
  patchFile("windy", "xevent", thisDir() & "/patches/windy/xevent")
