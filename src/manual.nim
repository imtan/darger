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
C-s / C-r                前方 / 後方インクリメンタル検索
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

[バッファ]
C-x b                    バッファを切り替え（無い名前なら新規）
C-x k                    バッファを閉じる（変更ありなら確認）
C-x C-b                  バッファ一覧（Enter:切替 k:閉じる）
C-x ← / C-x →            前 / 次のバッファへ

[日本語入力]
C-x C-j / C-\            SKK の入れ / 切り
                         モードライン: [かな] [カナ] [SKK]
                         大文字で読み開始 SPC:変換 Enter:確定
                         q:カナ切替 l:英数 C-j:かなに戻る

[エージェント]
C-c a                    agent-command に指示を送る
                         実行中は C-g で中止
                         差分: y:採用 k:見送り a:全採用
                         n / p:次 / 前の差分 q:終了 C-g:破棄

C-c c                    プロジェクト単位の agent-chat（複数ターン会話）
                         空入力で Enter: 既存の会話を表示、C-g: 実行中止
                         *agent ディレクトリ名* は C-x b でも開ける
                         別バッファを見ている間の返信はエコー欄で通知
                         バッファを消すと会話も破棄。保存確認なし
M-x agent-chat-new       現在のルートの会話を空にして新規セッションへ
                         その会話の実行中はリセット不可
会話のルート             ファイルの最寄りの .git、なければそのディレクトリ
                         会話からは同じルート、その他は作業ディレクトリから探索
設定                     agent-chat-command / agent-chat-resume-command
                         {id} は UUID に置換。最初の成功後は resume を使用
                         既定の claude -p は読み取りのみ（Claude Code 側で許可済みの操作は除く）
                         両設定に --permission-mode acceptEdits で編集を許可
                         ディスクの変更は再読込されないため保存時の上書きに注意

[その他]
C-g                      操作を中断
F1                       このヘルプを表示 / 閉じる
M-x dashboard            起動画面（最近のファイル一覧）を表示
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
"""
