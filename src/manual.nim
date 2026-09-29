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
確認プロンプト           y または n のあと Enter

設定ファイル: ~/.darger.el
  (global-set-key "C-c f" 'forward-word)
  (setq agent-command "...")
  (load-theme "catppuccin")    ; 既定は modus-vivendi
"""
