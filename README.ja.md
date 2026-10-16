# darger

Windows 11 と Linux 向けの小さな GPU テキストエディタです。Nim 2.2.10 以降でビルドします。
Windy がウィンドウ、OpenGL コンテキスト、入力、クリップボードを受け持ち、Pixie が
グリフをラスタライズして Boxy の GPU アトラスに載せます。macOS はコンパイルは通りますが
未検証です。`agent-command` は `claude -p --output-format text` をそのまま使えます。

C-c a (`agent-prompt`) は現在のファイルと指示を `agent-command` に送って一回限りの編集を
行い、diff レビューを開きます。C-g で中止します。C-c c (`agent-chat`) は代わりに
`Agent chat (<ルートディレクトリ名>): ` と尋ね、プロジェクトの最上位ディレクトリで複数ターンの
会話を行います。最上位とは `.git` を持つ最も近い祖先ディレクトリ、なければファイルの
ディレクトリです。チャットバッファからはそのチャットのルートを使い、パスを持たない他の
バッファからは作業ディレクトリから探し、見つからなければそのディレクトリを使います。

ルートごとにメモリ上のセッションと、`*agent <ルートディレクトリ名>*` という名前の Markdown
トランスクリプトがあり、C-x b で開けます。C-c c Enter をテキストなしで押すと、何も送らずに
既存のトランスクリプトを開きます。メッセージはそのまま stdin に渡され、返答は Markdown と
コードフェンスを保ちます。両コマンドを通じて同時に動くエージェントは一つだけです。C-g は
キャンセルを記録し、失敗はトランスクリプトに現れます。返答が来ても別のバッファから切り替わる
ことはありません。トランスクリプトを kill すると会話は忘れられ、保留中の返答も捨てられます。
トランスクリプトは保存を求めず、チャット履歴はディスクに保存されません。
`M-x agent-chat-new` は現在のルートのトランスクリプトを空にしてセッションをリセットします
(その会話が実行中なら拒否されます)。

チャットの返答はライブで表示され、ツール名と短い要約が Markdown の引用行として、プロセスの
実行中は末尾に `...` が付いて現れます。思考とツール結果は隠されます。完結した出力行だけが
表示されます。通常のプレーンテキストを返すエージェントコマンドも動作します。キャンセルや
失敗があっても、それまでに受け取った出力は残ります。カーソルは最初は最下部にあり、最終行に
いる間は新しい出力を追いかけます。上に移動すれば追従せずに読めます。更新は undo 履歴に
追加されません。チャットと一回限りのエージェントの両方で、経過時間 (`Agent running 1:23`)
がエコー行に表示され、チャットでは最新のツール活動も出ます。

デフォルト (`~/.darger.el` で上書きできます) は次の通りです。

```lisp
(setq agent-chat-command "claude -p --output-format stream-json --verbose --session-id {id}")
(setq agent-chat-resume-command "claude -p --output-format stream-json --verbose --resume {id}")
```

すべての `{id}` はセッションのランダムな UUID に置き換えられます。resume コマンドは
返答が成功した後にだけ使われ、最初のメッセージが失敗した場合は最初のコマンドで再試行します。
このデフォルトでは `claude -p` はプロジェクトを読めますが、誰にも確認を求められないため、
Claude Code の設定で既に許可されていない限りファイルの編集やコマンドの実行を拒否します。
両変数に `--permission-mode acceptEdits` を加えると編集が許可されます。自分では編集していない
バッファはファイルに追従します。エージェント (や他の何か) がディスク上で変更すると、darger は
1 秒以内に読み直します (`Reverted NAME`。undo 1 回で元のテキストに戻せます)。編集済みの
バッファはあなたのテキストを保ち、ディスク上で変わったファイルへの C-x C-s はまず
`NAME changed on disk; save anyway? (y or n)` と尋ねます。`M-x revert-buffer` は編集を捨てて
ファイルを読み直します。

```powershell
nimble build -d:release
.\darger.exe [file...]
nim r tests/tbuffer.nim
```

```sh
nimble build -d:release       # または: nimble install -d && nim c -d:release --outdir:. src/darger.nim
./darger [file...]
nim r tests/tbuffer.nim
nim r tests/tfileio.nim   # POSIX の保存動作
nim r tests/trecent.nim
nim r tests/tbuffers.nim
nim r tests/tcomplete.nim
nim r tests/tsyntax.nim
nim r tests/thtml.nim     # Web ビューア用の HTML レイアウト
nim r tests/tfeed.nim     # RSS / Atom の解析
nim r tests/tfetch.nim    # curl ダウンロード (curl が必要。file:// URL を使う)
nim r tests/tupdate.nim   # ローカルの bare リポジトリに対する自己更新 (git が必要)
nim r tests/torg.nim      # Org 構造と org-roam ノート
```

## macOS の darger.app

`nimble app` はリリースビルドを行い、そのコピーを中に入れた `~/Applications/darger.app` を
組み立てて LaunchServices に登録します。これで Spotlight、Dock、Finder の「このアプリケーションで
開く」(プレーンテキスト、ソースコード、Markdown、`.org`)、`open -a darger file.org` から darger を
開けます。チェックアウトのバイナリを直接動かさずコピーするのは、macOS が `~/Documents` (Desktop、
Downloads も) 配下の実行ファイルの LaunchServices 経由の起動を、プライバシーの許可ダイアログの
後にしか通さず、署名のないビルドではそのダイアログが出ないためです。起動は最初の命令の前で
止まり、同じバイナリでもターミナルからは普通に動きます。バンドルの `darger` はチェックアウトの
場所を `DARGER_SOURCE` に記録してコピーの `darger-bin` を起動するスタブなので、`M-x darger-update`
はチェックアウトを見つけられ、バンドルから起動した場合は `nimble -y app` でビルドしてコピーも
更新します。手で `nimble build` した後は `nimble app` をもう一度実行してください。この経路で
開いたファイルは引数ではなく Apple Event で届きます (AppKit はコマンドライン引数も同じ形で
報告するので、それは捨てます)。windy の macOS バックエンドのパッチ版
(`patches/windy/macos/platform.nim`) がそれを受け取り、エディタがダッシュボードの代わりに開きます
(起動中の darger があればそこへ)。こうして起動するとウィンドウがフォーカスも取ります。最近の
macOS では、他のプログラムから素の `./darger` を起動してもフォーカスは来ません。スクリプトからは
`open -n -W -a darger --args FILE` で、FILE を開いた新しいインスタンスを起動して閉じるまで
待てます。

## darger の更新

`M-x darger-update` は GitHub に新しいコミットがないか確認し、あれば pull してバックグラウンドで
エディタを再ビルドします。実行中の実行ファイルを含むチェックアウト
(`(setq darger-source-directory "~/src/darger")` で上書き可能) に対して動作し、そこは
`darger.nimble` を持つ git clone である必要があります。手順は `git fetch`、upstream ブランチとの
比較、`git merge --ff-only`、そして `darger-build-command` (デフォルト
`nimble -y build -d:release`。nimble が古すぎる場合は上記の `nim c` の行を設定してください)
です。エコー行には `Updating darger  checking GitHub 0:03  C-g:cancel` (続いて `pulling`、
`building`) と表示され、C-g で実行中のステップを止められます。各ステップのコマンドと出力は
`*darger update*` バッファ (C-x b) に入りますが、そこへ切り替わることはありません。結果は
`darger is up to date`、`darger updated to <hash> (N commits): restart to use it`、
`darger update failed: ...` のいずれかです。GitHub にないローカルコミットがマージで上書きされる
ことはありません。upstream に新しいコミットがなければ最新扱いになり、あれば
`local commits diverge from GitHub` で更新が止まります。git は認証情報を尋ねません
(`GIT_TERMINAL_PROMPT=0`)。Windows では実行中の `darger.exe` をビルド前に `darger.old.exe` に
リネームし、ビルドが失敗したら戻し、次回起動時に削除します。`~/.darger.el` に
`(darger-update)` と書けば、起動と再読込のたびに確認します。

