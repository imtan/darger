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

- TRAMP second slice: remote rgrep / consult-ripgrep through ssh, and remote LSP.

Review first (2026-10-16, the user: "レビューに関する機能を優先的に充実させたい"). The
review overlay (hunks of a proposed text over the buffer; y/k/u/n/p/a/q) is the
human gate for agent edits, so it grows before the other items:

R1. (done) Reviews from any source: diff-buffer-with-file, vc-review (git HEAD), review-file;
    the supersede prompt's `r`; u / ? keys.
R2. (done) Word-level refine highlighting, per-hunk +/- counts, `l` hunk list.
R3. (done) `e` edits the proposed hunk in a *hunk* buffer, C-c C-c applies
R4. (done) `r`: request changes to the hunk through the agent; the reply replaces the proposal.
R5. (done) Edited buffer changed on disk: offered once / auto-revert-review opens it;
    agent-changes lists the files a chat turn changed, Enter reviews each.
R6. (done) `|` side-by-side view
R7c. (done) *understanding* buffer (user: "バッファにして"): C-c u, magit-status-like view of
    branch files to understand / understood, open debt, glossary; Enter / U / o / g / q.
    Next: x on a file row (explain the whole file's change), debt count in the mode line.
R7b. (done) Per-branch ledger (user: "理解台帳かな。…自分の作業を自分で理解する負債としたい"):
    :BRANCH: / :REV: on entries, understanding-debt per branch, U attest, branch-debt
    (files changed from the merge base without a DONE attestation -> base review).
R7. (done, first slice) Understanding ledger (user: "ドメイン知識も含めた理解負債を解消する仕組み"):
    x explains a hunk, taken hunks go to ~/.darger-understanding.org as TODO (debt) /
    DONE (understood), understanding-debt lists them, glossary collects `- term :: def`.
    Next: repay from a normal buffer (explain the region / the entry's lines now, flip
    the entry to DONE); glossary lookup of the word at point; a debt count in the
    mode line or dashboard; quiz mode (the agent asks, the user answers).

(2026-10-16: reordered after comparing ~/.emacs.d/config.org with darger. The user's
rule: only add what is missing; never rebind or remove existing darger keys.)

1. Mode line polish (doom-modeline-ish): git branch, LSP state, SKK state grouped.
2. Books viewer, skilltree / feynman menus, YouTube browse, nostr, elpher, calfw:
    personal Emacs tools; port only on request.

## Log

- 2026-10-28 SKK kutouten: "." and "," insert 。、 in kana modes; skk-kutouten-type jp / en / jp-en / en-jp / ascii (setKutouten, tskk kutouten block)
- 2026-10-28 org-journal over SSH: org-journal-dir accepts /ssh:HOST:path (the day's file is read, created after mkdir -p and saved over ssh); core makeDirectory / remoteMakeDir hook
- 2026-10-21 treemacs icons: Nerd Font file-type icons coloured by type (src/icons.nim, ticons tests), treemacs-icons setting, render.hasGlyph for the font check
- 2026-10-21 treemacs file tree: left pane, lazy sorted directory chains, follow/reveal, hidden entries, root navigation and other-window skipping; tfiletree tests. DARGER_BACKGROUND=1 shows the window without taking keyboard focus (scripted runs, screenshots)

- 2026-10-21: Added TRAMP-style SSH file loading/saving, completion, Dired browsing, mode-line host hint and control-master cleanup; pure and mocked transport tests.

(the loop appends `- YYYY-MM-DD <commit> <what>` here)

- 2026-10-21 syntax: HTML/XML/Vue/Svelte, CSS/SCSS/Sass/Less, SQL, Haml/Slim, Dockerfile, Makefile, INI/env, Procfile and GraphQL; Rails file mappings and regression tests (tsyntax)
- 2026-10-21 dashboard: any other bound key closes it and runs (user: "ダッシュボードでいろいろ undefined になる"); press-key primitive
- 2026-10-21 frame-alpha (user: "設定でエディタを半透明にできる?"): NSWindow alphaValue through the patched windy backend, applied per tick when the setting changes (macOS)
- 2026-10-21 projectile hydra on C-c p (user request): f p b s r v d l q over the project, grep, magit, dired and agent-locate commands; project-dired
- 2026-10-20 defhydra (user: "Hydra みたいな機能欲しい"): heads with :exit, a hint box above the mode line while active, hydra-enter; the zoom hydra uses it; type-string dispatches pending chords (src/hydra.nim tested)
- 2026-10-20 Grep mode (user: "Grep モードという名前にして共通化"): places renamed grep-mode / *grep* / grep-next, auto-open for files that read like grep output, M-x rgrep into a grep buffer, "(Grep)" in the mode line (modeNameProviders)
- 2026-10-20 fix (user: "places の n, p が機能しなくなった"): typed letters go through runeFilters, not keyFilters, so the places / understanding / magit buffers now route runes to their key handlers; (type-string "...") types from Lisp
- 2026-10-20 terminal: bold font weight (Bold / SemiBold / Medium), per-pane bold attributes and regular fallback; SGR reset and wide-rune flags covered by tscreen (synthetic bold when the font has no bold weight, e.g. SF Mono)
- 2026-10-20 review R6: | toggles aligned read-only before/after panes, shared decisions and navigation, restores panes on exit; alignment, colours and refine covered by treview
- 2026-10-20 review R3: e edits proposed hunk lines in *hunk*, C-c C-c applies and C-c C-k cancels; newline normalization and rediff covered by treview
- 2026-10-20 olivetti-mode: per-buffer centred writing margin, configurable body width and automatic language activation; drawing, mouse mapping and Org images share the margin (tolivetti)
- 2026-10-20 agent prose wraps to pane width with Japanese kinsoku and list indents; cached Git branch in the mode line, including worktrees (twrap, tvcline)
- 2026-10-20 magit, minimal: C-x g status, stage/unstage, HEAD review, confirmed discard, commit prompt, push / ff-only pull; porcelain -z parsing (tmagit)
- 2026-10-20 writing helpers (C-c G): region/buffer translation, proofreading, tone, summaries, keywords and titles through hunk review; Markdown blog drafts in another window (twriting)
- 2026-10-20 dashboard like nvim's start screens (user request): solid-cell DARGER logo with shadow (bgs 13/14), centred menu with real bindings, recent files, footer with the understanding debt, relaid on resize
- 2026-10-20 understanding-repay: explain the nearest recorded debt, mark it DONE, and merge glossary terms; x on understanding debt rows (ledger tests)
- 2026-10-20 understanding is an ordinary read-only buffer too (keyFilters / providers), q leaves, the comparison returns to it
- 2026-10-20 places is an ordinary read-only buffer with its own keys instead of an overlay (user: C-x o did not work); understanding lets window commands through
- 2026-10-20 ERB mode (user request): HTML tags/attributes/comments + Ruby inside <% %> via a shadow document (tsyntax)
- 2026-10-20 places: the followed line and the current list row are highlighted (bandProviders, band 5 = theme.region)
- 2026-10-20 *places* (grep-mode style, user's example): n/p follow in the other window, Enter, o, cookie files open as places, agent-locate answers go there (src/places.nim tested)
- 2026-10-20 PATH from the login shell on macOS GUI launches (user: "/bin/sh claude not found"), src/execpath.nim tested
- 2026-10-20 understanding asks for the base branch on first open per repository and remembers it (~/.darger-understanding-bases) (user: "無意味に master と毎回比較されるのは面倒")
- 2026-10-20 understanding: b chooses the base branch (user request), understanding-base primitive
- 2026-10-20 understanding / branch-debt: one git numstat for the whole branch instead of three calls per file (the user: it hung with many changes)
- 2026-10-20 agent-locate (C-c l): ask the agent where, answer parsed as path:line places in a consult list (grep.parsePlaces / findReferences tested); agent-references; onAgentResult hook
- 2026-10-17 *understanding* buffer (ext/understand.nim): branch files to understand / understood, open debt, glossary; comparison returns to it (afterReview)
- 2026-10-16 understanding ledger per branch (+ X: ask a question about a hunk, answers join the explanation; branch-base comparisons read base -> branch, read-only): :BRANCH:/:REV:, U attest, understanding-debt(-all), branch-debt with base reviews (chat.branchOf, ledger.entries/understoodRevs tested)
- 2026-10-16 understanding ledger R7 slice 1: x explain in *explain*, ledger TODO/DONE entries on review end, understanding-debt, glossary (src/ledger.nim tested)
- 2026-10-16 review R5: changed-on-disk offer + auto-revert-review; agent-changes (src/changes.nim snapshots, tested) with per-file reviews
- 2026-10-16 review R4 + part of R3: `r` sends a hunk request to the agent and the reply replaces the proposal (checked with a fake agent); `w` applies so far and continues; `A` keeps all
- 2026-10-16 review R2: refine highlighting of the changed part of paired lines (bgs 9-12), -/+ counts in the echo line, `l` hunk list
- 2026-10-16 review R1: diff-buffer-with-file, vc-review, review-file, supersede `r`, u / ? keys, source in the echo line
- 2026-10-16 term line mode (user request): C-c C-j / C-c C-k, Enter sends the input typed after the screen, [Line]/[Char] in the mode line
- 2026-10-16 org-roam-graph (C-c n g): self-contained HTML force graph in the browser, current note red (roam.graphHtml tested)
- 2026-10-16 org-roam-capture (C-c n c, templates with one-key choice) and org-roam-tag-add (C-c n t), tested in torg
- 2026-10-16 Eagle picker thumbnail preview (Prompt.thumbnail, renderer.loadPicture shared with inline images); exit-minibuffer primitive; WebP (Eagle thumbnails) via a sips PNG cache (src/pictures.nim)
- 2026-10-16 Inline images: cropped at the pane bottom; wheel, C-v / M-v and recenter count image rows (stepShown moved to panes.nim, tested)
- 2026-10-16 Org inline images: [[file:…png]] drawn under its line (rows reserved, click maps to the line, org-image-max-rows)
- 2026-10-16 C-M-y pastes the clipboard image as img/日時.png + [[file:img/…]] (windy pasteboard + pixie, no pngpaste)
- 2026-10-16 migemo: romaji finds kana and SKK-dictionary words in isearch and all completion prompts (src/migemo.nim, no cmigemo needed)
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
