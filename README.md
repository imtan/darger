# darger

A small GPU text editor for Windows 11 and Linux, built with Nim 2.2.10+. Windy owns
the window, OpenGL context, input and clipboard; Pixie rasterizes glyphs into Boxy's
GPU atlas. macOS compiles but is untested; `agent-command` can use
`claude -p --output-format text` unchanged.

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
```

Nimble older than 0.24 (e.g. the 0.22.x bundled with Nim 2.2.10) fails with
`cannot open file: opengl`; use the `nim c` line instead.

On Linux windy uses X11 + GLX only, so Wayland sessions need XWayland. libX11,
libXext, libXcursor and libGL.so.1 are loaded with dlopen at startup (`ldd` does not
list them): Arch `libx11 libxext libxcursor libglvnd mesa xorg-xwayland`, Debian
`libx11-6 libxext6 libxcursor1 libgl1`. `config.nims` swaps in patched copies of
windy 0.5.0's X11 backend from `patches/windy` via `patchFile` on Linux only (see
`patches/windy/README.md`); windy stays pinned to 0.5.0.

The window has no title bar or frame. Dragging anywhere with the left button moves
it, dragging its bottom right corner (32 px) resizes it, and a double click toggles
maximized, which covers the whole screen including the taskbar. The mouse does
nothing else. C-x C-c quits. On Windows the build is a GUI program (`--app:gui` in
`config.nims`), so no console opens behind it and messages on stderr are not shown.

Without a file, the editor opens `*scratch*` with a dashboard shown over it: up to
12 recent files labelled 1-9 and a-c (HOME shown as `~`, long paths cut from the
left). C-n / C-p / arrows move between entries, Enter or an entry's label opens it
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
use their first face.

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
Nim (`.nim .nims .nimble`), Python (`.py .pyi`), Ruby (`.rb .rake`, Gemfile,
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
review) have none.

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
| Incremental search forward / backward | C-s / C-r; repeat for next / previous |
| Cancel | C-g |
| SKK Japanese input on / off | C-\ or C-x C-j |
| Manual (help) on / off | F1 |
| Dashboard (recent files) on / off | M-x dashboard |
| Zoom in / out / reset (sticky) | F2 g / l / 0 |
| Open the init file `~/.darger.el` | C-c , |

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

## Init file

`~/.darger.el` is evaluated at startup after the default bindings; C-c , opens it
(`(find-file "~/.darger.el")`, which switches to its buffer when it is already open). Besides `global-set-key`, `setq`, `message`,
`insert` and `command`, it can use `(load-theme "catppuccin")`, `(find-file "path")`
(`~` expands), `skk-mode`, `zoom-in` / `zoom-out` / `zoom-reset`, and
`(hydra "PREFIX" "hint")`, which makes a one-key prefix sticky: after a bound
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
  over a following ）. `q` toggles katakana, `l` switches to latin, C-j returns to
  hiragana.
- ▽: an uppercase letter or `;` starts a reading; a second uppercase letter (or `;`)
  marks the okurigana (`OkuRi` → 送り, converted as soon as the kana is complete).
  SPC converts, Enter / C-j commits the reading without a newline, `q` commits it as
  katakana, Backspace deletes the last kana, C-g cancels.
- ▼: SPC / `x` step through candidates 1-4; from the 5th, pages of seven appear in
  the echo area (`A:… S:… D:… F:… J:… K:… L:…  [残り N]`): pick with `a s d f j k l`,
  SPC / `x` change page. Enter / C-j commits, Backspace or C-g returns to ▽, and any
  other kana key commits and continues.
- Other Ctrl/Alt chords run their normal commands. SKK stays out of an active Windows
  IME composition. Find-file, write-file, agent, buffer, consult-line and isearch
  minibuffers use SKK as well; y/n and goto-line prompts bypass it.
- The main dictionary is `$env:DARGER_SKK_JISYO`, else the first existing of
  `~/Dropbox/.emacs.d/skk-get-jisyo/SKK-JISYO.L`, `~/.emacs.d/skk-get-jisyo/SKK-JISYO.L`,
  `~/.skk/SKK-JISYO.L` and `/usr/share/skk/SKK-JISYO.L` (EUC-JP when line 1 has a
  `coding: euc-jp` cookie, UTF-8 otherwise). It loads on the first toggle and
  reports `SKK: N entries loaded (t ms)`; without it kana input still works and
  conversion says `No dictionary`.
- Each commit from ▼ moves the choice to the front and rewrites `~/.darger-skk-jisyo`
  (UTF-8 SKK format, searched first, keys sorted rather than by recency). Emacs'
  `~/.skk-jisyo` is never touched.
- Not implemented: zenkaku latin (`L`), abbrev (`/`), Tab completion, dictionary
  registration (a miss says `No candidates for …` and stays in ▽), `l`-prefixed
  small kana (use `x`), okuri `[…]` blocks and `(concat …)` evaluation.

Windy 0.5.0 forwards repeated Windows WM_KEYDOWN events to `onButtonPress`, so
held command keys use native OS repeat. `onRune` handles printable text only.

In a sandbox where Nimble cannot update `~/.nimble/nimbledata2.json`, copy the
installed `pkgs2` directory and `*.json` files from `~/.nimble` into
`nimcache/nimble`, then use:

```powershell
nimble --nimbleDir:nimcache/nimble --offline build -d:release
```

All compiler cache files remain under the project `nimcache/` directory.