0.24 より古い Nimble (例: Nim 2.2.10 に同梱の 0.22.x) は `cannot open file: opengl` で
失敗します。代わりに `nim c` の行を使ってください。

Linux では windy は X11 + GLX のみを使うため、Wayland セッションには XWayland が必要です。
libX11、libXext、libXcursor、libGL.so.1 は起動時に dlopen で読み込まれます (`ldd` には
出ません)。Arch なら `libx11 libxext libxcursor libglvnd mesa xorg-xwayland`、Debian なら
`libx11-6 libxext6 libxcursor1 libgl1` です。`config.nims` は Linux でのみ、`patches/windy` にある
windy 0.5.0 の X11 バックエンドのパッチ版を `patchFile` で差し替えます
(`patches/windy/README.md` を参照)。windy は 0.5.0 に固定されています。

ウィンドウにはシステムのタイトルバーも枠もありません。darger は独自のタイトルバーを
テキスト 1 行分の高さで描きます。中央にバッファ名、最小化・最大化・閉じるボタン (macOS では左、
それ以外では右) があります。左ボタンでどこをドラッグしてもウィンドウが動き、右端か下端
(6 px) または右下隅 (32 px) をドラッグするとリサイズし、タイトルバーのダブルクリックで
最大化を切り替えます。最大化はタスクバーを含む画面全体 (macOS ではメニューバーと Dock の
脇の領域) を覆います。テキストをクリックするとそのウィンドウが選択されてカーソルがそこに移り
(マークは解除)、ホイールはポインタの下のウィンドウを 1 ノッチ 3 行スクロールします。カーソルは
Emacs と同様、画面内に留まるのに必要な分だけ動きます。マウスはそれ以外には何もしません。macOS では windy 0.5.0 が
ボーダーレスウィンドウの `canBecomeKeyWindow` オーバーライドを誤ったセレクタで登録するため、
そのウィンドウはキーボードフォーカスを取れません。上記のパッチ版バックエンドが正しい
ものを登録します (windy を上げたら再確認してください)。macOS 自体が C-SPC を
「前の入力ソースを選択」(システム設定 > キーボード > キーボードショートカット > 入力ソース)
に、C-矢印を Mission Control に取っています。それらを切るか、`~/.darger.el` で `mark` を
別のキーに割り当ててください。Option は多くのキーで特殊文字を入力するため、macOS では
Command キーが Meta です (`meta-modifier` は `"cmd"`。システムは Cmd-Tab と Cmd-Space を
保持します)。`~/.darger.el` に `(setq meta-modifier "alt")` と書けば他の OS と同じく Option が
Meta になります。C-x C-c で終了します。Windows ではビルドは GUI プログラム
(`config.nims` の `--app:gui`) なので背後にコンソールは開かず、stderr のメッセージは
表示されません。

ファイルなしで起動すると、エディタは `*scratch*` を開き、その上にダッシュボードを表示します。
最近のファイルを最大 12 件、1-9 と a-c のラベル付きで並べます (HOME は `~` で表示、長いパスは
左から切り詰め)。C-n / C-p / 矢印で項目間を移動し、Enter か項目のラベルで開きます (もう
存在しないファイルは報告され、ダッシュボードはそのまま残ります)。q、C-g、Escape で閉じて
`*scratch*` に戻り、C-x C-f でファイルを尋ね、F1 でマニュアルに切り替え、C-x C-c で終了します。
`M-x dashboard` で開き、`dashboard` に割り当てたキーで閉じることもできます。デフォルトでは
何も割り当てられていません。一覧は `~/.darger-recent` (1 行に 1 つの絶対 UTF-8 パス、新しい順、
最大 30 件、アトミックに書き込み) にあります。コマンドライン、C-x C-f、`find-file` から
訪れた既存のファイルと、保存したすべてのファイルが先頭に移動します。`*scratch*` は記録されず、
一覧の読み書きエラーは無視されます。

F1 (または `M-x help`) は、プロンプトとレビューの外で内蔵マニュアル (日本語) を切り替えます。
その中では移動キーと C-v / M-v / PageDown / PageUp / C-l でスクロールし、q、Enter、Escape、
C-g、F1 で閉じ、C-x C-c で終了します。編集中のバッファには触れません。

UTF-8 ファイルは保存時に CRLF/LF を保ちます。存在しないファイルを開くと、そのパスに結び付いた
空のバッファができます。UTF-8 BOM はファイルの接頭辞として保たれ、編集可能な文字にはなりません。
保存はターゲットの隣に一意な一時ファイルを書き、検査してフラッシュしてからターゲットを
置き換えます。途中で失敗したら一時ファイルは削除され、元のファイルは無傷で、バッファは
変更済みのままです。ディレクトリをターゲットにすることは拒否されます。Linux/macOS では
読み取り専用ファイルは拒否され、シンボリックリンクはリンク先に書き込まれ、ファイルモード
(と許される場合は所有者) が保たれ、find/write プロンプトで `~` が展開されます。

フォントを選ぶには `$env:DARGER_FONT = 'C:\path\to\monospace.ttf'` (POSIX:
`DARGER_FONT=/path/mono.ttf DARGER_FALLBACK_FONTS=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc ./darger`)
を設定します。デフォルトの主フォントは、どの OS でもまず Iosevka Nerd Font Mono
(`IosevkaNerdFontMono-ExtraLight.ttf`、次に `-Light`、次に `-Regular`。Linux では
`/usr/share/fonts/TTF` と `~/.local/share/fonts`、Windows ではユーザーごとのフォルダと
`C:\Windows\Fonts`、macOS では `~/Library/Fonts`)、次にユーザーごとの HackGen Console NF、
Cascadia Mono、Consolas、Courier New (Windows)、次に DejaVu Sans Mono、Liberation Mono、
Noto Sans Mono、Adwaita Mono (Linux)、Menlo のパスの順です。Linux では `fc-match monospace` が
最後の手段です。`DARGER_FALLBACK_FONTS` はどの OS でも `;` 区切りの TTF/OTF/TTC パスを受け付け、
デフォルトでは Windows で BIZ UD Gothic、Yu Gothic、MS Gothic、Malgun Gothic、Segoe UI Emoji、
Segoe UI Symbol を、それ以外で Noto Sans CJK、Noto Sans Symbols 2、Hiragino を、さらに Linux では
日本語と韓国語の `fc-match` の結果を試します。カラー絵文字フォント (CBDT、sbix) は
未対応です。読めないフォントは stderr にメッセージを出してスキップします。TTC ファイルは
最初のフェイスを使います。`~/.darger.el` でもフォントを選べます。`(set-font "path")` は
そのファイルを主フォントにし (`DARGER_FONT` とデフォルトより優先)、フォールバックは保ちます。
`(set-fallback-fonts "path;path")` はフォールバックを置き換えます。どちらもいつでも (M-: でも)
使え、読み込めないフォントは現在のフォントをそのままにして、エコー領域に
`Cannot load font …` と報告します。

