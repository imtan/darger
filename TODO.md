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

(2026-10-16: reordered after comparing ~/.emacs.d/config.org with darger. The user's
rule: only add what is missing; never rebind or remove existing darger keys.)

1. migemo: romaji matches Japanese in isearch, consult-line and the completion prompts,
   using cmigemo's dictionary when installed (the user has migemo in Emacs).
2. Org images: `C-M-y` pastes the clipboard image into `images/` next to the file and
   inserts `[[file:...]]` (macOS pbpaste/pngpaste); inline image display later, which
   would also give the Eagle picker its thumbnail preview.
3. org-roam: `C-c n c` capture a note with a prompt for the title, `C-c n t` add a tag
   (`#+filetags:`), backlinks buffer refresh, `C-c n g` graph (open in browser via dot?).
4. Writing helpers through the agent (their Gemini/gptel map `C-c G`): translate,
   proofread, summarize, keywords, blog draft on the region, through `agent-command`
   with prompt templates; result replaces the region or opens a buffer.
5. magit, minimal: `C-x g` status buffer (branch, staged/unstaged files, untracked),
   `s`/`u` stage/unstage, `c c` commit with a message buffer, `P p` push, diff on Enter.
6. Terminal: `C-c C-j` line mode as in Emacs term; a bold face (second font weight).
7. Mode line polish (doom-modeline-ish): git branch, LSP state, SKK state grouped;
    olivetti-style centred writing width for Org (`M-x olivetti-mode`).
8. Books viewer, skilltree / feynman menus, YouTube browse, nostr, elpher, calfw:
    personal Emacs tools; port only on request.

## Log

(the loop appends `- YYYY-MM-DD <commit> <what>` here)

- 2026-10-16 projects: C-x p f / p / b over the git root (src/project.nim tested), known roots in ~/.darger-projects
- 2026-10-16 Eagle images (user request): C-M-e by keyword, C-c e by folder, link to the library file as ~/… (src/eagle.nim tested against the live API)
- 2026-10-16 org-todo-keywords: sequence, done words, faces, agenda, fast one-key selection on C-c C-t
- 2026-10-16 consult-ripgrep (rg, grep fallback; src/grep.nim tested), C-c n s over org-roam-directory
- 2026-10-16 windmove C-c arrows (panes.neighbour tested), C-c n j org-roam-dailies-capture-today
- 2026-10-16 terminal: mouse reporting (?1000/1002/1003, SGR ?1006) through a core mouseFilters hook, wheel as arrows on the alternate screen, no gutter in terminal buffers (fixes the width mismatch)
- 2026-10-16 exploration: tests/editormonkey (random command sequences through ~/.darger.el in a throwaway HOME; 16 seeds x 300 commands, no crash); (ignore-errors ...) added to the Lisp
- 2026-10-16 SKK: annotations kept and shown beside candidates, (concat "...") evaluated, registered words with / or ; encoded, "word;note" registration
- 2026-10-16 windows: split ratios with C-x ^ / C-x } / C-x { resizing, C-x + balance (panes.resize / balance tested), C-x 4 b / C-x 4 f
- 2026-10-16 dashboard: a Today list (j journal, t capture, a agenda, s shell); recent files now 1-9 and 0
- 2026-10-16 org-agenda (minimal): today's scheduled / deadline / dated items and undated TODOs of org-agenda-files as a consult list (orgmode.agendaItems tested)
- 2026-10-16 terminal: background colours, underline and inverse video in the screen model and renderer (backProviders / markProviders hooks)
- 2026-10-16 tests/tmonkey.nim: fuzzers for Buffer, SKK, Lisp, HTML, terminal text/screen and pointAt; found and fixed two screen-model bugs (cursor restore after shrink, wide rune on a one-column screen)
- 2026-10-16 journal: org-journal-condition-prompt, the one-key 体調 [1-5] ★ prompt after a new entry
- 2026-10-16 terminal slice 3: several terminals (Terminal objects), wide runes take two cells, src/ext/claude.nim with C-c C c / C-c C t / C-c C n / C-c C r / C-c C f as in the user's Emacs
- 2026-10-16 terminal slice 2c: M-x term shows the screen model in *terminal*, every key raw to the pty (keySequence tested), C-x / C-c stay the editor's; runeFilters hook in core
- 2026-10-16 journal: org-journal-daily-template-file under the date headline of a new day, org-journal-add-id for an ID drawer (user: format differed from Emacs)
- 2026-10-16 terminal slice 2b: src/termscreen.nim, a VT100/xterm screen model (cursor addressing, erase, insert/delete, scrolling regions, alternate screen, scrollback, colours, resize), tests/tscreen.nim
- 2026-10-16 terminal slice 2a: ANSI foreground colours in *shell* (theme ansi palette, faceProviders hook), window size follows the pane
- 2026-10-16 SKK: skk-egg-like-newline variable, zenkaku latin L; l-prefixed small kana dropped (l is DDSKK's latin key)
- 2026-10-16 mouse: click places the cursor (and selects the pane), wheel scrolls the pane under the pointer (panes.pointAt tested)
- 2026-10-16 terminal slice 1: M-x shell / C-c s comint-style *shell* on a pty (src/pty.nim, src/termtext.nim, src/ext/term.nim), Enter sends, C-c C-c interrupts, C-d EOF
- 2026-10-16 background shader (user request): GLSL under the text, C-c C-c / C-c C-o / C-c C-k in GLSL buffers, live re-apply, errors to *shader* (src/ext/shader.nim, src/shadersrc.nim)
- 2026-10-15 auto-revert: unedited buffers follow their files, saving over a changed file asks, M-x revert-buffer (src/ext/revert.nim, Buffer.revert)
