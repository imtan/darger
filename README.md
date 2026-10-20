# darger

日本語版: [README.ja.md](README.ja.md)

A small GPU text editor for Windows 11 and Linux, built with Nim 2.2.10+. Windy owns
the window, OpenGL context, input and clipboard; Pixie rasterizes glyphs into Boxy's
GPU atlas. macOS compiles but is untested; `agent-command` can use
`claude -p --output-format text` unchanged.

C-c a (`agent-prompt`) sends the current file and an instruction through
`agent-command` for a one-shot edit, then opens a diff review. C-g cancels.
C-c c (`agent-chat`) instead prompts `Agent chat (<root directory name>): ` for a
multi-turn conversation in the project's top directory: the nearest ancestor
holding `.git`, or the file's directory if none exists. From a chat buffer it
uses that chat's root; from any other path-less buffer it searches from the
working directory, falling back to that directory.

Each root has an in-memory session and a Markdown transcript named
`*agent <root directory name>*`, reachable with C-x b. C-c c Enter with no text
opens the existing transcript without sending anything. Messages go unchanged
to stdin; replies keep Markdown and code fences. Only one agent can run at a
time across both commands. C-g records cancellation; failures appear in the
transcript. A reply does not switch away from another buffer. Killing a
transcript forgets the conversation and drops any pending reply. Transcripts
never require saving, and no chat history is saved to disk. `M-x agent-chat-new`
empties the current root's transcript and resets its session (refused while
that conversation is running).

Chat replies appear live, with tool names and short summaries as Markdown quote
lines and `...` at the end while the process runs. Thinking and tool results are
hidden. Only complete output lines are displayed; ordinary plain-text agent
commands also work. A cancellation or failure keeps the output received so far.
The cursor starts at the bottom and follows new output while it stays on the
last line; move up to read without following. Updates do not add undo history.
Both chat and one-shot agents show elapsed time (`Agent running 1:23`) in the
echo line, with the latest tool activity for chat.

The defaults (override them in `~/.darger.el`) are:

```lisp
(setq agent-chat-command "claude -p --output-format stream-json --verbose --session-id {id}")
(setq agent-chat-resume-command "claude -p --output-format stream-json --verbose --resume {id}")
```

Every `{id}` is replaced with the session's random UUID. The resume command is
used only after a successful reply; a failed first message retries the first
command. With these defaults, `claude -p` can read the project, and refuses to
edit files or run commands unless your Claude Code settings already allow them,
since nobody can be asked. Adding `--permission-mode acceptEdits` to both
variables allows edits. A buffer without edits of its own follows its file: when the
agent (or anything else) changes it on disk, darger reads it again within a second
(`Reverted NAME`, one undo step brings the old text back); a buffer you have edited
keeps your text, and C-x C-s over a file changed on disk first asks
`NAME changed on disk; save anyway? (y or n)`. `M-x revert-buffer` reads the file
again over your edits.

```powershell
nimble build -d:release
.\darger.exe [file...]
nim r tests/tbuffer.nim
```

```sh
nimble build -d:release       # or: nimble install -d && nim c -d:release --outdir:. src/darger.nim
./darger [file...]
nim r tests/tbuffer.nim
nim r tests/tfileio.nim   # POSIX save behaviour
nim r tests/trecent.nim
nim r tests/tbuffers.nim
nim r tests/tcomplete.nim
nim r tests/tsyntax.nim
nim r tests/thtml.nim     # HTML layout for the web viewer
nim r tests/tfeed.nim     # RSS / Atom parsing
nim r tests/tfetch.nim    # curl downloads (needs curl; uses file:// URLs)
nim r tests/tupdate.nim   # self-update against a local bare repository (needs git)
nim r tests/torg.nim      # Org structure and org-roam notes
nim r tests/tterm.nim     # shell output text and the pty (needs /bin/sh)
nim r tests/tscreen.nim   # the terminal screen model and key sequences
nim r tests/tpanes.nim    # window layout
nim r tests/tshader.nim   # background shader sources
nim r tests/tgrep.nim     # ripgrep / grep output parsing and a real search
nim r tests/teagle.nim    # Eagle API parsing and link paths
nim r tests/tproject.nim  # project file listing (git and plain) and known projects
nim r tests/tmigemo.nim   # romaji -> kana -> dictionary words for migemo
nim r tests/tpictures.nim # PNG conversion cache for pictures pixie cannot decode
nim r tests/tchanges.nim  # files changed under a project between two snapshots
nim r tests/texecpath.nim # the login shell's PATH merged for GUI launches
nim r tests/tledger.nim   # understanding ledger entries and the glossary
nim r tests/tmonkey.nim   # fuzz: random input into Buffer, SKK, Lisp, HTML, the terminal, panes
tests/editormonkey/run.sh 1 16 300   # whole editor: random command sequences per seed (opens windows)
```

## darger.app on macOS

`nimble app` builds the release binary and assembles `~/Applications/darger.app`
around a copy of it, registered with LaunchServices, so darger opens from Spotlight,
the Dock and Finder's "Open With" (plain text, source code, Markdown and `.org`
files) and with `open -a darger file.org`. The binary is copied rather than run
from the checkout because macOS lets LaunchServices start an executable that lives
under `~/Documents` (or Desktop, Downloads) only after a privacy prompt that never
comes for an unsigned build: the launch hangs before the first instruction, while
the same binary runs fine from a terminal. The bundle's `darger` is a stub that
records the checkout in `DARGER_SOURCE` and runs the copied `darger-bin`, so
`M-x darger-update` still finds the checkout, and started from the bundle it
rebuilds with `nimble -y app`, refreshing the copy; after a manual `nimble build`
run `nimble app` again. Files opened this way arrive as an Apple event, not as
arguments (AppKit also reports the command-line arguments that way; those are
dropped); a patched copy of windy's macOS backend
(`patches/windy/macos/platform.nim`) collects them and the editor visits them, into
the running darger when there is one, instead of the dashboard. Launched this way
the window also takes focus, which a bare `./darger` started from another program
does not get on recent macOS; for a script, `open -n -W -a darger --args FILE`
starts a new instance with FILE and waits until it closes.

When started from the Finder, Spotlight or the Dock, darger takes the PATH of the
login shell (`$SHELL -l -c 'printf %s "$PATH"'`) and adds the usual tool directories
(Homebrew, `~/.local/bin`, `~/.bun/bin`, …) that exist, so `agent-command`
(`claude`), `rg` and `git` are found as in a terminal; macOS otherwise gives
applications only the bare system PATH.

## Updating darger

`M-x darger-update` checks GitHub for new commits and, when there are any, pulls
them and rebuilds the editor in the background. It works on the checkout holding the
running executable (override with `(setq darger-source-directory "~/src/darger")`),
which must be a git clone with `darger.nimble`. The steps are `git fetch`, a
comparison with the upstream branch, `git merge --ff-only` and `darger-build-command`
(default `nimble -y build -d:release`; set it to the `nim c` line above if your nimble
is too old). The echo line shows `Updating darger  checking GitHub 0:03  C-g:cancel`
(then `pulling`, `building`); C-g stops the running step. Every step's command and
output goes to a `*darger update*` buffer (C-x b), without switching to it. The result
is one of `darger is up to date`, `darger updated to <hash> (N commits): restart to use
it`, or `darger update failed: ...`. Local commits that GitHub lacks are never merged
over: with no new upstream commits they count as up to date, otherwise the update
stops with `local commits diverge from GitHub`. Git never prompts for credentials
(`GIT_TERMINAL_PROMPT=0`). On Windows the running `darger.exe` is renamed to
`darger.old.exe` before the build, moved back if the build fails, and deleted at the
next start. `(darger-update)` in `~/.darger.el` checks at every start and reload.

Nimble older than 0.24 (e.g. the 0.22.x bundled with Nim 2.2.10) fails with
`cannot open file: opengl`; use the `nim c` line instead.

On Linux windy uses X11 + GLX only, so Wayland sessions need XWayland. libX11,
libXext, libXcursor and libGL.so.1 are loaded with dlopen at startup (`ldd` does not
list them): Arch `libx11 libxext libxcursor libglvnd mesa xorg-xwayland`, Debian
`libx11-6 libxext6 libxcursor1 libgl1`. `config.nims` swaps in patched copies of
windy 0.5.0's X11 backend from `patches/windy` via `patchFile` on Linux only (see
`patches/windy/README.md`); windy stays pinned to 0.5.0.