テキストは 16 ピクセル × ウィンドウの DPI スケール × ズームで、フォールバックのベースラインは
揃えられます。`DARGER_SCALE` (例: `2`) で DPI スケールを上書きできます。Linux で windy が 1.0 を
報告する場合 (`Xft.dpi` のない X11、XWayland) は、設定されていれば `GDK_SCALE` を使います。
F2 は粘着ズーム (Emacs の `hydra-zoom` のようなもの) を始めます。`g` で拡大 (x1.1)、`l` で縮小、
`0` でリセットし、F2 なしでキーを繰り返せます。別のキーを押すとズームを抜けて通常通り実行
されます (C-g は抜けるだけ)。ズームは 50%..400% の範囲に収まり、エコー領域に表示されます。
Emacs の `internal-border-width` 32 と同様に、テキスト領域、モードライン、エコー行は
32 ピクセル × DPI スケールの枠 (ズームされない) だけ内側に寄り、小さなウィンドウでは縮みます。

デフォルトの配色は modus-vivendi (Emacs の modus-themes と同じ黒背景) です。
`(load-theme "catppuccin")` で以前の Catppuccin Mocha の配色に切り替え、
`(load-theme "modus-vivendi")` で戻せます。いつでも (M-: でも `~/.darger.el` でも) 使えます。
未知の名前は `No such theme: …` と報告します。

シンタックスハイライトは内蔵です (外部の文法ファイルやライブラリを使わないので、Windows でも
同じように動きます)。言語はファイル拡張子 (大文字小文字を区別しない) か、Python、Ruby、
シェルスクリプトの `#!` 行から決まり、モードラインに表示されます。Nim (`.nim .nims .nimble`)、
GLSL (`.glsl .frag .vert .fs .vs`)、
Python (`.py .pyi`)、Ruby (`.rb .rake`、Gemfile、Rakefile)、GDScript (`.gd`)、
JS/TS (`.js .mjs .ts .tsx .jsx`)、C/C++ (`.c .h .cpp .hpp .cc`)、Rust (`.rs`)、Go (`.go`)、
Shell (`.sh .bash .zsh`)、Lisp (`.el .lisp .scm .clj`、`.emacs`)、JSON、TOML、
YAML (`.yaml .yml`)、Markdown (`.md .markdown`)、Org (`.org`) です。それ以外と `*scratch*` は
Text です。ファイルを開いたり書いたりした後に再判定されます。コメント、文字列、キーワード、
関数名と変数名、型、定数/数値、組み込みはテーマのフェイス (modus-vivendi では Emacs と同じく
fg-dim、blue-warmer、magenta-cooler、magenta、cyan、cyan-cooler、blue-cooler、magenta-warmer)
を取ります。トークナイザはテーブル駆動で近似的です。ブロックコメント、複数行文字列、
Markdown のフェンス、Org の `#+begin_src` ブロックは行をまたぎますが、本当の構文解析は
ありません。変更のたびにバッファ全体が再ハイライトされます (3000 行で数ミリ秒)。ヘルプ、
ダッシュボード、レビューのオーバーレイはプレーンのままです。

`show-paren-mode` と同様に、ポイントの後ろの括弧、なければ前の閉じ括弧が、対応する相手と
一緒にハイライトされます。`()`、`[]`、`{}`、`（）「」『』【】` が対象です。文字列やコメント内の
括弧は互いにしか対応しません。種類ごとに別々に数えるので `( [ ) ]` のような食い違いでも
対応し、探索は 5000 行離れたところで止まります。

ファイルバッファと `*scratch*` は左のガターに行番号を表示します。右揃え、最低 3 桁幅、
薄い色 (テーマの `lineNo`) で、カーソル行は明るく (`lineNoNow`)、その後に 2 セルの空きがあります。
オーバーレイ (ヘルプ、ダッシュボード、バッファ一覧、ファイラ、Web ページ、RSS 一覧、
レビュー) には行番号はありません。

CJK と対応する絵文字範囲は 2 セルを占めます。結合文字、異体字セレクタ、ジョイナー、
肌の色修飾子は 0 セルです。U+2600..27BF は Emacs と同じく 1 セルのままです。絵文字は
シェーピングなしのモノクロアウトラインで描かれます。ZWJ シーケンス、旗、キーキャップは
部品ごとに描かれます。欠けたグリフは中空の箱で表示されます。ファイル中のタブは 8 セル
ごとのストップで表示され、Tab キーは次の 4 セルストップまで空白を挿入します。長い行は
横にスクロールし、カーソルブロック全体が見えるようにします。IME の変換中テキストは
ハイライトされた背景でインラインに表示され、表示上の後続テキストを右にずらし、確定される
までバッファは変わりません。ネイティブ IME は Windows/macOS でのみ動きます。windy の X11
バックエンドには XIM がないので、Linux では fcitx/ibus、デッドキー、Compose は動きません。
内蔵の SKK (C-\ または C-x C-j) を使ってください。

`C-` は Ctrl、`M-` は Alt を意味します。左右どちらの修飾キーでも動きます。

| 操作 | キー |
| --- | --- |
| 文字 / 行の移動 | C-f / C-b / C-n / C-p、矢印 |
| 行頭 / 行末 | C-a / C-e、Home / End |
| 単語 / インデント位置 | M-f / M-b、M-m |
| バッファ先頭 / 末尾 | M-< / M->、C-Home / C-End |
| ページ / 再センタリング | C-v / M-v、PageDown / PageUp。C-l は中央/上/下を巡回 |
| 行番号へ移動 | M-g g / M-g M-g |
| 一致する行へジャンプ (consult-line) | M-g l |
| 言語サーバー: 補完 / ホバー | C-M-i (自動でも) / C-c h |
| 言語サーバー: 定義 / 戻る / 参照 | M-. / M-, / M-? |
| 言語サーバー: バッファを整形 | C-c = |
| 挿入 / 削除 | Enter / C-m / C-j、Tab / C-i、Backspace / C-h、C-d / Delete |
| 行を開く / 入れ替え | C-o / C-t |
| 行 / 単語 / 前の単語を kill | C-k / M-d / M-Backspace |
| 単語を大文字 / 小文字 / 先頭大文字 | M-u / M-l / M-c |
| マーク切替 / 交換 / 全選択 | C-SPC または C-@ / C-x C-x / C-x h |
| リージョンを kill / コピー | C-w / M-w |
| yank / 直前の yank を巡回 | C-y / M-y |
| undo | C-/、C-_ (Ctrl+Shift+Minus)、C-x u |
| 開く / 保存 / 別名保存 / 終了 | C-x C-f / C-x C-s / C-x C-w / C-x C-c |
| ウィンドウを下 / 右に分割 | C-x 2 / C-x 3 |
| 他のウィンドウ / ウィンドウを消す / 他を消す | C-x o / C-x 0 / C-x 1 |
| インクリメンタル検索 前方 / 後方 | C-s / C-r。繰り返すと次 / 前 |
| キャンセル | C-g |
| SKK 日本語入力 オン / オフ | C-\ または C-x C-j |
| マニュアル (ヘルプ) オン / オフ | F1 |
| ダッシュボード (最近のファイル) オン / オフ | M-x dashboard |
| GitHub から pull して再ビルド | M-x darger-update |
| ズーム 拡大 / 縮小 / リセット (粘着) | F2 g / l / 0 |
| 初期化ファイル `~/.darger.el` を開く | C-c , |
| Web ブラウザ (eww) / RSS リーダー | C-c w / C-c r |
| GLSL バッファ: シェーダー適用 / 絵だけ / 解除 | C-c C-c / C-c C-o / C-c C-k |
| シェルバッファ / 割り込み / EOF | C-c s / C-c C-c / C-d |
| Org: TODO / チェックボックス / 新しい項目 | C-c C-t / C-c C-c / M-Enter |
| Org: 昇格 / 降格 / サブツリーを上 / 下へ | M-Left / M-Right / M-Up / M-Down |
| Org: 見出し一覧 / リンクを開く / タイムスタンプ | C-c C-j / C-c C-o / C-c . |
| Org: 見出しを折りたたむ / ファイル全体 | TAB / Shift-TAB |
| Org: 日報エントリ / capture | C-c j / C-c t |
| org-roam: 検索 / リンク挿入 / バックリンク / 今日 | C-c n f / C-c n i / C-c n l / C-c n d |

