# darger

A small GPU text editor for Nim 2.2.12 and Windows 11. Windy owns the window,
OpenGL context, input and clipboard; Pixie rasterizes glyphs into Boxy's GPU atlas.

```powershell
nimble build -d:release
.\darger.exe [file]
nim r tests/tbuffer.nim
```

Without a file, the editor opens `*scratch*`. UTF-8 files retain CRLF/LF on save;
finding a nonexistent file creates an empty buffer bound to that path.
A UTF-8 BOM is kept as a file prefix, not an editable character. Save writes a
unique temporary file beside the target, checks and flushes it, then replaces
the target; on any failure the temporary file is removed, the original stays
intact and the buffer stays modified. Directory targets are rejected.

Set `$env:DARGER_FONT = 'C:\path\to\monospace.ttf'` to choose a font. Defaults:
per-user HackGen Console NF, Cascadia Mono, Consolas, Courier New, then common
DejaVu Sans Mono / Menlo paths. `DARGER_FALLBACK_FONTS` accepts semicolon-separated
TTF/OTF/TTC paths; by default the editor tries BIZ UD Gothic, Yu Gothic, MS Gothic,
Malgun Gothic, Segoe UI Emoji and Segoe UI Symbol. Unreadable fonts are skipped
with a message on stderr. TTC files use their first face.

Text is 16 pixels times the window DPI scale, with aligned fallback baselines.
CJK and the supported emoji ranges occupy two cells; combining marks, variation
selectors, joiners and skin-tone modifiers occupy zero cells. U+2600..27BF stays
one cell like Emacs. Emoji use monochrome outlines without shaping: ZWJ sequences,
flags and keycaps render as their parts. Missing glyphs appear as hollow boxes.
File tabs display at eight-cell stops; Tab inserts spaces to the next four-cell
stop. Long lines scroll horizontally, keeping the entire cursor block visible.
IME composition appears inline with a highlighted background and moves the
displayed suffix right, without changing the buffer until text is committed.

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

Search ignores case for all-lowercase queries. Typing extends the current match;
a search that hits the buffer edge shows `Failing I-search`, and repeating C-s/C-r
then wraps (`Wrapped`). Repeats never overlap the current match; C-s/C-r with an
empty query reuses the last search. Backspace returns to the previous search state.
Enter accepts the match, any other command ends the search at the match and runs,
and C-g restores the original point. Minibuffers support insertion, Backspace,
C-a/C-e/C-f/C-b, C-k, C-y, Enter and C-g. Answer confirmation prompts with `y`
or `n`, then Enter. Killing/copying updates the clipboard; C-y uses the clipboard
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
