## macOS only: screen geometry windy does not expose, and the files the system opens
## (collected by the patched windy backend, patches/windy/macos/platform.nim). Kept
## apart from darger.nim because windy's AppKit bindings shadow `string` wherever
## they are imported.
import windy
import windy/platforms/macos/[macdefs, objc, platform]
export takeOpenedFiles

objc:
  proc visibleFrame(self: NSScreen): NSRect

proc visibleArea*(window: Window): tuple[x, y, w, h: float32] =
  ## The window's screen's visible frame (under the menu bar, beside the Dock) in
  ## points, with y counted down from the top of the screen as windy's pos does.
  let screen = window.nativeWindow.screen
  let full = screen.frame
  let vis = screen.visibleFrame
  (vis.origin.x.float32, (full.size.height - vis.origin.y - vis.size.height).float32,
   vis.size.width.float32, vis.size.height.float32)