検索は、すべて小文字のクエリでは大文字小文字を区別しません。入力すると現在の一致が
伸び、バッファ端に当たった検索は `Failing I-search` を表示し、C-s/C-r を繰り返すと
折り返します (`Wrapped`)。繰り返しは現在の一致と重なりません。空のクエリでの C-s/C-r は
直前の検索を再利用します。Backspace で前の検索状態に戻ります。Enter で一致を確定し、
他のコマンドは一致位置で検索を終えて実行し、C-g は元のポイントに戻します。
インクリメンタル検索以外のプロンプトはウィンドウ上部付近のポップアップに浮かびます
(M-g l のものは下部。ウィンドウが小さすぎるときは最下行)。メッセージは最下行に留まります。
ミニバッファは挿入、Backspace、C-a/C-e/C-f/C-b、C-k、C-y、Enter、C-g に対応します。
Find/Write/Agent/バッファ/行のプロンプトとインクリメンタル検索は、C-\ または C-x C-j
(`skk-mode` に割り当てたキー) で SKK も切り替えられます。確認プロンプトには `y` か `n` を
入れて Enter で答えます。Backspace と Delete はアクティブなリージョンを kill せずに削除します。
kill/コピーはクリップボードを更新し、60 件の kill リングが空なら C-y はクリップボードを
使います。undo は 200 個のスナップショットを保持し、空白以外の連続した self-insert を
まとめます。スナップショット方式の undo と平坦化された編集は小さなファイル向きです。

## ファイラ (Dired)

C-x d はディレクトリを尋ねます。開始位置は現在のファイルのディレクトリ (scratch なら
作業ディレクトリ) で、`M-x dired` も同じです。`(dired "path")` とコマンドラインの
ディレクトリ引数はファイラを直接開きます。C-x d プロンプトでは Enter でそれまでに入力した
ディレクトリを開くので、C-x d Enter で現在のディレクトリを一覧できます。Tab で補完します。
C-x C-f では、ディレクトリ候補での Enter は従来通り降りていき、選ぶものが何もない
ディレクトリだけがファイラを開きます。

読み取り専用のオーバーレイには隠しファイルも含まれ、ディレクトリが先、名前は大文字小文字を
区別せずにソートされます。行には種類 (`d`、`l`、`-`)、サイズ、更新時刻、名前が表示され、
ディレクトリ名には末尾に `/` が付いてハイライトされます。

- n / C-n / 下 と p / C-p / 上 で項目間を移動。C-v / M-v でページ、M-< / M-> で
  最初 / 最後の項目へ。
- Enter / f でファイルを開くかディレクトリに入る。^ で親へ移動し、出てきたディレクトリを
  選択する。g で再読込 (選択中の名前を保持)。
- + でディレクトリを作成 (親も含む)。R で項目をリネームまたは移動 (既存の移動先は拒否)。
  どちらもパス補完付きのプロンプトを使う。
- D は `Trash NAME? (y or n)` と尋ね、y で Windows のごみ箱か Linux の `gio trash` を使う。
  エラーはエコー領域に表示され、完全削除へのフォールバックはない。他のプラットフォームでは
  ごみ箱は未対応。
- q / C-g / Escape でファイラを閉じる。C-g / Escape は作成/リネームのプロンプトを
  キャンセルして一覧に戻る。

## シェル

C-c s (`M-x shell`) は `*shell*` を開きます。comint 風のシェルバッファです (macOS / Linux)。
`shell-file-name` (既定は `$SHELL`、なければ `/bin/sh`) を、現在のファイルのディレクトリで
擬似端末上に `TERM=dumb`、`INSIDE_DARGER=1`、`PAGER=cat` 付きで起動します。出力はエスケープ
シーケンス、復帰、バックスペースを適用してバッファ上部に溜まり、その後ろに打った文字が
コマンドで、Enter で送ります (pty はエコーしないので、打った行はそのまま残り、出力がその下に
続きます)。C-c C-c で割り込み (`SIGINT`)、空のコマンドでの C-d で EOF を送ります。出力は
約 400 KB を保ちます。バッファは保存を求めず、kill するか終了するとシェルは HUP され、
シェルが終わった後 (`Process shell finished`) の C-c s は新しいシェルを起動します。
ターミナルの最初のスライスで、行モード、色なし、全画面プログラムは動きません。

## 背景シェーダー

NeoEmacs のフレームシェーダーと同じように、GLSL のフラグメントシェーダーをテキストの下で
動かせます。`~/.darger.el` か M-: で `(background-shader "~/.emacs.d/bg-shader.glsl")` と
すると、そのファイルをコンパイルしてウィンドウ全体に毎フレーム描き、その上にテーマの背景色を
`background-shader-dim` の不透明度 (既定 `0.6`。`0` で絵だけ) で重ねます。ファイルは Shadertoy
形式 (`mainImage(out vec4 fragColor, in vec2 fragCoord)`。`iResolution`、`iTime`、`iMouse`、
`iFrame` が使える) か、独自の `main` と `out` を持つ `#version 410 core` のフラグメント
シェーダー全体です。GLSL バッファ (`.glsl .frag .vert .fs .vs`。ハイライトあり) では C-c C-c で
バッファの内容を適用、C-c C-o で絵だけ ↔ うっすら背景を切り替え、C-c C-k で解除します。
`M-x background-shader` (バッファを適用)、`background-shader-toggle`、`background-shader-clear`
はどこからでも使えます。適用中のファイルを保存するか、ディスク上で変わると再適用されるので、
動かしながら書けます。コンパイルエラーのときは前のシェーダーが動いたまま、GL のログが
ファイルの行番号に直されてエコー行と `*shader*` バッファ (C-x b) に入ります。シェーダー実行中は
入力時だけでなく毎フレーム再描画します。

## Web ブラウザ (eww)

C-c w (`eww`) は `URL or search: ` と尋ねます。URL は入力通りに読み込まれ、ドットを含む単語
(`example.com`) には `https://` が付き、それ以外は `eww-search-prefix` (デフォルトは
DuckDuckGo の HTML 版) で検索されます。空のプロンプトで Enter を押すと最後のページを
再び開きます。`(eww "url")` と `M-x eww` は Lisp から同じことをし、ページ上での C-c w は
ページを閉じます。

