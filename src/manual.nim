## F1 key reference shown in help mode.

const manualText* = """
darger キー操作一覧      q / Enter / F1 で閉じる
C- は Ctrl、M- は Alt。左右どちらの修飾キーでも可。
F1 でこの画面を表示。C-n C-p C-v M-v でスクロール。

[移動]
C-f / C-b / C-n / C-p    文字・行を移動（矢印キーも可）
C-a / C-e                行頭 / 行末（Home / End も可）
M-f / M-b                単語単位で移動
M-m                      行のインデント位置へ
M-< / M->                バッファ先頭 / 末尾（C-Home / C-End）
C-v / M-v                次 / 前のページ（PageDown / PageUp）
C-l                      カーソル行を中央 / 上 / 下に再表示
M-g g / M-g M-g          行番号を指定して移動
M-g l                    行を絞り込んで移動（C-g で元の位置）
M-g f                    診断（エラー・警告）一覧から移動

[言語サーバー]
C-M-i                    補完候補を表示（入力中は自動で表示）
                         C-n / C-p で選択、Enter / Tab で確定
C-c h                    カーソル位置の説明（ホバー）を表示
M-. / M-,                定義へ移動 / 移動前の位置へ戻る
M-?                      参照の一覧から移動（C-g で元の位置）
C-c =                    バッファ全体を整形（C-/ で元に戻す）

[編集]
Enter / C-m / C-j        改行
Tab / C-i                次の 4 桁位置まで空白を挿入
Backspace / C-h          前の文字を削除
C-d / Delete             次の文字を削除
C-o                      カーソル位置に空行を開く
C-t                      前後の文字を入れ替え
C-k                      行末まで削除
M-d / M-Backspace        次 / 前の単語を削除
M-u / M-l / M-c          単語を大文字 / 小文字 / 先頭だけ大文字

[選択とコピー]
C-SPC / C-@              マークを置く（もう一度で解除）
C-x C-x                  マークとカーソルを交換
C-x h                    全選択
C-w / M-w                切り取り / コピー
C-y / M-y                貼り付け / 貼り付け履歴を巡回

[取り消し]
C-/  C-_  C-x u          元に戻す

[検索]
C-s / C-r (migemo: ローマ字で日本語も一致)                前方 / 後方インクリメンタル検索
                         繰り返し押すと次 / 前の一致へ
                         Enter で確定、C-g で元の位置に戻る

[ファイル]
C-x C-f                  ファイルを開く（無ければ新規）
C-x C-s                  保存
C-x C-w                  別名で保存
C-x C-c                  終了

[ファイラ (Dired)]
C-x d / M-x dired        ディレクトリ一覧（C-x d Enter で今のディレクトリ）
n / p / C-n / C-p        次 / 前の項目（上下矢印も可）
C-v / M-v / M-< / M->    ページ移動 / 先頭 / 末尾
Enter / f                ファイルを開く / ディレクトリに入る
^ / g                    親ディレクトリ / 再読み込み
+ / R                    ディレクトリ作成 / 改名（上書き不可）
D                        ごみ箱へ移動（y / n で確認、完全削除しない）
q / C-g / Escape         一覧を閉じる（作成・改名の入力中は一覧に戻る）

[Web ブラウザ (eww)]
C-c w / M-x eww          URL か検索語を入力（空で Enter: 前回のページ）
                         ドットを含む語は https:// を補う。他は eww-search-prefix で検索
                         取得は fetch-command（既定は curl）でバックグラウンド実行
Tab / Shift-Tab          次 / 前のリンクへ
Enter / f                カーソル位置（なければ行の先頭）のリンクを開く
l / r                    戻る / 進む
g / G                    再読み込み / 別の URL を入力
&                        リンク（なければページ）を OS のブラウザで開く
w / v                    URL をコピー / HTML ソースを *web source* に開く
n / p / C-v / M-v        行 / ページ移動（SPC / Backspace もページ）
q / C-g / Escape         閉じる（読み込み中の C-g は中止）。C-c w Enter で再表示
                         文字コードはヘッダ / meta / XML 宣言から判定（Shift_JIS, EUC-JP 等）
                         フィードの URL は記事一覧として表示。画像・PDF は表示しない

[RSS リーダー]
C-c r / M-x rss          購読フィードの記事一覧（新しい順、既読は暗く表示）
                         購読は ~/.darger-feeds（1 行 1 URL）と (rss-feed "url")
Enter / f                記事を既読にして本文を表示（q で一覧に戻る）
& / b                    記事を OS のブラウザで開く
r / u / R                既読 / 未読 / 表示中の全記事を既読に
g                        全フィードを再取得（到着順に一覧へ反映）
a                        フィード URL を追加（~/.darger-feeds に追記）
s                        フィード名と題名で絞り込み（空で解除）
w                        記事の URL をコピー
q / C-g / Escape         一覧を閉じる（取得は続く）
                         既読は ~/.darger-rss-read に保存。記事本文は保存しない

[バッファ]
C-x b                    バッファを切り替え（無い名前なら新規）
C-x k                    バッファを閉じる（変更ありなら確認）
C-x C-b                  バッファ一覧（Enter:切替 k:閉じる）
C-x ← / C-x →            前 / 次のバッファへ

[ウィンドウ]
C-x 2 / C-x 3            下 / 右に分割（同じバッファを表示）
C-x o                    次のウィンドウへ（クリックでも選択。クリック位置にカーソル、ホイールでスクロール）
C-x 0 / C-x 1            このウィンドウを消す / 他を全部消す
C-x ^ / C-x } / C-x {    縦に広げる / 横に広げる / 横に狭める   C-x + で均等化
C-x 4 b / C-x 4 f        他のウィンドウにバッファ / ファイルを開く
C-c ← → ↑ ↓              その方向のウィンドウへ (windmove)

[日本語入力]
C-x C-j / C-\            SKK の入れ / 切り
                         モードライン: [かな] [カナ] [SKK]
                         大文字で読み開始 SPC:変換 Enter:確定
                         ▼で C-n / C-p (矢印) 候補を 1 つずつ x:戻る
                         5 件目から候補一覧 a s d f j k l で選択
                         候補なし: 辞書登録プロンプト (空 Enter / C-g で ▽ に戻る)
                         ▽で Tab: 読みを辞書の見出し語で補完 (繰り返しで次)
                         /: abbrev (英字の読み。/dog SPC → 犬 など)
                         q:カナ切替 l:英数 L:全角英数 C-j:かなに戻る 他のコマンドは確定してから実行
                         (setq skk-egg-like-newline nil) で Enter が確定 + 改行

[エージェント]
C-c a                    agent-command に指示を送る (結果はレビューで y/k/u/n/p/l/w/a/A/q、? でキー一覧)
  r (レビュー中)         今のハンクへの修正指示をエージェントに送り、再提案を受け取る
M-x diff-buffer-with-file  ディスク上のファイルとの差分をレビュー (保存時の確認でも r)
M-x vc-review            git HEAD との差分をレビュー。M-x review-file は別ファイルとの比較
M-x agent-changes        直前のチャットターンで変わったファイル一覧。Enter でレビュー
  x (レビュー中)         今のハンクの説明をエージェントに求める (*explain*)。説明なしで採用 → 理解負債
  X (レビュー中)         今のハンクについて質問する。答えは説明に追記され台帳にも残る
  U (レビュー中)         説明なしで「理解した」と自己申告 (DONE で記録)
M-x understanding-debt   理解台帳 (~/.darger-understanding.org) の今のブランチの未返済一覧 (-all で全部)
M-x branch-debt          このブランチで base から変わったファイルのうち未理解のもの。Enter で base と比較レビュー
C-c u                    *understanding* バッファ: ブランチの未理解 / 理解済みファイル、未返済エントリ、用語集
                         Enter で比較 (閉じると戻る) / 負債の場所へ、b で base ブランチ選択、U でファイル全体を理解済み、
                         o 台帳、g 再構築、q 閉じる
M-x glossary             説明から集めた用語集 (~/.darger-glossary.org) を引く
                         実行中は C-g で中止
                         差分: y:採用 k:見送り a:全採用
                         n / p:次 / 前の差分 q:終了 C-g:破棄

C-c c                    プロジェクト単位の agent-chat（複数ターン会話）
                         空入力で Enter: 既存の会話を表示、C-g: 実行中止
                         *agent ディレクトリ名* は C-x b でも開ける
                         別バッファを見ている間の返信はエコー欄で通知
                         バッファを消すと会話も破棄。保存確認なし
                         回答とツール名・要約を逐次表示。実行中の末尾は ...
                         最終行にカーソルがあれば追従、上へ移動すると停止
                         取消・失敗でも途中の出力を残す。Undo 履歴は増えない
                         改行まで届いた出力だけを表示。通常のテキスト出力も対応
実行状況                 Agent running 1:23 と最新のツール活動をエコー欄に表示
                         C-c a も経過時間を表示。取消中は Agent cancelling...
M-x agent-chat-new       現在のルートの会話を空にして新規セッションへ
                         その会話の実行中はリセット不可
会話のルート             ファイルの最寄りの .git、なければそのディレクトリ
                         会話からは同じルート、その他は作業ディレクトリから探索
設定                     agent-chat-command / agent-chat-resume-command
                         {id} は UUID に置換。最初の成功後は resume を使用
                         既定は claude -p --output-format stream-json --verbose
                         初回は --session-id {id}、継続は --resume {id}
                         既定の claude -p は読み取りのみ（Claude Code 側で許可済みの操作は除く）
                         両設定に --permission-mode acceptEdits で編集を許可
                         未編集バッファはディスクの変更に追従 (Reverted)。編集済みは保存時に確認

[Org / org-roam]  （.org ファイルで。ノートは org-roam-directory、既定 ~/org-roam）
C-c C-t                  見出しの TODO を巡回 (org-todo-keywords。選択キーがあれば 1 キー選択)
C-c C-c                  チェックボックス [ ] / [X] を切り替え
M-Enter                  同じ階層の見出し・項目を下に追加
M-left / M-right         見出しの階層を上げる / 下げる
M-up / M-down            サブツリーを上 / 下の兄弟と入れ替え
TAB / Shift-TAB          見出しの折りたたみ（FOLDED → CHILDREN → SUBTREE）/ 全体（OVERVIEW → CONTENTS → SHOW ALL）
                         #+startup: folded のファイルは折りたたんで開く。検索や移動で隠れた行に着くと開く
C-c C-j                  見出し一覧から移動（C-g で元の位置）
C-c C-o                  リンクを開く（id: / file: / URL / *見出し）
C-c .                    今日の日付 <2026-10-07 Wed> を挿入
C-c n f                  ノートを題名で検索して開く（無ければ作成。M-Enter で入力どおり）
C-c n i                  ノートへのリンク [[id:…][題名]] を挿入（無ければ作成）
C-c n c / C-c n t        題名とテンプレートからノートを作成 / #+filetags: にタグを追加
C-c n g                  ノートのグラフをブラウザで開く
C-c n l                  このノートへのバックリンク一覧（C-g で元の位置）
C-c n d                  今日のデイリーノート daily/日付.org を開く
C-c n j                  今日のデイリーに時刻の見出しを足す
C-c n s                  Org ディレクトリを全文検索 (M-x consult-ripgrep はプロジェクト)
C-x p f / p / b          プロジェクトのファイルを開く / プロジェクト切替 / プロジェクトのバッファ
C-c l                    エージェントに「どこ?」と聞き、答えを *places* (grep バッファ風) で開く
  n / p / Enter / o / q  場所を移動 (隣のウィンドウが追従) / そこへ移動 / 編集切替 / 離れる (普通のバッファ。C-x o 可)
M-x places               今のバッファを places 一覧として開く (-*- mode: grep -*- のファイルは自動)
M-x agent-references     今のバッファ (チャットの記録など) が挙げる path:line を一覧で開く
M-x org-id-get-create    ファイルに ID を付けてノートにする
C-c j                    日報 (org-journal)。org-journal-dir の今日のファイルに時刻見出しを足す
                         org-journal-condition-prompt t なら体調 [1-5] を 1 キーで聞く (★)
C-c t                    capture。入力を org-capture-file の org-capture-headline の下に追記
C-M-e / C-c e            Eagle の画像をキーワード / フォルダから選んで [[file:~/…]] を挿入
C-M-y                    クリップボードの画像を img/日時.png に保存して [[file:img/…]] を挿入
M-x org-agenda           org-agenda-files の今日の予定・期限・TODO を一覧 (Enter で移動、C-g で戻る)

[シェル]
C-c s                    *shell* を開く (comint 風。Enter で送信、C-c C-c 割り込み、C-d で EOF)
M-x term                 *terminal*: 全画面対応の端末 (全キーをプログラムへ。C-x / C-c は darger)
  C-c C-j / C-c C-k      行モード (普通に編集し Enter で送る。SKK 可) / 文字モードに戻す
C-c C c / C-c C t        Claude Code を右のウィンドウで起動・フォーカス / 隠す・出す
C-c C n / C-c C r / C-c C f  新セッション / リージョンを送る / このファイルを見てと送る

[背景シェーダー]  （.glsl バッファで。(background-shader "path") を ~/.darger.el に）
C-c C-c                  このバッファを背景シェーダーとして適用（保存・外部変更でも再適用）
C-c C-o                  絵だけ ↔ うっすら背景（background-shader-dim、既定 0.6）
C-c C-k                  解除。エラーは *shader* バッファとエコー行に

[その他]
C-g                      操作を中断
F1                       このヘルプを表示 / 閉じる
M-x dashboard            起動画面（最近のファイル一覧）を表示
M-x darger-update        GitHub に新しいコミットがあれば取り込んで再ビルド
                         実行中は Updating darger ... をエコー欄に表示、C-g で中止
                         結果: up to date / updated to ハッシュ（要再起動）/ failed
                         各手順の出力は *darger update* バッファ（C-x b）
                         対象は実行ファイルのあるチェックアウト。ローカルの
                         未プッシュコミットと衝突する場合は取り込まない
設定                     darger-source-directory（既定: 実行ファイルの場所）
                         darger-build-command（既定: nimble -y build -d:release）
F2 g / l / 0             文字の拡大 / 縮小 / 元に戻す（連打可）
C-c ,                    設定ファイル ~/.darger.el を開く
M-x                      コマンド名を入力して実行
M-:                      Lisp 式を評価
ミニバッファ             C-a C-e C-f C-b C-k C-y が使える
                         Enter で確定、C-g で中止
候補一覧                 空白区切りの語を順不同で絞り込み
                         C-n / C-p で選択、C-v / M-v で 10 件
                         Tab で候補を入力に、Enter で選択を確定
                         M-Enter で入力どおりに確定
確認プロンプト           y または n のあと Enter

設定ファイル: ~/.darger.el
  (global-set-key "C-c f" 'forward-word)
  (setq agent-command "...")
  (load-theme "catppuccin")    ; 既定は modus-vivendi
  (set-font "/path/mono.ttf")  ; 主フォント。DARGER_FONT と既定より優先、読めなければ現状維持
  (set-fallback-fonts "/path/a.ttc;/path/b.ttf")  ; 代替フォントを ; 区切りで置き換え
  (rss-feed "https://example.com/feed.xml")
  (setq fetch-command "curl -sSL --max-time 30 --compressed")
  (setq darger-build-command "nim c -d:release --outdir:. src/darger.nim")
"""