The window has no system title bar or frame; darger draws its own title bar, one text
row high: the buffer name in the middle and minimize, maximize and close buttons (on
the left on macOS, on the right elsewhere). Dragging anywhere with the left button
moves the window, dragging its right or bottom edge (6 px) or its bottom right corner
(32 px) resizes it, and a double click on the title bar toggles maximized, which covers
the whole screen including the taskbar (on macOS, the screen beside the menu bar and
the Dock). A click in the text selects that window and puts the cursor there (the mark
is deactivated); the wheel scrolls the window under the pointer three lines a notch,
moving its cursor only as far as needed to keep it in view, as Emacs does. The mouse does
nothing else. On macOS, windy 0.5.0 registers its borderless
window's `canBecomeKeyWindow` override under the wrong selector, so such a window never
takes keyboard focus; the patched backend above registers the real one (re-check on
any windy bump). macOS itself takes C-SPC for "Select the previous input source"
(System Settings > Keyboard > Keyboard Shortcuts > Input Sources) and C-arrows for
Mission Control; turn those off, or bind `mark` elsewhere in `~/.darger.el`. Option
types special characters on many keys there, so on macOS the command key is Meta
(`meta-modifier` is `"cmd"`; the system still keeps Cmd-Tab and Cmd-Space);
`(setq meta-modifier "alt")` in `~/.darger.el` makes Option Meta, as elsewhere. C-x C-c quits. On Windows the build is a GUI program (`--app:gui` in
`config.nims`), so no console opens behind it and messages on stderr are not shown.

Without a file, the editor opens `*scratch*` with a dashboard shown over it: a
"Today" list of one-key commands, `j` today's journal entry, `t` capture a task, `a`
the agenda, `s` the shell, then up to 10 recent files labelled 1-9 and 0 (HOME shown
as `~`, long paths cut from the left). C-n / C-p / arrows move between entries,
Enter or an entry's label opens it
(a file that no longer exists is reported and the dashboard stays), q, C-g or Escape
close it to `*scratch*`, C-x C-f prompts for a file, F1 switches to the manual and
C-x C-c quits. `M-x dashboard` opens it and a key bound to `dashboard` also closes
it; none is bound by default. The list lives in `~/.darger-recent` (one absolute
UTF-8 path per line, newest first, at most 30, written atomically): every existing
file visited from the command line, C-x C-f or `find-file`, and every file saved, is
moved to the top. `*scratch*` is never recorded, and errors reading or writing the
list are ignored.

F1 (or `M-x help`) toggles the built-in manual (Japanese) outside prompts and
review. In it, navigation keys and C-v / M-v / PageDown / PageUp / C-l scroll; q,
Enter, Escape, C-g or F1 close it and C-x C-c quits. The edited buffer is never
touched.

UTF-8 files retain CRLF/LF on save; finding a nonexistent file creates an empty
buffer bound to that path. A UTF-8 BOM is kept as a file prefix, not an editable
character. Save writes a unique temporary file beside the target, checks and
flushes it, then replaces the target; on any failure the temporary file is removed,
the original stays intact and the buffer stays modified. Directory targets are
rejected. On Linux/macOS read-only files are refused, a symlink is written through
to its target, the file mode (and owner, when permitted) is kept, and `~` expands
in the find/write prompts.

Set `$env:DARGER_FONT = 'C:\path\to\monospace.ttf'` (POSIX:
`DARGER_FONT=/path/mono.ttf DARGER_FALLBACK_FONTS=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc ./darger`)
to choose fonts. Default primary: Iosevka Nerd Font Mono first on every OS
(`IosevkaNerdFontMono-ExtraLight.ttf`, then `-Light`, then `-Regular`; in
`/usr/share/fonts/TTF` and `~/.local/share/fonts` on Linux, the per-user and
`C:\Windows\Fonts` folders on Windows, `~/Library/Fonts` on macOS), then per-user
HackGen Console NF, Cascadia Mono, Consolas, Courier New (Windows), then DejaVu Sans
Mono, Liberation Mono, Noto Sans Mono, Adwaita Mono (Linux) and Menlo paths; on
Linux `fc-match monospace` is the last resort. `DARGER_FALLBACK_FONTS` accepts
TTF/OTF/TTC paths separated by `;` on every OS; by default the editor tries BIZ UD
Gothic, Yu Gothic, MS Gothic, Malgun Gothic, Segoe UI Emoji and Segoe UI Symbol on
Windows, and Noto Sans CJK, Noto Sans Symbols 2 and Hiragino elsewhere, plus
`fc-match` picks for Japanese and Korean on Linux. Colour emoji fonts (CBDT, sbix)
are unsupported. Unreadable fonts are skipped with a message on stderr. TTC files
use their first face. `~/.darger.el` can choose fonts too: `(set-font "path")`
makes the file the primary font (over `DARGER_FONT` and the defaults), keeping the
fallbacks, and `(set-fallback-fonts "path;path")` replaces the fallbacks; both
work at any time (M-: too), and a font that cannot be loaded leaves the current
fonts in place and reports `Cannot load font …` in the echo area.

Text is 16 pixels times the window DPI scale times the zoom, with aligned fallback
baselines. `DARGER_SCALE` (e.g. `2`) overrides the DPI scale; on Linux, when windy
reports 1.0 (X11 without `Xft.dpi`, XWayland), `GDK_SCALE` is used if set. F2 starts
a sticky zoom (like Emacs `hydra-zoom`): `g` zooms in (x1.1), `l` out, `0` resets,
and the keys repeat without F2 until another key leaves the zoom and runs normally
(C-g just leaves). The zoom stays within 50%..400% and the echo area shows it. Like
Emacs' `internal-border-width` 32, the text area, mode line and echo line are inset
by a 32-pixel-times-DPI-scale border (not zoomed) that shrinks in tiny windows.

The default colours are modus-vivendi (black background, as in Emacs'
modus-themes); `(load-theme "catppuccin")` switches to the previous Catppuccin
Mocha colours and `(load-theme "modus-vivendi")` back, at any time (M-: or
`~/.darger.el`). Unknown names report `No such theme: …`.

Syntax highlighting is built in (no external grammars or libraries, so it works the
same on Windows). The language comes from the file extension, case-insensitively,
or a `#!` line for Python, Ruby and shell scripts, and is shown in the mode line:
Nim (`.nim .nims .nimble`), GLSL (`.glsl .frag .vert .fs .vs`), Python (`.py .pyi`), Ruby (`.rb .rake`, Gemfile,
Rakefile), GDScript (`.gd`), JS/TS (`.js .mjs .ts .tsx .jsx`), C/C++ (`.c .h .cpp
.hpp .cc`), Rust (`.rs`), Go (`.go`), Shell (`.sh .bash .zsh`), Lisp (`.el .lisp .scm
.clj`, `.emacs`), JSON, TOML, YAML (`.yaml .yml`), Markdown (`.md .markdown`) and
Org (`.org`); anything else, and `*scratch*`, is Text. It is re-detected after
visiting or writing a file. Comments, strings, keywords, function and variable
names, types, constants/numbers and builtins take the theme's faces (for
modus-vivendi: fg-dim, blue-warmer, magenta-cooler, magenta, cyan, cyan-cooler,
blue-cooler and magenta-warmer, as in Emacs). The tokenizer is table-driven and
approximate: block comments, multi-line strings, Markdown fences and Org
`#+begin_src` blocks carry across lines, but there is no real parsing. The whole
buffer is re-highlighted after each change (a few ms for 3000 lines); the help,
dashboard and review overlays stay plain.

Like `show-paren-mode`, the bracket after point, or else the closing bracket before
it, is highlighted together with its partner: `()`, `[]`, `{}` and `（）「」『』【】`.
Brackets in strings and comments only pair with each other. Each kind is counted on
its own, so a mismatched `( [ ) ]` still pairs, and the search stops 5000 lines away.