ページは `fetch-command` (デフォルト
`curl -sSL --max-time 30 --max-redirs 10 --compressed -A darger/0.1`。curl は Windows 10/11、
macOS、ほぼすべての Linux に入っています) でバックグラウンドにダウンロードされるので、
エディタは応答し続け、エコー行に `Loading url 0:03  C-g:cancel` が刻まれます。本文は
パイプではなく一時ファイルに入り、ダウンロードは 20 MB で止まります。cookie jar、JavaScript、
フォーム送信、画像表示はありません。

ページは内蔵の寛容な HTML トークナイザ (外部ライブラリなし) でレイアウトされます。段落、
見出し (関数名と同じ色)、リスト (`•`、`1.`)、`<pre>` はそのまま、引用はインデント、表は
セル間 2 スペースの行、画像は `[alt]`、`<hr>` は罫線、script と style は除去されます。
テキストはウィンドウ幅 (最大 100 セル) で空白と CJK 文字の間で折り返され、ウィンドウや
ズームが変わると再レイアウトされます。リンクは青 (文字列フェイス) です。最初の行は URL、
モードラインは `<title>` を表示します。文字コードは `Content-Type` ヘッダ、BOM、
`<meta charset>`、XML 宣言から決まり (Shift_JIS、EUC-JP、ISO-2022-JP、GBK、Big5、EUC-KR、
Windows-125x ... は OS のコンバータ経由)、不正なバイトは U+FFFD になります。フィード URL
(RSS/Atom) はエントリ一覧として表示され、`text/plain` と JSON はそのまま、他の種類 (画像、
PDF) は表示されません (`&` で外部で開けます)。HTTP エラーページはエコー行に `HTTP 404` を
出して表示されます。

- C-n / C-p / n / p / 矢印で行移動。C-f / C-b は行内を移動。C-v / M-v / SPC / Backspace で
  ページ。M-< / M-> で先頭 / 末尾へ。C-l で再センタリング。
- Tab / Shift-Tab で次 / 前のリンクへ。Enter / f でカーソル下のリンク、なければカーソル行の
  最初のリンクをたどる。
- l / r で戻る / 進む (ページは再取得され、カーソル行は保たれる)。g で再読込。G で別の
  URL か検索を尋ねる。
- & でポイントのリンク (なければページ) をシステムブラウザで開く。w でその URL を kill リングと
  クリップボードにコピー。v で生の HTML を `*web source*` バッファに開く。
- q / Escape / C-g でページを閉じる (C-g はまずダウンロードをキャンセルする)。F1 で
  マニュアル。C-x C-c で終了。ページは残り、C-c w Enter で戻せる。

## RSS

C-c r (`rss`) はリーダーを開きます。elfeed 風に、すべての購読のエントリを新しい順に
`date  feed  title` で並べ、既読は薄く表示します。購読は `~/.darger-feeds` (1 行に 1 つの URL、
任意でタイトルが続く。`#` はコメント) と、`~/.darger.el` の `(rss-feed "url" ["title"])` から
来ます。最初に開くとすべてのフィードを `fetch-command` で、最大で一度に全部取得し、
届くにつれて一覧が埋まり、ヘッダに `fetching 3/7`、続いて `12 new` か `up to date` と、
最初の失敗 (`host: HTTP 404`、`not a feed`、...) が表示されます。ページがフィードを告知している
(`<link rel=alternate type=application/rss+xml>`) サイト URL は一度だけたどられます。RSS 2.0、
Atom、RSS 1.0 (RDF) は標準ライブラリの寛容な XML パーサで解析します。title、link、guid/id、
pubDate/published/updated/dc:date、author/dc:creator、`content:encoded` (なければ
description/summary) を HTML として、Atom の XHTML コンテンツも含めて扱います。エントリは
ディスクにキャッシュされず、セッションごとにフィードを取り直します。

- n / p / C-n / C-p / 矢印で移動。C-v / M-v / SPC / Backspace でページ。M-< / M->。
- Enter / f でエントリを既読にして Web ビューアで表示する。タイトルは記事へのリンクで、
  続いてフィード、日付、著者、本文。中のリンクは他のページと同様に動き、q (または履歴なしの
  l) で一覧に戻る。
- & / b で記事をシステムブラウザで開く。w で URL をコピー。
- r / u でエントリを既読 / 未読にする (r は下にも移動)。R で表示中のすべてのエントリを
  既読にする。既読キー (guid、なければ link) は `~/.darger-rss-read` に最新 5000 件保たれる。
- g ですべてのフィードを再取得。a でフィード URL を尋ね、`~/.darger-feeds` に追記して取得。
  s でフィードとタイトルに対して orderless 風に一覧を絞り込む (空でリセット)。
- q / Escape / C-g で一覧を閉じる (取得は続き、終わると `RSS: 3 new (C-c r)` がエコーされる)。
  F1 でマニュアル。C-x C-c で終了。

## ウィンドウ

Emacs と同様に、フレームに複数のウィンドウを並べられます。C-x 2 (`split-window-below`) と
C-x 3 (`split-window-right`) は選択中のウィンドウを 2 つに分け、どちらも同じバッファの同じ
場所を表示します。C-x o (`other-window`) で次のウィンドウ (左から右、上から下、末尾で先頭に
戻る) を選択し、マウスクリックでその下のウィンドウを選択、C-x 0 (`delete-window`) で選択中の
ウィンドウを消して隣にスペースを渡し、C-x 1 (`delete-other-windows`) で選択中のものだけを
残します。各ウィンドウは自分のバッファ、ポイント、スクロール (同じバッファを 2 つの
ウィンドウで表示すると、それぞれにポイントがあります) とモードラインを持ちます。選択中の
モードラインは明るく、他は暗く、横並びのウィンドウの間には `│` の列が入ります。半分が 3 行か
10 桁より小さくなる分割は拒否されます。コマンド、プロンプト、オーバーレイ (dired、eww、
マニュアル、レビュー)、カーソルボックスはすべて選択中のウィンドウで動き、他のウィンドウは
バッファをハイライトと折りたたみ付きで表示するだけです。別のウィンドウに表示中のバッファを
kill すると、そこには最近使ったバッファが入ります。プロンプトのポップアップとエコー行は
ウィンドウではなくフレームのものです。

## バッファ

各ファイルは自分のバッファで開き、他のバッファはテキスト、ポイント、undo、スクロール位置、
言語を保ちます。すべてのコマンドライン引数が開かれ、最初のものが表示されます (読み込みに
失敗したものはエコー領域に報告されてスキップ)。初期の `*scratch*` の隣に並びます。既に
開いているファイルを開く (C-x C-f、`find-file`、ダッシュボード、C-c ,) とそのバッファに
切り替わり、編集内容は保たれます。

- C-x b (`switch-to-buffer`) はバッファ名を尋ねる。Enter だけなら最後に使った別のバッファ
  (デフォルトとして表示) に切り替わり、未知の名前はその名前の空バッファを作る。
  `(switch-to-buffer "name")` は Lisp から同じことをする。
- C-x k (`kill-buffer`) は名前を尋ね (デフォルト: 現在のバッファ)、変更済みなら
  `Buffer NAME modified; kill anyway? (y or n)` と尋ねる。現在のバッファを kill すると前の
  バッファが表示され、最後の一つを kill すると新しい `*scratch*` が残る。
