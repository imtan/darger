import std/strutils
import ../src/[reviewcomments, agentplan, review]

let anchor = CommentAnchor(path: "日本語/a.nim", line: 2, content: "  new", excerpt: "+  new")
let first = ReviewComment(root: "/repo", anchor: anchor, text: "境界も確認して")
var comments: seq[ReviewComment]
comments.putComment(first)
comments.putComment(ReviewComment(root: "/other", anchor: anchor, text: "別リポジトリ"))
doAssert decodeComments(encodeComments(comments)) == comments
var edited = first
edited.text = "説明を追加して"
comments.putComment(edited)
doAssert comments.len == 2 and comments[0].text == edited.text
doAssert comments.findComment("/repo", anchor) == 0
doAssert comments.findComment("/absent", anchor) == -1
var stale = anchor
stale.content = "changed"
doAssert comments.findComment("/repo", stale) == -1
stale = anchor
inc stale.line
doAssert comments.findComment("/repo", stale) == -1
let prompt = commentPrompt(comments, "/repo")
doAssert "日本語/a.nim:2\n+  new\nコメント: 説明を追加して" in prompt
doAssert "別リポジトリ" notin prompt and prompt.endsWith("これらのコメントに対応して")
doAssert commentPrompt(comments, "/absent") == ""
doAssert comments.withoutSent(@[first]).len == 2 # a newer edit is never cleared
doAssert comments.withoutSent(@[edited]) == @[comments[1]]
for bad in ["{", "{}", "{\"version\":2,\"repositories\":{}}", "{\"version\":1,\"repositories\":{\"/r\":[{\"path\":\"a\",\"line\":0,\"content\":\"x\",\"excerpt\":\"+x\",\"text\":\"c\"}]}}"]:
  var failed = false
  try: discard decodeComments(bad)
  except CatchableError: failed = true
  doAssert failed

doAssert planCommand("claude -p --session-id {id}", "", false).endsWith("--permission-mode plan")
doAssert planCommand("/bin/claude -p --resume {id}", "", true).endsWith("--permission-mode plan")
doAssert planCommand("other-cli", "", false) == "other-cli"
doAssert planCommand("claude", "custom --session-id {id}", true) == "custom --resume {id}"
doAssert implementationCommand("claude --resume {id}").endsWith("--permission-mode default")
doAssert implementationCommand("claude --permission-mode acceptEdits") == "claude --permission-mode acceptEdits"
doAssert implementationCommand("claude --permission-mode=acceptEdits") == "claude --permission-mode=acceptEdits"
doAssert planTitle("../../ 日本語: 計画\n") == "日本語-計画"
doAssert planTitle("/") == "plan"
doAssert "コードはまだ変更せず" in planningPrompt("task")
doAssert "編集した計画" in approvalPrompt("編集した計画", "コメント")

# Source positions survive decisions and insertion/deletion offsets, in both views.
var r = newReview("a\nb\nc\nd\n", "a\nB\nextra\nc\n")
let view = r.view(0)
doAssert view.newLines == @[1, 2, 2, 3, 4, 4]
doAssert view.newLines.len == view.colors.len
let sides = r.sideBySide(0)
doAssert sides.left.newLines == @[1, 2, 0, 4, 4]
doAssert sides.right.newLines == @[1, 2, 3, 4, 0]
r.decisions[0] = rejected
doAssert r.view(0).newLines == @[1, 2, 4, 4]
r.decisions[0] = accepted
doAssert r.view(0).newLines == @[1, 2, 3, 4, 4]
echo "comment persistence, exact anchors, prompts, plan commands and review positions ok"