File buffers and `*scratch*` show line numbers in a gutter on the left: right-aligned,
at least 3 digits wide, dim (the theme's `lineNo`) with the cursor's line bright
(`lineNoNow`), then 2 empty cells. The overlays (help, dashboard, buffer list, filer,
web page, RSS list, review) have none.

CJK and the supported emoji ranges occupy two cells; combining marks, variation
selectors, joiners and skin-tone modifiers occupy zero cells. U+2600..27BF stays
one cell like Emacs. Emoji use monochrome outlines without shaping: ZWJ sequences,
flags and keycaps render as their parts. Missing glyphs appear as hollow boxes.
File tabs display at eight-cell stops; Tab inserts spaces to the next four-cell
stop. Long lines scroll horizontally, keeping the entire cursor block visible.
IME composition appears inline with a highlighted background and moves the
displayed suffix right, without changing the buffer until text is committed.
Native IME works on Windows/macOS only: windy's X11 backend has no XIM, so
fcitx/ibus, dead keys and Compose do not work on Linux; use the built-in SKK
(C-\ or C-x C-j).

`C-` means Ctrl, `M-` means Alt; either left or right modifier works.

| Action | Keys |
| --- | --- |
| Character / line movement | C-f / C-b / C-n / C-p, arrows |
| Line start / end | C-a / C-e, Home / End |
| Words / indentation | M-f / M-b, M-m |
| Buffer start / end | M-< / M->, C-Home / C-End |
| Pages / recenter | C-v / M-v, PageDown / PageUp; C-l cycles center/top/bottom |
| Go to line | M-g g / M-g M-g |
| Jump to a matching line (consult-line) | M-g l |
| Language server: completion / hover | C-M-i (also automatic) / C-c h |
| Language server: definition / back / references | M-. / M-, / M-? |
| Language server: format the buffer | C-c = |
| Insert / delete | Enter / C-m / C-j, Tab / C-i, Backspace / C-h, C-d / Delete |
| Open line / transpose | C-o / C-t |
| Kill line / word / backward word | C-k / M-d / M-Backspace |
| Word upper / lower / capitalize | M-u / M-l / M-c |
| Toggle mark / exchange / select all | C-SPC or C-@ / C-x C-x / C-x h |
| Kill / copy region | C-w / M-w |
| Yank / rotate last yank | C-y / M-y |
| Undo | C-/, C-_ (Ctrl+Shift+Minus), C-x u |
| Find / save / save as / exit | C-x C-f / C-x C-s / C-x C-w / C-x C-c |
| Split window below / right | C-x 2 / C-x 3 |
| Other window / delete window / delete other windows | C-x o / C-x 0 / C-x 1 |
| Enlarge window / wider / narrower / balance | C-x ^ / C-x } / C-x { / C-x + |
| Buffer / file in the other window | C-x 4 b / C-x 4 f |
| Window in a direction (windmove) | C-c left / right / up / down |
| Incremental search forward / backward | C-s / C-r; repeat for next / previous |
| Cancel | C-g |
| SKK Japanese input on / off | C-\ or C-x C-j |
| Manual (help) on / off | F1 |
| Dashboard (recent files) on / off | M-x dashboard |
| Pull and rebuild from GitHub | M-x darger-update |
| Zoom in / out / reset (sticky) | F2 g / l / 0 |
| Open the init file `~/.darger.el` | C-c , |
| Web browser (eww) / RSS reader | C-c w / C-c r |
| GLSL buffer: shader apply / picture only / clear | C-c C-c / C-c C-o / C-c C-k |
| Shell buffer / interrupt / end-of-file | C-c s / C-c C-c / C-d |
| Claude Code: start or focus / toggle window / new session | C-c C c / C-c C t / C-c C n |
| Claude Code: send region / send file | C-c C r / C-c C f |
| Org: TODO / checkbox / new item | C-c C-t / C-c C-c / M-Enter |
| Org: promote / demote / move subtree up / down | M-Left / M-Right / M-Up / M-Down |
| Org: headline list / open link / timestamp | C-c C-j / C-c C-o / C-c . |
| Org: fold the headline / the whole file | TAB / Shift-TAB |
| Org: journal entry / capture | C-c j / C-c t |
| Org: image from Eagle by keyword / by folder | C-M-e / C-c e |
| Org: paste the clipboard image | C-M-y |
| org-roam: find / insert link / backlinks / today | C-c n f / C-c n i / C-c n l / C-c n d |
| org-roam: today's daily with a time entry | C-c n j |
| org-roam: capture a note / add a file tag | C-c n c / C-c n t |
| org-roam: graph in the browser | C-c n g |
| Understanding buffer (debt per branch) | C-c u |
| Grep the Org directory (consult-ripgrep) | C-c n s |
| Project: find file / switch project / project buffers | C-x p f / C-x p p / C-x p b |
| Ask the agent where (places with a preview) | C-c l |

Search ignores case for all-lowercase queries. Typing extends the current match; a
search that hits the buffer edge shows `Failing I-search`, and repeating C-s/C-r
then wraps (`Wrapped`). Repeats never overlap the current match; C-s/C-r with an
empty query reuses the last search. Backspace returns to the previous search state.
Enter accepts the match, any other command ends the search at the match and runs,
and C-g restores the original point. Prompts other than incremental search float in
a popup near the top of the window (M-g l's at the bottom; on the bottom line when
the window is too small); messages stay on the bottom line. Minibuffers support insertion, Backspace,
C-a/C-e/C-f/C-b, C-k, C-y, Enter and C-g; the Find/Write/Agent/buffer/line prompts
and incremental search also take C-\ or C-x C-j (any key bound to `skk-mode`) to toggle
SKK. Answer confirmation prompts with `y` or `n`, then Enter. Backspace and Delete
remove an active region without killing it. Killing/copying updates the clipboard;
C-y uses the clipboard when the 60-entry kill ring is empty. Undo keeps 200
snapshots and groups runs of non-whitespace self-inserts. Snapshot undo and
flattened edits favor small files.

## Review

A review shows the buffer with another version's changes as hunks, the way the
agent's edits are reviewed: removed lines in red, added in green, the current hunk
brighter. Keys: y takes the proposed version of the hunk, k keeps the buffer's,
u undoes the decision, n / p move, l lists the hunks (`3  -1 +2  [taken]  first
line`) to jump to one, a takes every pending hunk and finishes, A keeps every
pending one and finishes, w applies the decisions made so far and keeps reviewing
the rest, q or Enter applies the decisions (pending hunks stay as they are), C-g
cancels, ? lists the keys. Within a pending hunk, the k-th removed and added lines
are compared and the part that differs is highlighted brighter, like
diff-refine-hunk. The echo line names the source, the hunk and its `-removed
+added` line counts.

r asks the agent for a change to the current hunk: the instruction goes to
`agent-command` with that hunk and the whole proposal, and the agent's complete new
text replaces the proposal (decisions start over, the hunk position is kept), so a
review goes round review, feedback, new proposal without leaving the buffer;
`(review-request-changes "…")` does the same from Lisp. Besides the agent (C-c a),
these open a review:

- `M-x diff-buffer-with-file`: the buffer against its file on disk, so an agent's
  or another editor's write is merged hunk by hunk with your own edits. Saving over
  a file that changed on disk now offers `r` for the same review.
- `M-x vc-review`: the buffer against the file as committed (`git show HEAD:…`);
  taking a hunk reverts it to the committed version.
- `(review-file "other.txt")`, or `M-x review-file` with a prompt: the buffer against
  another file, like ediff-buffers.
- When a file changed on disk while its buffer has edits, the echo line says so once
  and offers that review; with `(setq auto-revert-review t)` the review opens by
  itself when that buffer is current and nothing else is open. Buffers without
  edits still follow the file.
- After an agent chat turn (C-c c), the files it changed under the chat's root are
  counted in the echo line, and `M-x agent-changes` lists them: Enter opens the file
  in a review against the buffer's own text when it differs from the disk, else
  against git HEAD, so an agent's edits across the project are gated the same way.

### Understanding ledger

Code taken from an agent without understanding it is a debt; the review keeps the
books. x asks the agent to explain the current hunk (what it changes, why, what to
watch out for, and the domain or technical terms it relies on as `- term ::
definition` items); the explanation shows in `*explain*` in the other window and
the hunk counts as understood. When a review of an agent's or the disk's changes
ends, every hunk taken becomes an Org entry in `understanding-ledger` (default
`~/.darger-understanding.org`, `nil` to disable): `* TODO file:line  taken without
explanation  :debt:project:` with the hunk as a diff block, or `* DONE … :understood:`
with the explanation, so the agenda and TODO tools track what is still to be
understood. `M-x understanding-debt` lists the open entries and Enter visits the
spot (`M-x understanding-ledger` opens the file). The terms from explanations
collect in `glossary-file` (default `~/.darger-glossary.org`, one `- term ::
definition` per line, existing terms kept) and `M-x glossary` looks one up.
X asks the agent a question of your own about the hunk (the explanation so far is
sent along); the answer joins the explanation in `*explain*` and in the ledger, so a
hunk can be understood through a short dialogue. U attests that you understand the
hunk without an explanation; it is recorded as DONE too. Nothing is ever demanded: the ledger is a self-kept account of the work
you still want to understand.

Entries carry the git branch (`:BRANCH:`, also a tag) and the file's last-change
commit (`:REV:`), so the debt is kept per branch: `M-x understanding-debt` lists the
current branch's open entries (`understanding-debt-all` every branch's).
`M-x branch-debt` turns the branch's own work into debt: the files changed since the
merge base with the base branch (`main`, `master` or `develop`, or
`understanding-base-branch`) that no DONE entry of this branch attests to at their
current commit, with their `+/-` counts and `(uncommitted)`; Enter opens the file
in a comparison read base to branch (removed lines are the base's, added ones
yours), where nothing is taken: x explains, X asks, U attests, and q records every
hunk (understood or not) in the ledger. Run it again and the attested files
are gone; before a merge it answers "what did I do here that I do not yet
understand?".