- C-x 右 / C-x 左 (`next-buffer` / `previous-buffer`) は開いた順に巡回する。
- C-x C-b (`list-buffers`) はバッファを最近使った順に ` CRM Name  Path` の行で一覧する
  (`.` は現在のバッファ、`*` は変更済み)。C-n / C-p / n / p で移動、Enter で切り替え、k で
  その行のバッファを kill (変更済みならその場で y/n を尋ねる)、q、C-g、Escape で一覧を閉じる。

名前は Emacs に従います。ファイルの名前はそのベース名で、同名のバッファには親ディレクトリが
付きます (`darger.nim<src>`、`darger.nim<tests>`、必要なら `<a/src>` まで深くなる)。パスの
ないバッファは `*scratch*`、`*scratch*<2>`、... か、C-x b で入力した名前です。モードラインと
ウィンドウタイトルはこの名前を表示します。C-x C-s は現在のバッファだけを保存し、C-x C-c は
変更済みのバッファがあれば終了前に尋ねます。kill リングは共有で、切り替え先のバッファに
付いてきます。バッファはファイルに追従します (上のエージェントの節を参照)。未編集のバッファは
ファイルがディスク上で変わると読み直され、編集済みなら保存前に尋ねます。

## 補完

Find file / Write file (C-x C-f、C-x C-w)、M-x、C-x b、C-x k、M-g l、M-g f、M-? のプロンプトは、
vertico 風に入力の下に候補を並べます。最大 10 行 (低いウィンドウではテキストが残るよう
もっと少なく)、選択中のものがハイライトされ、プロンプトの右に `N/M` (選択 / 一致) が出ます。
一致は orderless 風です。入力を空白で分割し、すべての語が候補のどこかに、順不同、大文字小文字
無視 (日本語も含む) で現れる必要があります。最初の語で始まる候補が先に来て、それ以外は
元の順序を保ちます。

- 最初の候補が事前選択される。C-n / C-p (下 / 上) で移動し折り返す。C-v / M-v
  (PageDown / PageUp) で 10 件移動。
- TAB で選択中の候補を入力に挿入し、Enter で確定する。M-Enter は入力をそのまま確定する。
  例えば既存の `foobar` の隣に `foo` を作るときや、名前が他の接頭辞になる新しいバッファを
  作るとき。一致がなければ Enter も入力をそのまま使う。
- ファイル: 候補はそれまでに入力したディレクトリ (最後の `/` まで、`~` は展開) の項目で、
  ディレクトリには末尾に `/` が付き、大文字小文字無視でソートされ、残りの入力で絞り込む。
  ドットファイルは残りが `.` で始まると現れる。ディレクトリでの TAB か Enter は開く代わりに
  中に降りる。
- M-x はすべてのコマンドを一覧する。バッファコマンド、引数なしで呼べるプリミティブ、
  `~/.darger.el` の引数なし `defun`。C-x b は最近使った順にバッファを並べ、デフォルトが先頭。
  C-x k は現在のバッファから始まる。
- M-g l (`consult-line`) はすべての行を `number  text` (テキストは 200 文字で切る) として
  一覧し、テキストで絞り込む。選択を動かすとその行がセンタリングとハイライト付きで
  プレビューされる。Enter でそこに留まり、C-g で元の位置に戻る。一覧はモードラインの上、
  ウィンドウ下部に開くので、プレビュー中の行はその上に見えたままになる。

## 言語サーバー

言語にサーバーがあるファイルは LSP 経由で診断を受け取ります。サーバーはその言語のバッファが
最初に表示されたときに起動し (言語ごとに一つ、ファイルの上にある `.git` を持つ最も近い
ディレクトリ、なければファイルのディレクトリをルートとする)、終了時に停止します。darger は
最後の編集から 150 ms 後と保存時に全文を送ります。

| 言語 | サーバー (インストールされている最初のものを使う) |
| --- | --- |
| Nim | `nimlangserver` |
| Python | `pyright-langserver --stdio`、`pylsp` |
| Ruby | `solargraph stdio`、`ruby-lsp` |
| GDScript | `tcp://127.0.0.1:6005` (Godot エディタのサーバー) |
| JS/TS | `typescript-language-server --stdio` |
| C/C++ | `clangd` |
| Rust | `rust-analyzer` |
| Go | `gopls` |
| Shell | `bash-language-server start` |
| JSON | `vscode-json-language-server --stdio` |
| YAML | `yaml-language-server --stdio` |
| Markdown | `marksman server` |

見つからないときはエコー領域に一度だけ、例えば `No language server for C/C++ (clangd not
found)` と出ます。言語のコマンド (空白で分割。`tcp://host:port` は起動せず接続する) は
`~/.darger.el` で上書きできます。

```elisp
(lsp-server "C/C++" "clangd --log=error")
(lsp-server "Python" "")   ; Python にはサーバーを使わない
```

- 診断はその範囲に下線を引く (エラー赤、警告黄、情報青、ヒント灰)。モードラインは言語名の
  後に ` E:n W:m` を表示する。カーソルを 500 ms 乗せると、エコー領域が空なら
  `error: message` が出る。
- M-g f (`consult-flymake`) はそれらを `line:col  E|W|I|H  message` としてウィンドウ下部に
  行順で一覧する。選択を動かすとその場所がプレビューされ、Enter で留まり、C-g で戻る。
- M-x `lsp-restart` は現在のバッファのサーバーを再起動する。M-x `lsp-log` はログのパスを
  エコーする。ログは一時ディレクトリの `darger-lsp-<language>-<pid>.log` (サーバーの stderr と
  メッセージ。4 MB を超えると作り直され、終了時に削除)。
- 補完 (company 風): カーソル下のポップアップにサーバーの候補が、種類の文字 (f 関数、v 変数、
  m メソッド、c クラス/構造体、k キーワード、t 型、s スニペット、o その他) と詳細付きで並ぶ。
  識別子文字を 2 つ入力して 300 ms 止まるか、サーバーのトリガー文字 (`.` など) の直後に
  自動で開く。C-M-i (`completion-at-point`) はすぐに尋ねる。C-n / C-p (または矢印) で選択、
  Enter / TAB で挿入 (スニペットのプレースホルダはテキストに縮められ、clangd の `#include`
  のような項目の追加編集も入る)、C-g / Escape で閉じ、入力すると一覧が絞られる (一覧が
  打ち切られていたとサーバーが言った場合は 300 ms 止まった後に再び尋ねる)。他のキーは閉じて
  通常通り実行される。`~/.darger.el` の `(setq lsp-auto-complete nil)` で C-M-i だけになる。
- C-c h (`lsp-hover`) はポイントのシンボルについてのサーバーの説明をカーソル下の箱に表示する
  (最大 12 行。長いものは C-n / C-p / C-v / M-v でスクロール)。他のキーで閉じる。
- M-. (`lsp-definition`) は定義にジャンプし、必要ならそのファイルを開く。M-, (`lsp-back`) で
  戻る。元の位置は最新 50 件保たれる。M-x `lsp-type-definition` と `lsp-implementation` も
  同様にジャンプする。M-? (`lsp-references`) は参照を `path:line: text` としてウィンドウ下部に
  ファイルごとにまとめて一覧する。選択を動かすと各参照がプレビューされ、Enter で留まり
  (M-, で戻れる)、C-g で戻る。
- C-c = (`lsp-format-buffer`) はサーバーでバッファを整形する (4 スペースインデント)。C-/ で
  整形全体を一度に undo できる。
