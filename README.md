# darger

A small GPU text editor for Windows 11 and Linux, built with Nim 2.2.10+. Windy owns
the window, OpenGL context, input and clipboard; Pixie rasterizes glyphs into Boxy's
GPU atlas. macOS compiles but is untested; `agent-command` can use
`claude -p --output-format text` unchanged.

```powershell
nimble build -d:release
.\darger.exe [file]
nim r tests/tbuffer.nim
```

```sh
nimble build -d:release       # or: nimble install -d && nim c -d:release --outdir:. src/darger.nim
./darger [file]
nim r tests/tbuffer.nim
nim r tests/tfileio.nim   # POSIX save behaviour
```

Nimble older than 0.24 (e.g. the 0.22.x bundled with Nim 2.2.10) fails with
`cannot open file: opengl`; use the `nim c` line instead.

On Linux windy uses X11 + GLX only, so Wayland sessions need XWayland. libX11,
libXext, libXcursor and libGL.so.1 are loaded with dlopen at startup (`ldd` does not
list them): Arch `libx11 libxext libxcursor libglvnd mesa xorg-xwayland`, Debian
`libx11-6 libxext6 libxcursor1 libgl1`. `config.nims` swaps in patched copies of
windy 0.5.0's X11 backend from `patches/windy` via `patchFile` on Linux only (see
`patches/windy/README.md`); windy stays pinned to 0.5.0.

Without a file, the editor opens `*scratch*` with the built-in manual (Japanese)
shown over it. F1 (or `M-x help`) toggles the manual outside prompts and review. In it,
navigation keys and C-v / M-v / PageDown / PageUp / C-l scroll; q, Enter, Escape,
C-g or F1 close it and C-x C-c quits. The edited buffer is never touched.

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
to choose fonts. Default primary: per-user HackGen Console NF, Cascadia Mono,
Consolas, Courier New (Windows), then DejaVu Sans Mono, Liberation Mono, Noto Sans
Mono, Adwaita Mono (Linux) and Menlo paths; on Linux `fc-match monospace` is the last
resort. `DARGER_FALLBACK_FONTS` accepts TTF/OTF/TTC paths separated by `;` on every
OS; by default the editor tries BIZ UD Gothic, Yu Gothic, MS Gothic, Malgun Gothic,
Segoe UI Emoji and Segoe UI Symbol on Windows, and Noto Sans CJK, Noto Sans Symbols 2
and Hiragino elsewhere, plus `fc-match` picks for Japanese and Korean on Linux.
Colour emoji fonts (CBDT, sbix) are unsupported. Unreadable fonts are skipped with a
message on stderr. TTC files use their first face.

Text is 16 pixels times the window DPI scale, with aligned fallback baselines.
`DARGER_SCALE` (e.g. `2`) overrides the scale; on Linux, when windy reports 1.0
(X11 without `Xft.dpi`, XWayland), `GDK_SCALE` is used if set.
CJK and the supported emoji ranges occupy two cells; combining marks, variation
selectors, joiners and skin-tone modifiers occupy zero cells. U+2600..27BF stays
one cell like Emacs. Emoji use monochrome outlines without shaping: ZWJ sequences,
flags and keycaps render as their parts. Missing glyphs appear as hollow boxes.
File tabs display at eight-cell stops; Tab inserts spaces to the next four-cell
stop. Long lines scroll horizontally, keeping the entire cursor block visible.
IME composition appears inline with a highlighted background and moves the
displayed suffix right, without changing the buffer until text is committed.
Native IME works on Windows/macOS only: windy's X11 backend has no XIM, so
fcitx/ibus, dead keys and Compose do not work on Linux; use the built-in SKK (C-x C-j).

`C-` means Ctrl, `M-` means Alt; either left or right modifier works.

| Action | Keys |
| --- | --- |
| Character / line movement | C-f / C-b / C-n / C-p, arrows |
| Line start / end | C-a / C-e, Home / End |
| Words / indentation | M-f / M-b, M-m |
| Buffer start / end | M-< / M->, C-Home / C-End |
| Pages / recenter | C-v / M-v, PageDown / PageUp; C-l cycles center/top/bottom |
| Go to line | M-g g / M-g M-g |
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
| SKK Japanese input on / off | C-x C-j |
| Manual (help) on / off | F1 |

Search ignores case for all-lowercase queries. Typing extends the current match;
a search that hits the buffer edge shows `Failing I-search`, and repeating C-s/C-r
then wraps (`Wrapped`). Repeats never overlap the current match; C-s/C-r with an
empty query reuses the last search. Backspace returns to the previous search state.
Enter accepts the match, any other command ends the search at the match and runs,
and C-g restores the original point. Prompts other than incremental search float
in a popup near the top of the window (on the bottom line when the window is too
small); messages stay on the bottom line. Minibuffers support insertion,
Backspace, C-a/C-e/C-f/C-b, C-k, C-y, Enter and C-g; the Find/Write/Agent prompts
and incremental search also take C-x C-j to toggle SKK. Answer confirmation
prompts with `y` or `n`, then Enter. Backspace and Delete remove an active region
without killing it.
Killing/copying updates the clipboard; C-y uses the clipboard
when the 60-entry kill ring is empty. Undo keeps 200 snapshots and groups runs of
non-whitespace self-inserts. Snapshot undo and flattened edits favor small files.

## SKK input

C-x C-j toggles a built-in DDSKK-style SKK (turning it off commits anything in
progress). The mode line shows `[かな]`, `[カナ]` or `[SKK]` (latin); nothing when off.
Pending romaji, `▽reading` and `▼candidate` are drawn inline at the cursor like an
IME composition; the buffer changes only when kana complete or a conversion is
committed, through the normal insert path (a commit is one undo step).

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
  IME composition. Find-file, write-file and isearch minibuffers use SKK as well;
  y/n and goto-line prompts bypass it.
- The main dictionary is `$env:DARGER_SKK_JISYO`, else the first existing of
  `~/Dropbox/.emacs.d/skk-get-jisyo/SKK-JISYO.L`, `~/.emacs.d/skk-get-jisyo/SKK-JISYO.L`,
  `~/.skk/SKK-JISYO.L` and `/usr/share/skk/SKK-JISYO.L` (EUC-JP when line 1 has a
  `coding: euc-jp` cookie, UTF-8 otherwise). It loads on the first C-x C-j and
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