C-c u (`understanding`) opens the `*understanding*` buffer, the ledger as a view to
work from (a magit status for understanding debt): the branch against its base with
the files still to understand (`+n -m`, `(uncommitted)`) and the ones understood,
the open debt entries on the branch, and the glossary size. Enter on a file opens
the base comparison and the buffer comes back when it closes; Enter on a debt entry
goes to the spot; U marks a whole file understood; o opens the ledger file; g
rebuilds; q closes. The first time in a repository the buffer asks which branch to
understand the work against (local and remote-tracking branches, the usual main /
master / develop first) instead of silently comparing with master; the choice is
remembered per repository in `~/.darger-understanding-bases`, b changes it, and
`(setq understanding-base-branch "name")` fixes it for every repository. The popup lists (`understanding-debt`, `branch-debt`) stay for
quick jumps.

The review's keys are also commands (`review-take`, `review-keep`, `review-next`,
`review-previous`, `review-finish`, `review-explain-hunk`, `review-attest`), so an
init file or an agent can drive a review.

## Filer (Dired)

C-x d prompts for a directory, starting in the current file's directory (or the
working directory for scratch), and so does `M-x dired`; `(dired "path")` and
directory command-line arguments open the filer directly. In the
C-x d prompt Enter opens the directory typed so far, so C-x d Enter lists the
current one; Tab completes. In C-x C-f, Enter on a directory candidate keeps
descending as before, and only a directory with nothing to pick opens the filer.

The read-only overlay includes hidden files, with directories first and names
sorted case-insensitively. Rows show type (`d`, `l`, `-`), size, modification time
and name; directory names have a trailing `/` and are highlighted.

- n / C-n / down and p / C-p / up move between entries; C-v / M-v page,
  M-< / M-> jump to the first / last entry.
- Enter / f opens a file or enters a directory; ^ goes to the parent and selects
  the directory just left. g refreshes, retaining the selected name.
- + creates a directory (including parents); R renames or moves an entry,
  refusing an existing destination. Both use path-completing prompts.
- D asks `Trash NAME? (y or n)`; y uses the Windows Recycle Bin or Linux
  `gio trash`. Errors are shown in the echo area; there is no permanent-delete
  fallback. Trash is unsupported on other platforms.
- q / C-g / Escape closes the filer. C-g / Escape cancels a create/rename prompt
  and returns to the listing.

## Shell

C-c s (`M-x shell`) opens `*shell*`, a comint-style shell buffer (macOS / Linux):
`shell-file-name` (default `$SHELL`, else `/bin/sh`) runs on a pseudo-terminal in the
current file's directory with `TERM=dumb`, `INSIDE_DARGER=1` and `PAGER=cat`. Its
output, with escape sequences, carriage returns and backspaces applied, fills the top
of the buffer in the eight ANSI foreground colours (`ESC[31m` … `ESC[37m`, bright
`90`-`97`, `38;5;n` for the first 16; other attributes and backgrounds are dropped,
true colour shows in the default colour) from the theme's `ansi` palette; what you
type after it is a command, sent with Enter (the pty does not echo, so the line stays
as typed and the output follows), C-c C-c interrupts (`SIGINT`), and C-d at an empty
command sends end-of-file. The process learns the size of the window showing
`*shell*` (`$COLUMNS`, `$LINES`) and follows splits, resizes and zooms. The output
keeps about 400 KB. The buffer never needs saving; killing it, or quitting, hangs
the shell up, and C-c s after the shell exited (`Process shell finished`) starts a
new one.

`M-x term` is the other kind of terminal, like Emacs' `term` in char mode: `*terminal*`
shows a real screen (`src/termscreen.nim`: cursor addressing, erasing, scrolling
regions, the alternate screen, colours, with the lines that scrolled off above it) of
the size of its window, running the shell, or `(term "command args")` that program,
with `TERM=xterm-256color`, so full-screen programs such as `claude`, `top` or `vim`
work. Every key goes to the program as a terminal would send it (Enter, arrows,
function keys, C-a … C-z, M-x as ESC x, Escape, Shift-Tab), and typed characters
too, so SKK is out of the way there; only the editor's prefixes C-x and C-c (and M-x,
M-:, C-g) stay with darger, so C-x o, C-x b and C-c s still work, and C-c C-c sends
a C-c to the program. C-c C-j (`term-line-mode`) switches to line mode as in Emacs
term: the buffer is ordinary text, so every editing key and SKK work and the
scrollback can be searched and copied; what is typed after the screen's text is kept
across new output and Enter sends it to the program (which echoes it). C-c C-k
(`term-char-mode`) gives the keys back to the program, dropping unsent input; the
mode line shows `[Line]` or `[Char]`, and `(term-send-input)` sends the typed
input from Lisp. An init file that opens a file or a terminal is no longer covered
by the dashboard. The buffer's cursor is the terminal's; wide (CJK) runes take two
cells; the eight ANSI colours show as foreground and background, underline as an
underline, inverse video by swapping the two (bold is recorded but drawn as regular
text). The terminal has no line-number gutter, so the program owns every column of
its window. A program that asks for mouse reports (`?1000`, `?1002`, `?1003`, SGR
`?1006`) gets clicks, releases and wheel notches on its cells instead of darger's
cursor placement and scrolling; on the alternate screen without reports, the wheel
sends arrow keys, as terminals do for `less` or `vim`. Killing the buffer or quitting
hangs the program up.

Claude Code runs in such a terminal with the bindings of the user's Emacs setup:
C-c C c (`claude-code`) starts `claude-command` (default `claude`) in the project root
(the nearest `.git` above the file) in `*claude-code: <project>*`, shown in a window on
the right (splitting when there is one window) and selected, or just goes there when
it already runs; C-c C t (`claude-code-toggle`) hides that window or shows it again;
C-c C n (`claude-code-new`) kills the session and starts a fresh one; C-c C r
(`claude-code-send-region`) pastes the region into it (bracketed paste, so its newlines
do not submit) and presses Enter; C-c C f (`claude-code-send-file`) sends
`このファイルを見てください: <path relative to the project>` and Enter.

## Background shader

