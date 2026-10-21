## Window transparency: (setq frame-alpha 0.85) makes the whole window that opaque
## (text included, like Emacs' `alpha` frame parameter), 1 = opaque. macOS only for
## now; elsewhere the setting is read and ignored.
import std/[tables]
import ../[core, lisp]
import windy

var applied = -1.0

tickHooks.add proc(): bool =
  let v = interp.env.values.getOrDefault("frame-alpha")
  let alpha = if v == nil or v.kind == vNil: 1.0 else: clamp(v.asNumber, 0.1, 1.0)
  if alpha == applied: return false
  applied = alpha
  when defined(macosx):
    window.alpha = alpha
  else:
    if alpha < 1.0: echoLine = "frame-alpha: transparency is only wired up on macOS yet"
  false

defaults.add """
(setq frame-alpha 1.0)
"""
