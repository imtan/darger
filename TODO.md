# darger backlog

The exploratory improvement loop works through this file: it picks the top open item
(or finds a new one by probing), fixes it with tests, commits, and moves the item to
the log below. Reorder or add items freely; the loop reads it fresh every round.

## Rules the loop follows

- Small core, large extensions: new features go under `src/ext/`, pure logic in its
  own module with a test in `tests/`. Mention when a change grows `core.nim`.
- Emacs behaviour is the reference when darger differs without a reason.
- Every change: build, run the affected tests, `nimble app`, commit with a clear
  message. Never leave the tree dirty between rounds.
- No synthetic keystrokes into the user's session. GUI checks use a temporary HOME
  with a `.darger.el` that drives commands, `open -a` / direct launch, and a
  screenshot of darger's own window. Never touch `~/Dropbox/Org` or `~/.darger.el`.
- Pick work the user feels daily (journal, Org, SKK, windows, agents) over polish.
- One item per round; if an item is too big, split it here and do the first slice.

## Open

1. Reload a buffer when its file changes on disk (unmodified buffer: silently; modified:
   ask) — README warns that saving can overwrite an agent's edit.
2. Terminal buffer (vterm replacement) — slice 1: spawn a shell on a pty, show its
   output in a buffer, send typed lines; slice 2: raw key mode and ANSI colours;
   slice 3: `claude` in it with C-c C c-style bindings (send region / file).
3. Mouse in the text: click places the cursor, wheel scrolls the pane under it.
4. SKK: `skk-egg-like-newline` variable (Enter inserts a newline after kakutei when
   nil, as DDSKK's default); zenkaku latin `L`; `l`-prefixed small kana.
5. Org journal: insert `templates/journal-daily.org` (org-journal-daily-template-file)
   when the day's first entry is created, as the user's Emacs does.
6. Org agenda, minimal: `M-x org-agenda` lists TODO / SCHEDULED items of
   `org-agenda-files` for today in a consult-style list.
7. Windows: `C-x +` balance, `C-x ^` / `C-x }` resize, `C-x 4 b` other-window buffer.
8. Add the monkey/fuzz tests (Buffer, SKK, Lisp, HTML) to `tests/` and the README list.
9. Dashboard: a line for C-c j (today's journal) and C-c t (capture).
10. Dictionary registration: Enter with text containing `;` annotations, and
    `(concat ...)` evaluation when a candidate uses it.

## Log

(the loop appends `- YYYY-MM-DD <commit> <what>` here)