A GLSL fragment shader can run under the text, as the NeoEmacs frame shader did:
`(background-shader "~/.emacs.d/bg-shader.glsl")` in `~/.darger.el` or at M-:
compiles the file and draws it over the whole window every frame, with the theme's
background laid over it at `background-shader-dim` opacity (default `0.6`; `0` shows
the picture alone). The file is either Shadertoy-style, a `mainImage(out vec4
fragColor, in vec2 fragCoord)` with `iResolution`, `iTime`, `iMouse` and `iFrame`
available, or a whole `#version 410 core` fragment shader with its own `main` and
`out`. In a GLSL buffer (`.glsl .frag .vert .fs .vs`, highlighted) C-c C-c applies
the buffer's text, C-c C-o toggles between the picture alone (no text, mode lines or
echo line, only the title bar; keys still work, so C-c C-o brings the text back) and
the dimmed background, and C-c C-k clears it; `M-x background-shader` (the buffer),
`background-shader-toggle` and `background-shader-clear` do the same anywhere.
Saving the applied file, or changing it on disk, re-applies it, so a shader can be
written while it runs. A compile error leaves the previous shader running and puts
GL's log, with the file's line numbers, in the echo line and a `*shader*` buffer
(C-x b). While a shader runs darger redraws every frame instead of only on input.
`shaders/` holds three samples to start from: `gradient.glsl`, `plasma.glsl` and
`stars.glsl`.

## Web browser (eww)

