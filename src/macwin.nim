## macOS only: screen geometry windy does not expose. Kept apart from darger.nim
## because windy's AppKit bindings shadow `string` wherever they are imported.
import windy
import windy/platforms/macos/[macdefs, objc]

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

proc yes(self: ID, cmd: SEL): bool {.cdecl.} = true

proc allowKeyWindow*(window: Window) =
  ## windy 0.5.0 registers its canBecomeKeyWindow override under the wrong selector
  ## ("canBecomeKeyWindow:"), so a borderless window never takes keyboard focus. Add
  ## the real one to windy's window class and take focus now. Re-check on any windy bump.
  var cls = objc_getClass("WindyWindow")
  if cast[int](cls) == 0: cls = object_getClass(window.nativeWindow.ID)
  discard class_addMethod(cls, s"canBecomeKeyWindow", cast[IMP](yes), "")
  window.nativeWindow.makeKeyAndOrderFront(0.ID)
