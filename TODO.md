# darger backlog

The exploratory improvement loop works through this file: it picks the top open item
(or finds a new one by probing), fixes it with tests, commits, and moves the item to
the log below. Reorder or add items freely; the loop reads it fresh every round.

## Rules the loop follows

- Small core, large extensions: new features go under `src/ext/`, pure logic in its
  own module with a test in `tests/`. Mention when a change grows `core.nim`.
- Emacs behaviour is the reference when darger differs without a reason.
- Every change: build, run the affected tests, `nimble app`, commit with a clear
  message, and push to origin/master (darger-update pulls from GitHub). Never leave
  the tree dirty between rounds.
- No synthetic keystrokes into the user's session. GUI checks use a temporary HOME
  with a `.darger.el` that drives commands, `open -a` / direct launch, and a
  screenshot of darger's own window. Never touch `~/Dropbox/Org` or `~/.darger.el`.
- Pick work the user feels daily (journal, Org, SKK, windows, agents) over polish.
- One item per round; if an item is too big, split it here and do the first slice.

## Open

1. Terminal buffer — slice 2c: `M-x term`, a buffer showing src/termscreen.nim's
   screen (scrollback above it) with every key sent raw to the pty (C-c as the escape
   prefix, as Emacs term's char mode), TERM=xterm-256color, size following the pane;
   slice 3: `claude` in it with C-c C c-style bindings (send region / file, side window).
2. Org journal: the 体調 ★ prompt on a new entry (1-5 stars after the time, skip on
   any other key), as the user's Emacs hook does.
3. Org agenda, minimal: `M-x org-agenda` lists TODO / SCHEDULED items of
   `org-agenda-files` for today in a consult-style list.
4. Windows: `C-x +` balance, `C-x ^` / `C-x }` resize, `C-x 4 b` other-window buffer.
5. Add the monkey/fuzz tests (Buffer, SKK, Lisp, HTML) to `tests/` and the README list.
6. Dashboard: a line for C-c j (today's journal) and C-c t (capture).
7. Dictionary registration: Enter with text containing `;` annotations, and
    `(concat ...)` evaluation when a candidate uses it.

## Log

(the loop appends `- YYYY-MM-DD <commit> <what>` here)

- 2026-10-16 journal: org-journal-daily-template-file under the date headline of a new day, org-journal-add-id for an ID drawer (user: format differed from Emacs)
- 2026-10-16 terminal slice 2b: src/termscreen.nim, a VT100/xterm screen model (cursor addressing, erase, insert/delete, scrolling regions, alternate screen, scrollback, colours, resize), tests/tscreen.nim
- 2026-10-16 terminal slice 2a: ANSI foreground colours in *shell* (theme ansi palette, faceProviders hook), window size follows the pane
- 2026-10-16 SKK: skk-egg-like-newline variable, zenkaku latin L; l-prefixed small kana dropped (l is DDSKK's latin key)
- 2026-10-16 mouse: click places the cursor (and selects the pane), wheel scrolls the pane under the pointer (panes.pointAt tested)
- 2026-10-16 terminal slice 1: M-x shell / C-c s comint-style *shell* on a pty (src/pty.nim, src/termtext.nim, src/ext/term.nim), Enter sends, C-c C-c interrupts, C-d EOF
- 2026-10-16 background shader (user request): GLSL under the text, C-c C-c / C-c C-o / C-c C-k in GLSL buffers, live re-apply, errors to *shader* (src/ext/shader.nim, src/shadersrc.nim)
- 2026-10-15 auto-revert: unedited buffers follow their files, saving over a changed file asks, M-x revert-buffer (src/ext/revert.nim, Buffer.revert)
