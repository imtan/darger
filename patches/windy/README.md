# windy 0.5.0 X11 patches

`x11.nim` and `xevent.nim` are copies of windy 0.5.0's Linux X11 backend
(`windy/platforms/linux/x11.nim`, `windy/platforms/linux/x11/xevent.nim`)
with fixes darger needs: XCheckIfEvent predicate ABI (input freeze after the
first copy/yank), clipboard read hang and reply types, a per-redraw leak in
property reads, held keys replayed as presses on FocusIn, WM_CLASS, format-32
property reads, TARGETS-negotiated/validated/INCR clipboard reads, Latin-1
STRING replies, and a flush after XDestroyWindow.
Each file's header lists its exact deltas. `config.nims` swaps them in with
`patchFile` on Linux only; Windows and macOS use stock windy.
windy is MIT licensed; its notice is kept in `LICENSE` in this directory.

On any windy version bump, re-diff against the new upstream files, drop what
upstream fixed, and re-apply the rest (or remove the patchFile lines).