- サーバーが 10 秒答えないリクエストは `LSP: <method> timed out` で捨てられる。エディタは
  答えを待ってブロックせず、忙しいサーバーがまだ読んでいないテキストはキューされる
  (Windows では 4 KB ずつ書く)。

## Org と org-roam

Org バッファ (`.org`) では、C-c C-t がポイント上か上方の見出しを TODO、DONE、なしの順に
巡回します。C-c C-c はリスト項目の `[ ]` / `[X]` を切り替えます。M-Enter はその行の下に同じ
種類の見出しかリスト項目を追加します (番号は進み、チェックボックスは空で来ます)。
M-Left / M-Right は見出しを昇格・降格し、M-Up / M-Down はそのサブツリーを上か下の兄弟と
入れ替えます。C-c C-j は M-g l のように見出しを一覧します (プレビューは選択に追従し、C-g で
戻り、ジャンプ後は M-, で戻れます)。C-c C-o はポイントの `[[link]]` をたどります (`id:` は
ノートを開き、`file:` とプレーンなパスはファイルを開き、URL はシステムブラウザへ、
`*Headline` はジャンプ)。C-c . は `<2026-10-07 Wed>` を挿入します。

折りたたみは Emacs と同じように動きます。見出しで TAB を押すと FOLDED (サブツリーが隠れ、
見出しの末尾に `...`)、CHILDREN (本文と、折りたたまれた子見出し)、SUBTREE を巡回します。
Shift-TAB はファイル全体を OVERVIEW (トップレベルの見出しだけ)、CONTENTS (すべての見出し、
本文なし)、SHOW ALL と巡回し、`#+startup: folded` (または `overview`、`content`) のファイルは
その状態で開きます。見出し以外での TAB は従来通りインデントです。C-n / C-p、C-v / M-v、C-l は
表示中の行だけを数えます。検索、M-g g、リンク、編集で隠れた行に着くと、そこまでの折りたたみが
開き、途中の兄弟サブツリーは折りたたまれたままです。折りたたみより上の編集は折りたたみを
ずらし、折りたたんだ見出しを削除するとその本文は単に見えるようになります。コマンドは
`M-x org-cycle` と `org-shifttab` です。

C-c j (`org-journal-new-entry`) は org-journal のように日報を付けます。今日のファイルは
`org-journal-dir` / `org-journal-file-format` (既定 `~/org-journal`、`%Y%m%d.org`) で、
なければ `org-journal-file-header` と日付見出し (`org-journal-date-prefix` +
`org-journal-date-format`、既定 `* ` と `%A, %d %B %Y`) を付けて作り、末尾に時刻見出し
(`org-journal-time-prefix` + `org-journal-time-format`、既定 `** ` と `%R `) を足して、
カーソルをその後ろに置きます。`org-extend-today-until` 時 (既定 `"0"`) より前は前日の
ファイルに書きます。書式は strftime の `%Y %y %m %d %e %H %M %S %R %A %a %B %b %j %%` を
受け付け、日本語ロケール (`LANG=ja_JP.UTF-8`) では Emacs と同じく `%A` が `火曜日`、`%B` が
`10月` になります。C-c t (`org-capture`) は `Capture: ` と尋ね、入力を `org-capture-template`
(既定 `* TODO %?\n`。`%?` が入力、`%t` / `%u` が今日のアクティブ / 非アクティブな
タイムスタンプ、`%T` / `%U` は時刻付き) に通して、`org-capture-file` 内の
`org-capture-headline` のサブツリー末尾 (既定は `""` でファイル末尾、`~/org/inbox.org`) に
入れます。見出しやファイルがなければ作ります。そのファイルのバッファが開いていれば編集して
保存し、なければファイルに直接書き、カーソルは今いる場所から動きません。

org-roam ノートは `org-roam-directory` (デフォルト `~/org-roam`。`~/.darger.el` で
`(setq org-roam-directory "~/notes")`) の下にある、ID プロパティドロワーと `#+title:` を持つ
Org ファイルです。ディレクトリはコマンドのたびに、データベースなしで再走査されます。
C-c n f はタイトルを尋ねます。一覧にあるノートで Enter を押すと開き、新しいタイトルで Enter
(一致が並んでいる間に入力したタイトルを取るには M-Enter) を押すと
`<timestamp>-<slug>.org` を作って開きます。C-c n i はポイントに `[[id:…][Title]]` を挿入します
(アクティブなリージョンはタイトルになり、置き換えられます)。C-c n l は現在のノートに
リンクしているノートを、リンク行とともに参照のようにプレビュー付きで一覧します。C-c n d は
今日の `daily/YYYY-MM-DD.org` を開きます (なければ作成)。`M-x org-id-get-create` は任意の Org
ファイルに ID を与えてノートにします。

## アーキテクチャ

`src/core.nim` がエディタです。バッファレジストリ、ウィンドウとレンダラ、キーディスパッチ、
プロンプト、オーバーレイ、Lisp インタプリタ、そして他のすべてが差し込まれる API を持ちます。
`src/darger.nim` はウィンドウ (タイトルバー、マウス、キーボードのコールバック) とメインループ
だけを受け持ちます。すべての機能は `src/ext/` 以下の拡張で、`core` を import し、`darger.nim`
から import されたときに自分を登録する Nim モジュールです。`org` (Org と org-roam)、`web`
(eww)、`rss`、`dired`、`help`、`dash`、`blist`、`agent` (一回限りの編集、レビュー、チャット)、
`selfupdate`、`langserver` があります。それぞれが依って立つ純粋なロジック (解析、プロトコル、
ファイル操作) は `src/` 直下の独自モジュールに置かれ、テストを持ちます。

API は `core.nim` の「The extension API」の下にあります。`defineMode` はビュー (`Mode`: 表示する
バッファ、フェイス、モードラインのタグ、エコー行のメッセージ、キーハンドラ、close と
relayout の proc) を登録します。`definePrompt` はミニバッファプロンプト (`Prompt`: 候補、
位置をプレビューするかパスを補完するか、どのビューの上に浮かぶか、そしてプロンプトを開いた
ままにもできる `onAccept`) を登録します。`interp.defPrimitive` は M-x と `global-set-key` 用の
コマンドを追加します。`defaults.add` は組み込みのバインディングの後、`~/.darger.el` の前に
評価される Lisp を供給します。フック: `tickHooks` (ループごとにポーリング)、`messageHooks`
(エコー行の上書き)、`keyFilters`、`runeHooks`、`insertHooks`、`imeHooks`、`escapeHooks`、
`busyHooks`、`cancelHooks` (C-g)、`killHooks`、`saveHooks`、`modifiedIgnore`、`exitHooks`、
`langHints`、そして単一のプロバイダ `dirVisitor`、`marksHook`、`boxHook`、`modeLineHook`、
`startScreen`。ビューは他の機能を直接呼ばずキーマップ (`dispatch(full)`) 経由で届くので、
import を外せば拡張を取り除けます。

## 初期化ファイル

