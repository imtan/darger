# windy 0.5.0 patches

`x11.nim` and `xevent.nim` are copies of windy 0.5.0's Linux X11 backend
(`windy/platforms/linux/x11.nim`, `windy/platforms/linux/x11/xevent.nim`)
with fixes darger needs: XCheckIfEvent predicate ABI (input freeze after the
first copy/yank), clipboard read hang and reply types, a per-redraw leak in
property reads, held keys replayed as presses on FocusIn, WM_CLASS, format-32
property reads, TARGETS-negotiated/validated/INCR clipboard reads, Latin-1
STRING replies, and a flush after XDestroyWindow.
`macos/platform.nim` is a copy of the macOS backend
(`windy/platforms/macos/platform.nim`) whose borderless windows take keyboard
focus (the canBecomeKeyWindow override was registered under the wrong selector)
and whose app delegate implements `application:openFiles:`, so files opened from
Finder, Spotlight or `open -a darger` reach the editor (`takeOpenedFiles()`).
Each file's header lists its exact deltas. `config.nims` swaps them in with
`patchFile` on Linux and macOS; Windows uses stock windy.
windy is MIT licensed; its notice is kept in `LICENSE` in this directory.

On any windy version bump, re-diff against the new upstream files, drop what
upstream fixed, and re-apply the rest (or remove the patchFile lines).
