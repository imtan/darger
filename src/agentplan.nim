## Plan command selection and Markdown persistence names, without editor state.
import std/[strutils, os, unicode]

proc planCommand*(normal, configured: string, resumed: bool): string =
  if strutils.strip(configured).len > 0:
    result = configured
    if resumed: result = result.replace("--session-id", "--resume")
    return
  result = normal
  let words = strutils.splitWhitespace(normal)
  if words.len > 0 and extractFilename(strutils.strip(words[0], chars = {'\'', '"'})) in ["claude", "claude.exe"]:
    result.add " --permission-mode plan"

proc planTitle*(request: string): string =
  for rune in request.toRunes:
    if result.runeLen >= 48: break
    if rune.int < 128 and (char(rune) in {'/', '\\', ':', '*', '?', '"', '<', '>', '|', '.', ' '} or rune.int < 32):
      if result.len > 0 and result[^1] != '-': result.add '-'
    else: result.add $rune
  result = strutils.strip(result, chars = {'-'})
  if result.len == 0: result = "plan"

proc planningPrompt*(request: string): string =
  request & "\n\nコードはまだ変更せず、計画だけを Markdown で書いて。ファイルの作成・変更やコマンドによる更新はしないで。"

proc approvalPrompt*(plan, comments: string): string =
  "この計画どおりに実装して。変更は通常のレビューを通して。\n\n" & plan &
    (if comments.len > 0: "\n\n計画へのコメント:\n" & comments else: "")

proc implementationCommand*(normal: string): string =
  result = normal
  let words = strutils.splitWhitespace(normal)
  if words.len > 0 and extractFilename(strutils.strip(words[0], chars = {'\'', '"'})) in ["claude", "claude.exe"] and
      "--permission-mode" notin normal:
    result.add " --permission-mode default"