`~/.darger.el` は起動時にデフォルトのバインディングの後に評価され、ディスク上で変わるたび
(0.5 秒ごとに確認) に再評価されるので、保存すればすぐに適用されます。まずデフォルトの
バインディングが復元されるので、ファイルから消した `global-set-key`、`hydra`、`setq` は
デフォルトに戻ります。一方、既に追加されたフィード、LSP サーバー、`defun` は再起動まで
残ります。エコー行は `Loaded ~/.darger.el` かエラーを報告し、ファイルがなければ起動のたびに
`No ~/.darger.el (C-c , creates it)` と表示します。`M-x load-init` で手動で
再読込できます。C-c , で開きます (`(find-file "~/.darger.el")`。既に開いていればそのバッファに
切り替わります)。`global-set-key`、`setq`、`message`、`insert`、`command` のほかに、
`(load-theme "catppuccin")`、`(set-font "path")`、`(set-fallback-fonts "path;path")`、
`(find-file "path")` (`~` は展開)、`save-buffer`、`kill-emacs`、`skk-mode`、
`zoom-in` / `zoom-out` / `zoom-reset`、
`(eww "url")`、`(background-shader "path")`、`(setq background-shader-dim 0.6)`、
`(rss-feed "url")`、`(setq fetch-command "...")`、
`(setq eww-search-prefix "...")`、そして `(hydra "PREFIX" "hint")` が使えます。hydra は
1 キーのプレフィックスを粘着にします。割り当てられた `PREFIX x` コマンドの後もプレフィックスが
有効なままで、ヒントがエコー領域に出ます。デフォルトの
`(hydra "f2" "zoom  g:in  l:out  0:reset")` がその例です。

```elisp
(global-set-key "f2 r" 'zoom-reset)
(load-theme "catppuccin")
```

## SKK 入力

C-\ または C-x C-j (`skk-mode`) は内蔵の DDSKK 風 SKK を切り替えます (オフにすると進行中の
ものを確定します)。モードラインは `[かな]`、`[カナ]`、`[SKK]` (ラテン) を表示し、オフなら
何も出ません。保留中のローマ字、`▽読み`、`▼候補` は IME の変換中テキストのようにカーソル位置に
インラインで描かれ、バッファはかなが完成するか変換が確定したときにだけ、通常の挿入経路で
変わります (確定は 1 つの undo ステップ)。

- 直接入力は DDSKK のローマ字規則に従う。`nn`/`n'` → ん、子音の重ね → っ、`x` + 母音 /
  `xtu` / `xya` / `xwa` で小書き、`-` ー、`~` 〜、`! ? : [ ]` は全角、
  `z/ z. z, z- zh zj zk zl z[ z]` → `・ … ‥ 〜 ← ↓ ↑ → 『 』`。`.`、`,`、数字、空白は
  ASCII のまま。`(` はカーソルを中に置いて （） を挿入し、`)` は続く ） を飛び越える。`q` で
  カタカナ切替、`l` でラテンへ、`L` で全角英数 (`[全英]`。`Abc 1` → `Ａｂｃ　１`)、どちらからも
  C-j でひらがなに戻る。
- ▽: 大文字か `;` で読みを始める。2 つ目の大文字 (または `;`) が送り仮名を示す (`OkuRi` → 送り。
  かなが完成し次第変換)。SPC で変換、Enter / C-j で改行なしに読みを確定、`q` でカタカナとして
  確定、Backspace で最後のかなを削除、C-g でキャンセル。Enter、Backspace、Tab はここでは
  C-m、C-h、C-i と同じ意味。`(setq skk-egg-like-newline nil)` にすると、▽ / ▼ での Enter は
  DDSKK の既定どおり確定してから改行も入れる。既定の `t` は確定のみ。Tab は skk-comp のように読みを補完する。入力した文字で始まる辞書の
  見出し語 (ユーザー辞書が先、次に本辞書、五十音順。送りあり見出しは除く) に読みが置き換わり、
  もう一度 Tab で次、最後の次は入力した文字に戻る。補完の続きを打つこともでき、SPC で変換する。
- `/` で abbrev の読みを始める (`▽` に ASCII をそのまま入力。ローマ字変換なし、大文字と `;` も
  文字のまま)。`/dog` SPC は見出し語 `dog` を引くので、ユーザー辞書に `dog /犬/` があれば 犬 に
  なる。Enter で ASCII のまま確定、Tab は ASCII の見出し語だけを補完し、候補がなければ ASCII の
  見出し語で登録する。終わるとかな入力に戻る。
- ▼: SPC / `x` で候補 1-4 を順に進み、C-n / C-p (または矢印) はどこでも 1 候補ずつ進む・戻る。
  5 つ目からは現在のページ 7 件がカーソルの下に一覧で出て、選択キー `a s d f j k l` が付き、
  選択中の候補がハイライトされる (プロンプト内ではエコー行に `A:… ▶S:… D:…  [残り N]`)。
  SPC / `x` でページを変え、先頭候補での C-p は ▽ に戻る。Enter / C-j で確定、Backspace か
  C-g で ▽ に戻り、他のかなキーは確定して続ける。
- 候補のない読み、または最後の候補を越えた SPC は、DDSKK の辞書登録プロンプト
  `辞書登録 「よみ」: ` を開く (中でも SKK が使える)。単語を入れて Enter でユーザー辞書に登録して
  挿入し (送り仮名付き)、空の Enter か C-g で読みを残して ▽ に戻る。別のプロンプトの中では
  `No candidates for …` と言って ▽ に戻るだけ。
- 他のコマンド (C-a、C-f、M-x、C-x …) は、DDSKK と同様にまず SKK の進行中の入力を確定して
  から実行されるので、▽ / ▼ が元のカーソル位置に取り残されない。SKK はアクティブな Windows
  IME の変換中には関与しない。find-file、write-file、agent、バッファ、consult-line、isearch の
  ミニバッファも SKK を使う。y/n と goto-line のプロンプトは通さない。
- メイン辞書は `$env:DARGER_SKK_JISYO`、なければ `~/Dropbox/.emacs.d/skk-get-jisyo/SKK-JISYO.L`、
  `~/.emacs.d/skk-get-jisyo/SKK-JISYO.L`、`~/.skk/SKK-JISYO.L`、`/usr/share/skk/SKK-JISYO.L` の
  うち最初に存在するもの (1 行目に `coding: euc-jp` クッキーがあれば EUC-JP、なければ UTF-8)。
  最初の切替時に読み込み、`SKK: N entries loaded (t ms)` と報告する。なくてもかな入力は動き、
  変換は `No dictionary` と言う。
- ▼ からの確定のたびに選択を先頭に動かし、`~/.darger-skk-jisyo` (UTF-8 の SKK 形式。最初に
  検索され、キーは最近順ではなくソート) を書き直す。Emacs の `~/.skk-jisyo` には触れない。
- 未実装: `l` 接頭辞の小書き (DDSKK と同じく `l` はラテンモードのキーなので `x` を使う)、
  送り `[…]` ブロック、`(concat …)` 評価。

Windy 0.5.0 は Windows の WM_KEYDOWN の繰り返しイベントを `onButtonPress` に転送するので、
押しっぱなしのコマンドキーは OS ネイティブのリピートを使います。`onRune` は印字可能な
テキストだけを扱います。

Nimble が `~/.nimble/nimbledata2.json` を更新できないサンドボックスでは、インストール済みの
`pkgs2` ディレクトリと `*.json` ファイルを `~/.nimble` から `nimcache/nimble` にコピーし、
次を使います。

```powershell
nimble --nimbleDir:nimcache/nimble --offline build -d:release
```

コンパイラのキャッシュファイルはすべてプロジェクトの `nimcache/` ディレクトリ以下に残ります。