C-c w (`eww`) prompts `URL or search: `. A URL is loaded as typed; a word with a dot
(`example.com`) gets `https://`; anything else is searched with `eww-search-prefix`
(default DuckDuckGo's HTML version). Enter with an empty prompt reopens the last page.
`(eww "url")` and `M-x eww` do the same from Lisp; C-c w on a page closes it.

Pages are downloaded with `fetch-command` (default
`curl -sSL --max-time 30 --max-redirs 10 --compressed -A darger/0.1`; curl is part of
Windows 10/11, macOS and nearly every Linux) in the background, so the editor stays
responsive and `Loading url 0:03  C-g:cancel` ticks in the echo line. The body goes to
a temporary file, not a pipe; downloads stop at 20 MB. There is no cookie jar, JavaScript,
form submission or image display.

The page is laid out by a built-in tolerant HTML tokenizer (no external libraries):
paragraphs, headings (coloured like function names), lists (`•`, `1.`), `<pre>` kept
verbatim, block quotes indented, tables as rows with two spaces between cells, images as
`[alt]`, `<hr>` as a rule, scripts and styles dropped. Text wraps to the window width
(at most 100 cells) at spaces and between CJK characters, and is laid out again when the
window or zoom changes. Links are blue (the string face). The first row shows the URL;
the mode line shows the `<title>`. The charset comes from the `Content-Type` header, a
BOM, `<meta charset>` or the XML declaration (Shift_JIS, EUC-JP, ISO-2022-JP, GBK, Big5,
EUC-KR, Windows-125x ... via the OS converters); invalid bytes become U+FFFD. A feed URL
(RSS/Atom) is shown as a list of its entries; `text/plain` and JSON appear as is; other
types (images, PDF) are not shown (`&` opens them outside). An HTTP error page is shown
with `HTTP 404` in the echo line.

- C-n / C-p / n / p / arrows move by line; C-f / C-b within it; C-v / M-v / SPC /
  Backspace page; M-< / M-> jump to the top / bottom; C-l recenters.
- Tab / Shift-Tab move to the next / previous link. Enter / f follows the link under
  the cursor, or else the first link on the cursor's line.
- l / r go back / forward (pages are fetched again, the cursor line is kept);
  g reloads; G prompts for another URL or search.
- & opens the link at point (else the page) in the system browser; w copies that URL
  to the kill ring and clipboard; v opens the raw HTML in a `*web source*` buffer.
- q / Escape / C-g close the page (C-g first cancels a download); F1 opens the manual;
  C-x C-c quits. The page stays and C-c w Enter brings it back.

## RSS

C-c r (`rss`) opens the reader, an elfeed-style list of every subscription's entries,
newest first: `date  feed  title`, with read entries dimmed. Subscriptions come from
`~/.darger-feeds` (one URL per line, optionally followed by a title; `#` comments)
and from `(rss-feed "url" ["title"])` in `~/.darger.el`. The first opening fetches
every feed with `fetch-command`, up to all of them at once; the list fills in as they
arrive and the header shows `fetching 3/7`, then `12 new` or `up to date` and the
first failure (`host: HTTP 404`, `not a feed`, ...). A site URL whose page advertises
its feed (`<link rel=alternate type=application/rss+xml>`) is followed once. RSS 2.0,
Atom and RSS 1.0 (RDF) are parsed with the standard library's tolerant XML parser:
title, link, guid/id, pubDate/published/updated/dc:date, author/dc:creator, and
`content:encoded` (else the description/summary) as HTML, including Atom XHTML
content. Entries are not cached on disk: each session fetches the feeds again.

- n / p / C-n / C-p / arrows move; C-v / M-v / SPC / Backspace page; M-< / M->.
- Enter / f marks the entry read and shows it with the web viewer: the title links to
  the article, then feed, date and author, then the body. Links inside work as on any
  page; q (or l with no history) returns to the list.
- & / b open the article in the system browser; w copies its URL.
- r / u mark the entry read / unread (r also moves down); R marks every listed entry
  read. Read keys (guid, else link) are kept in `~/.darger-rss-read`, the newest 5000.
- g fetches every feed again. a prompts for a feed URL, appends it to `~/.darger-feeds`
  and fetches it. s filters the list orderless-style on feed and title (empty resets).
- q / Escape / C-g close the list (fetches continue; `RSS: 3 new (C-c r)` is echoed
  when they finish). F1 opens the manual; C-x C-c quits.

## Windows

Like Emacs, the frame can show several windows at once: C-x 2 (`split-window-below`)
and C-x 3 (`split-window-right`) split the selected window in two, both showing its
buffer at the same place; C-x o (`other-window`) selects the next one (left to right,
top to bottom, wrapping), a mouse click selects the one under it, C-x 0
(`delete-window`) removes the selected window and gives its space to its neighbour,
and C-x 1 (`delete-other-windows`) keeps only the selected one. C-x ^
(`enlarge-window`, `shrink-window` by M-x) gives the selected window a row more from
the window above or below it, C-x } / C-x { (`enlarge-window-horizontally` /
`shrink-window-horizontally`) a column more or less from the window beside it, and
C-x + (`balance-windows`) shares every split by the number of windows on each side.
C-x 4 b and C-x 4 f (`switch-to-buffer-other-window`, `find-file-other-window`) ask
for a buffer or a file and show it in the next window, splitting when there is only
one. C-c left / right / up / down (`windmove-left` …) select the window in that
direction from the cursor, as windmove does. Each window has its
own buffer, point and scroll (a buffer shown in two windows has a point in each),
and its own mode line; the selected window's is bright, the others dimmed, and a `│`
column separates side-by-side windows. A split is refused when a half would be
smaller than 3 rows or 10 columns. The selected window is the one every command,
prompt, overlay (dired, eww, the manual, a review) and the cursor box act in; the
others just show their buffer with its highlighting and folds. Killing a buffer
shown in another window puts the most recently used buffer there. The prompt popup
and the echo line belong to the frame, not to a window.

## Buffers

Every file opens in its own buffer; the other buffers keep their text, point, undo,
scroll position and language. Every command-line argument is opened and the first
is shown (one that fails to load is reported in the echo area and skipped), next
to the initial `*scratch*`. Visiting a file that is already open (C-x C-f,
`find-file`, the dashboard, C-c ,) switches to its buffer and keeps its edits.

- C-x b (`switch-to-buffer`) prompts for a buffer name; Enter alone switches to the
  most recently used other buffer (shown as the default), and an unknown name
  creates an empty buffer with that name. `(switch-to-buffer "name")` does the same
  from Lisp.
- C-x k (`kill-buffer`) prompts for a name (default: the current buffer) and asks
  `Buffer NAME modified; kill anyway? (y or n)` for a modified one. Killing the
  current buffer shows the previous one; killing the last leaves a fresh `*scratch*`.
- C-x right / C-x left (`next-buffer` / `previous-buffer`) cycle in opening order.
- C-x C-b (`list-buffers`) lists the buffers, most recently used first, as
  ` CRM Name  Path` rows (`.` marks the current buffer, `*` a modified one). C-n /
  C-p / n / p move, Enter switches, k kills the buffer on the line (asking y/n
  inline when it is modified), q, C-g or Escape close the list.

Names follow Emacs: a file's name is its basename; buffers sharing one get their
parent directory appended (`darger.nim<src>`, `darger.nim<tests>`, deepening to
`<a/src>` when needed), path-less buffers are `*scratch*`, `*scratch*<2>`, ... or
the name typed at C-x b. The mode line and window title show this name. C-x C-s
saves only the current buffer; C-x C-c asks before exiting when any buffer is
modified. The kill ring is shared: it follows you to the buffer you switch to.
Buffers follow their files (see the agent section above): an unedited buffer whose
file changed on disk is re-read, an edited one asks before saving over the change.

## Completion

The Find file / Write file (C-x C-f, C-x C-w), M-x, C-x b, C-x k, M-g l, M-g f and M-? prompts
list candidates under the input, vertico-style: up to 10 rows (fewer in a short
window, so some text stays visible), the selected one highlighted, and `N/M` (selected / matching) at the right of the prompt. Matching is
orderless-style: the input is split on spaces and every term must occur somewhere
in the candidate, in any order, ignoring case (Japanese included). Candidates that
start with the first term come first, otherwise the source order is kept.

- The first candidate is preselected. C-n / C-p (Down / Up) move and wrap around;
  C-v / M-v (PageDown / PageUp) move by 10.
- TAB inserts the selected candidate into the input; Enter accepts it. M-Enter
  accepts the input exactly as typed, e.g. to create `foo` next to an existing
  `foobar`, or a new buffer whose name is a prefix of another. With no matches,
  Enter uses the typed input too.
- Files: the candidates are the entries of the directory typed so far (up to the
  last `/`, `~` expanded), directories with a trailing `/`, sorted ignoring case;
  the rest of the input filters them. Dot-files appear once the rest starts with
  `.`. TAB or Enter on a directory descends into it instead of opening it.
- M-x lists every command: buffer commands, primitives callable without arguments
  and parameterless `defun`s from `~/.darger.el`. C-x b lists buffers most recently
  used first with the default first; C-x k starts with the current buffer.
- M-g l (`consult-line`) lists every line as `number  text` (text cut at 200
  characters) and filters on the text. Moving the selection previews that line,
  centred and highlighted; Enter stays there, C-g returns to where it started.
  Its list opens at the bottom of the window, above the mode line, so the
  previewed line stays visible above it.

## Searching files

`M-x consult-ripgrep` asks `Grep in <dir>: ` for a query and searches the project
(the nearest `.git` above the file, else its directory) with ripgrep (`rg --vimgrep
--smart-case`, 200 matches per file at most; `grep -rni` without rg), then lists
the matches as `path:line: text`, consult-style: typing narrows them, moving the
selection previews the spot, Enter jumps there (M-, comes back) and C-g returns.
`(consult-ripgrep "dir")` searches that directory, and C-c n s
(`consult-ripgrep-org`) the `org-roam-directory`, like the user's
`my/consult-ripgrep-org`. The search runs to completion before the list opens.

## Asking the agent where

C-c l (`agent-locate`) asks `agent-command` a question about the project ("where is
the retry logic?", "どこで日報のテンプレートを埋めている?") and opens the answer the way
consult-ripgrep opens matches: the agent is told to reply only with `path:line: note`
lines, those naming existing files become a list with a preview, Enter jumps (M-,
comes back), C-g returns. `(agent-locate "question")` does it from Lisp.
`M-x agent-references` lists every `path:line` the current buffer mentions, so the
places an agent cites in a chat transcript open the same way.

## Migemo

As in the user's Emacs, a romaji query also finds the Japanese it spells, in isearch
(C-s / C-r), consult-line, consult-ripgrep's narrowing and every completion prompt:
`kensaku` matches `けんさく`, `ケンサク` and the SKK dictionary's words read that way
(検索, 研削, …; a reading prefix counts, so `kens` already finds 検索), besides
`kensaku` itself. The match found sets the highlighted length. It needs no cmigemo:
the SKK dictionary and romaji rules are used, loaded on first use. On by default
(`(setq migemo-mode nil)` or M-x migemo-mode turns it off).

While a prompt is open, `(insert "text")` types into the minibuffer (a one-key
prompt takes the first character) and `(exit-minibuffer)` accepts it as Enter does,
so an init file or an agent can drive prompts.

## Projects

Like Emacs' project.el: C-x p f (`project-find-file`) lists every file of the
project, the nearest `.git` above the current file (tracked and untracked files
with `.gitignore` applied, through `git ls-files`) or else the file's directory
(hidden and build directories skipped), as relative paths to narrow and open. C-x p p
(`project-switch-project`) offers the projects visited before (kept in
`~/.darger-projects`, newest first; any directory can be typed) and then a file in the
chosen one; C-x p b (`project-buffers`) lists the open buffers under the project.

## Language servers

A file whose language has a server gets diagnostics from it over LSP. The server is
started the first time a buffer of that language is shown (one per language, rooted at
the nearest directory above the file holding `.git`, else the file's directory) and
stopped on exit. darger sends the whole text 150 ms after the last edit, and on save.

| Language | Server (the first one installed is used) |
| --- | --- |
| Nim | `nimlangserver` |
| Python | `pyright-langserver --stdio`, `pylsp` |
| Ruby | `solargraph stdio`, `ruby-lsp` |
| GDScript | `tcp://127.0.0.1:6005` (the Godot editor's server) |
| JS/TS | `typescript-language-server --stdio` |
| C/C++ | `clangd` |
| Rust | `rust-analyzer` |
| Go | `gopls` |
| Shell | `bash-language-server start` |
| JSON | `vscode-json-language-server --stdio` |
| YAML | `yaml-language-server --stdio` |
| Markdown | `marksman server` |

When none is found the echo area says so once, e.g. `No language server for C/C++
(clangd not found)`. Override a language's command (split on spaces; `tcp://host:port`
connects instead of spawning) in `~/.darger.el`:

```elisp
(lsp-server "C/C++" "clangd --log=error")
(lsp-server "Python" "")   ; no server for Python
```

- Diagnostics underline their range (error red, warning yellow, info blue, hint grey);
  the mode line shows ` E:n W:m` after the language name. Resting the cursor 500 ms on
  one shows `error: message` in the echo area when it is empty.
- M-g f (`consult-flymake`) lists them as `line:col  E|W|I|H  message` at the bottom of
  the window, sorted by line; moving the selection previews the spot, Enter stays
  there, C-g returns.
- M-x `lsp-restart` restarts the current buffer's server; M-x `lsp-log` echoes the path
  of its log, `darger-lsp-<language>-<pid>.log` in the temp directory (the server's
  stderr and messages, restarted past 4 MB and removed on exit).
- Completion (company-style): a popup under the cursor lists the server's candidates,
  each with a kind letter (f function, v variable, m method, c class/struct, k keyword,
  t type, s snippet, o other) and its detail. It opens by itself once you have typed
  two identifier characters and paused 300 ms, or right after one of the server's
  trigger characters (such as `.`); C-M-i (`completion-at-point`) asks at once.
  C-n / C-p (or the arrows) select, Enter / TAB insert (snippet placeholders are
  reduced to their text, and the item's extra edits, such as clangd's `#include`, go in
  too), C-g / Escape close, and typing narrows the list (asking the server again after
  a 300 ms pause when it said the list was cut short); any other key closes it and runs
  as usual. `(setq lsp-auto-complete nil)` in `~/.darger.el`
  keeps only C-M-i.
- C-c h (`lsp-hover`) shows the server's description of the symbol at point in a box
  under the cursor (up to 12 rows; C-n / C-p / C-v / M-v scroll a longer one); any
  other key closes it.
- M-. (`lsp-definition`) jumps to the definition, opening its file when needed, and
  M-, (`lsp-back`) returns; the last 50 origins are kept. M-x `lsp-type-definition` and
  `lsp-implementation` jump the same way. M-? (`lsp-references`) lists the references as
  `path:line: text` at the bottom of the window, grouped by file; moving the selection
  previews each one, Enter stays there (M-, comes back), C-g returns.
- C-c = (`lsp-format-buffer`) formats the buffer with the server (4-space indents);
  C-/ undoes the whole format in one step.
- A request the server leaves unanswered for 10 s is dropped with
  `LSP: <method> timed out`; the editor does not block waiting for an answer, and
  text a busy server has not read yet is queued (on Windows, written 4 KB at a time).

## Org and org-roam

In an Org buffer (`.org`), C-c C-t cycles the headline at or above point through
TODO, DONE and none; C-c C-c toggles a list item's `[ ]` / `[X]`; M-Enter adds a
headline or list item of the same kind below the line (numbers advance, a checkbox
comes empty); M-Left / M-Right promote and demote the headline; M-Up / M-Down swap
its subtree with the sibling above or below. C-c C-j lists the headlines like
M-g l (the preview follows the selection, C-g returns, M-, comes back after a
jump), C-c C-o follows the `[[link]]` at point (`id:` opens the note, `file:` and
plain paths open files, URLs go to the system browser, `*Headline` jumps), and
C-c . inserts `<2026-10-07 Wed>`.

`(setq org-todo-keywords '("TODO(t)" "NEXT(n)" "WAITING(w)" "|" "DONE(d)"))` sets
the keyword sequence (default `TODO` `DONE`): C-c C-t cycles through it and back to
none, the words after `|` count as done (the last word without a `|`) for the
agenda, and headlines colour them (active words red, yellow, blue, magenta, cyan in
turn, done words dimmed). With selection keys like `(t)`, C-c C-t instead asks
`TODO: [t] TODO [n] NEXT …` and takes one key, SPC for none, as Emacs' fast TODO
selection does.

C-c n c (`org-roam-capture`) asks for a title and makes the note in
`org-roam-directory` from `org-roam-capture-templates`, a list of
`(key description file head)`: with several templates one key picks one, as in
Emacs' capture. `file` and `head` may use `${title}`, `${slug}`, `${id}`,
`%<FORMAT>` and `%T`; the ID drawer is added when the head has none. For example
`(setq org-roam-capture-templates '(("z" "🌱 Zettelkasten" "%<%Y%m%d%H%M%S>.org"
"\n#+date: %T\n#+title:${title}\n#+filetags:\n") ("w" "📝 Wiki"
"%<%Y%m%d%H%M%S>.org" "#+title:📝${title}\n#+filetags: :WIKI:\n")))`. C-c n t
(`org-roam-tag-add`) adds a tag to the file's `#+filetags:` (the notes' existing
tags are offered; the line is created after `#+title:` when missing).

C-c n g (`org-roam-graph`) opens the notes and their `id:` links as a graph in the
browser (a page with its own force layout, no Graphviz needed): the current note
is red, hovering shows a note's title, tags and link count, drag moves, the wheel
zooms.

C-M-y (`org-insert-clipboard-image`) saves the clipboard's image as
`img/YYYY-mm-dd-HH-MM-SS.png` next to the file (the buffer must have one) and inserts
`[[file:img/…]]`, like the user's Emacs command, with no pngpaste needed.

Image links show inline, as org-display-inline-images: a line with `[[file:…png]]`
(also jpg, gif, webp, bmp; `~` and paths relative to the file work; WebP through macOS' sips) gets the picture
in the rows under it, scaled to the text width and at most `org-image-max-rows`
rows (default 15). A picture running off the pane's bottom is cropped, and the
wheel, C-v / M-v and recentring count its rows. Files are reloaded when they
change; a click on a picture puts point at the end of its line.
M-x org-toggle-inline-images hides and shows them.

Images from Eagle (eagle.cool), as the user's Emacs does: C-M-e
(`org-insert-eagle-image`) asks for a keyword (empty for the newest items) and lists
the matching images from Eagle's local API as `name.ext  [tags]`; C-c e
(`org-insert-eagle-image-from-folder`) lists Eagle's folders (`parent/child`) first.
Enter inserts a link to the library file itself, `[[file:~/…/Library.library/images/
ID.info/name.ext]]`, written with `~` so it resolves on every machine that keeps the
library under HOME. Eagle must be running (`eagle-api-base`, default
`http://localhost:41595`); nothing is copied. The highlighted item's thumbnail is
previewed at the top right while the list is open.

Folding works as in Emacs: TAB on a headline cycles FOLDED (the subtree hidden, the
headline ending in `...`), CHILDREN (its text and its child headlines, folded) and
SUBTREE; Shift-TAB cycles the whole file through OVERVIEW (top-level headlines only),
CONTENTS (every headline, no text) and SHOW ALL, and `#+startup: folded` (or
`overview`, `content`) opens the file that way. TAB elsewhere still indents. C-n / C-p,
C-v / M-v and C-l count only shown lines; a search, M-g g, a link or an edit that lands
in hidden text opens the folds down to it, keeping the sibling subtrees folded. Edits
above a fold move it; a folded headline that is deleted simply shows its text again.
`M-x org-cycle` and `org-shifttab` are the commands.

C-c j (`org-journal-new-entry`) keeps a journal like org-journal: today's file is
`org-journal-dir` / `org-journal-file-format` (defaults `~/org-journal`,
`%Y%m%d.org`), created with `org-journal-file-header` and a date headline
(`org-journal-date-prefix` + `org-journal-date-format`, defaults `* ` and
`%A, %d %B %Y`), then a time headline (`org-journal-time-prefix` +
`org-journal-time-format`, defaults `** ` and `%R `) is added at the end with the
cursor after it. Before `org-extend-today-until` o'clock (default `"0"`) the entry
still belongs to yesterday. A new file gets the contents of
`org-journal-daily-template-file` (default none) under the date headline, so the
day's sections are there before the first entry, and an ID property drawer at the
top when `org-journal-add-id` is `t` (default `nil`), making the day an org-roam
node. With `org-journal-condition-prompt` `t` (default `nil`) a new entry asks
`体調 [1-5]` with one key: a digit puts that many `★` after the time and leaves the
cursor after them, any other key skips, as the user's Emacs hook does. The formats
take strftime's `%Y %y %m %d %e %H %M %S %R
%A %a %B %b %j %%`; under a Japanese locale (`LANG=ja_JP.UTF-8`) `%A` and `%B` give
`火曜日` and `10月`, as Emacs does. C-c t (`org-capture`) prompts `Capture: ` and
files the text, through `org-capture-template` (default `* TODO %?\n`; `%?` is the
text, `%t` / `%u` today's active / inactive timestamp, `%T` / `%U` with the time),
at the end of the subtree of `org-capture-headline` in `org-capture-file`
(defaults `""`, meaning the end of the file, and `~/org/inbox.org`), creating the
headline or the file when missing. An open buffer of that file is edited and
saved; otherwise the file is written directly, and you stay where you were.
`M-x org-agenda` reads `org-agenda-files` (a path, a list of paths, or directories of
`.org` files; default none) and lists, consult-style with a preview, what Emacs' day
agenda would show for today: TODO headlines scheduled today or earlier
(`Scheduled:` / `Sched. 3x:`), deadlines overdue or within 14 days (`Deadline:` /
`In 3 d.:` / `3 d. ago:`), headlines with today's timestamp, then the undated TODOs
(`TODO:`), each with its file's name; Enter goes to the headline (M-, comes back),
C-g returns. DONE items and headlines dated for other days are left out. Bind it
yourself, e.g. `(global-set-key "C-c a" 'org-agenda)` replaces the agent prompt.

org-roam notes are Org files under `org-roam-directory` (default `~/org-roam`,
`(setq org-roam-directory "~/notes")` in `~/.darger.el`) with an ID property drawer
and a `#+title:`; the directory is rescanned at each command, without a database.
C-c n f prompts for a title: Enter on a listed note opens it, and Enter on a new
title (or M-Enter to take the typed title while matches are listed) creates
`<timestamp>-<slug>.org` and opens it. C-c n i inserts `[[id:…][Title]]` at point
(an active region becomes the title and is replaced). C-c n l lists the notes
linking to the current one with the linking line, previewed like references.
C-c n d opens today's `daily/YYYY-MM-DD.org`, creating it; C-c n j
(`org-roam-dailies-capture-today`) opens it and adds a `* HH:MM ` headline at the end. `M-x org-id-get-create`
gives any Org file an ID, making it a note.

## Architecture

`src/core.nim` is the editor: the buffer registry, the window and renderer, key
dispatch, prompts, overlays and the Lisp interpreter, plus the API everything else
plugs into. `src/darger.nim` only owns the window (title bar, mouse, keyboard
callbacks) and the main loop. Every feature is an extension under `src/ext/`, a
Nim module that imports `core` and registers itself when imported from
`darger.nim`: `org` (Org and org-roam), `web` (eww), `rss`, `dired`, `help`,
`dash`, `blist`, `agent` (one-shot edits, review and chat), `selfupdate` and
`langserver`. The pure logic each one builds on (parsing, protocols, file work)
stays in its own module in `src/` with tests.

The API, in `core.nim` under "The extension API": `defineMode` registers a view (a
`Mode`: the buffer it shows, its faces, mode-line tag, echo-line message, key handler,
close and relayout procs); `definePrompt` registers a minibuffer prompt (a `Prompt`:
candidates, whether they preview positions or complete paths, which view it floats
over, and `onAccept`, which may keep the prompt open); `interp.defPrimitive` adds a
command for M-x and `global-set-key`; `defaults.add` supplies Lisp evaluated after
the built-in bindings and before `~/.darger.el`. Hooks: `tickHooks` (polled every
loop), `messageHooks` (echo-line overrides), `keyFilters`, `runeHooks`,
`insertHooks`, `imeHooks`, `escapeHooks`, `busyHooks`, `cancelHooks` (C-g),
`killHooks`, `saveHooks`, `modifiedIgnore`, `exitHooks`, `langHints`, and the
single providers `dirVisitor`, `marksHook`, `boxHook`, `modeLineHook`,
`startScreen`. Views reach other features through the keymap (`dispatch(full)`)
rather than by calling them, so an extension can be left out by removing its import.

## Init file

`~/.darger.el` is evaluated at startup after the default bindings, and again whenever
it changes on disk (checked twice a second), so saving it applies it at once: the
default bindings are restored first, so a `global-set-key`, `hydra` or `setq` dropped
from the file goes back to its default, while feeds, LSP servers and `defun`s already
added stay until restart. The echo line reports `Loaded ~/.darger.el` or the error, and
`No ~/.darger.el (C-c , creates it)` at every start without one;
`M-x load-init` reloads it by hand. C-c , opens it
(`(find-file "~/.darger.el")`, which switches to its buffer when it is already open). Besides `global-set-key`, `setq`, `message`,
`insert` and `command`, it can use `(load-theme "catppuccin")`, `(set-font "path")`,
`(set-fallback-fonts "path;path")`, `(find-file "path")`
(`~` expands), `save-buffer`, `kill-emacs`, `skk-mode`, `zoom-in` / `zoom-out` /
`zoom-reset`, `(eww "url")`, `(background-shader "path")`, `(setq background-shader-dim 0.6)`,
`(rss-feed "url")`, `(setq fetch-command "...")`, `(setq eww-search-prefix "...")`, and
`(ignore-errors ...)`, which evaluates its body and gives `nil` instead of stopping the
file when it fails, and `(hydra "PREFIX" "hint")`, which makes a one-key prefix sticky: after a bound
`PREFIX x` command the prefix stays active and the hint shows in the echo area, as
the default `(hydra "f2" "zoom  g:in  l:out  0:reset")`.

```elisp
(global-set-key "f2 r" 'zoom-reset)
(load-theme "catppuccin")
```

## SKK input

C-\ or C-x C-j (`skk-mode`) toggles a built-in DDSKK-style SKK (turning it off
commits anything in progress). The mode line shows `[かな]`, `[カナ]` or `[SKK]`
(latin); nothing when off. Pending romaji, `▽reading` and `▼candidate` are drawn
inline at the cursor like an IME composition; the buffer changes only when kana
complete or a conversion is committed, through the normal insert path (a commit is
one undo step).

- Direct input follows the DDSKK romaji rules: `nn`/`n'` → ん, a doubled consonant →
  っ, `x` + vowel / `xtu` / `xya` / `xwa` for small kana, `-` ー, `~` 〜, `! ? : [ ]`
  full-width, `z/ z. z, z- zh zj zk zl z[ z]` → `・ … ‥ 〜 ← ↓ ↑ → 『 』`. `.`, `,`,
  digits and space stay ASCII. `(` inserts （） with the cursor inside; `)` steps
  over a following ）. `q` toggles katakana, `l` switches to latin, `L` to full-width
  ASCII (`[全英]`: `Abc 1` → `Ａｂｃ　１`), C-j returns to hiragana from either.
- ▽: an uppercase letter or `;` starts a reading; a second uppercase letter (or `;`)
  marks the okurigana (`OkuRi` → 送り, converted as soon as the kana is complete).
  SPC converts, Enter / C-j commits the reading without a newline, `q` commits it as
  katakana, Backspace deletes the last kana, C-g cancels. Enter, Backspace and Tab
  mean the same as C-m, C-h and C-i here. `(setq skk-egg-like-newline nil)` makes
  Enter in ▽ / ▼ commit and then insert the newline, as DDSKK does by default; the
  default `t` only commits. Tab completes the reading like skk-comp:
  it becomes the next dictionary key starting with what was typed (user dictionary
  entries first, then the main one, alphabetically; okuri-ari keys skipped), another
  Tab the next, and after the last Tab brings the typed text back; typing continues
  from the completion and SPC converts it.
- `/` starts an abbrev reading (`▽` typed as ASCII, no romaji; uppercase and `;` are
  literal): `/dog` SPC looks up the key `dog`, so `dog /犬/` in the user dictionary
  gives 犬, Enter commits the ASCII as typed, Tab completes among ASCII keys, and a
  miss registers under the ASCII key. Kana input resumes afterwards.
- ▼: SPC / `x` step through candidates 1-4, and C-n / C-p (or the arrows) one
  candidate at a time anywhere; from the 5th the current page of seven hangs from
  the cursor as a list with its pick keys `a s d f j k l` and the selected one
  highlighted (in a prompt, as `A:… ▶S:… D:…  [残り N]` on the echo line). SPC / `x`
  change page, C-p before the first candidate returns to ▽. Enter / C-j commits,
  Backspace or C-g returns to ▽, and any other kana key commits and continues.
- A reading with no candidates, or SPC past the last one, opens DDSKK's registration
  prompt `辞書登録 「よみ」: ` (SKK works in it too): Enter with a word puts it in the
  user dictionary and inserts it (with the okurigana), Enter alone or C-g returns to
  ▽ with the reading. Inside another prompt the reading just comes back as ▽ with
  `No candidates for …`.
- Any other command (C-a, C-f, M-x, C-x …) first commits what SKK has in progress, as
  DDSKK does, so ▽ / ▼ never stays behind at the old cursor. SKK stays out of an
  active Windows IME composition. Find-file, write-file, agent, buffer, consult-line
  and isearch minibuffers use SKK as well; y/n and goto-line prompts bypass it.
- The main dictionary is `$env:DARGER_SKK_JISYO`, else the first existing of
  `~/Dropbox/.emacs.d/skk-get-jisyo/SKK-JISYO.L`, `~/.emacs.d/skk-get-jisyo/SKK-JISYO.L`,
  `~/.skk/SKK-JISYO.L` and `/usr/share/skk/SKK-JISYO.L` (EUC-JP when line 1 has a
  `coding: euc-jp` cookie, UTF-8 otherwise). It loads on the first toggle and
  reports `SKK: N entries loaded (t ms)`; without it kana input still works and
  conversion says `No dictionary`.
- Each commit from ▼ moves the choice to the front and rewrites `~/.darger-skk-jisyo`
  (UTF-8 SKK format, searched first, keys sorted rather than by recency). Emacs'
  `~/.skk-jisyo` is never touched.
- Dictionary candidates keep their annotations (`仮名;note`): ▼ and kakutei use the word,
  the candidate box shows the note beside it. `(concat "a\057b")` candidates (SKK's way
  to write `/` or `;`) are evaluated, so `a/b` is shown and inserted; a registered word
  containing `/` or `;` is written that way, and `word;note` registers with its note.
- Not implemented: `l`-prefixed small kana (`l` is the latin-mode key, as in DDSKK: use
  `x`) and okuri `[…]` blocks.

Windy 0.5.0 forwards repeated Windows WM_KEYDOWN events to `onButtonPress`, so
held command keys use native OS repeat. `onRune` handles printable text only.

In a sandbox where Nimble cannot update `~/.nimble/nimbledata2.json`, copy the
installed `pkgs2` directory and `*.json` files from `~/.nimble` into
`nimcache/nimble`, then use:

```powershell
nimble --nimbleDir:nimcache/nimble --offline build -d:release
```

All compiler cache files remain under the project `nimcache/` directory.
