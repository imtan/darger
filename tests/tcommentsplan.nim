{.define: headless.}
import std/[os, osproc, strutils, tables, times, unicode, sequtils, tempfiles]
import ../src/[core, buffer, buffers, render, lisp, syntax, review]
import ../src/ext/[agent, agentplan, reviewcomments, branchdiff, magit]

# The shell must set HOME before importing core (as for every headless test).
let home = createTempDir("darger-comments-plan-", "")
putEnv("HOME", home)
let repo = home / "repo"
createDir(repo)
proc git(args: string) =
  let r = execCmdEx("git -C " & quoteShell(repo) & " -c commit.gpgsign=false " & args)
  doAssert r.exitCode == 0, r.output
proc eval(s: string) = discard interp.evalString(s, "<comments-plan-test>")
proc call(name: string) = discard interp.call(symbol(name), @[])
proc key(name, value: string) = discard interp.call(symbol(name), @[stringValue(value)])
proc at(prefix: string) =
  for i, line in b.lines:
    if ($line).startsWith(prefix):
      b.cursor = (i, 0)
      return
  doAssert false, "Missing " & prefix & " in " & b.text
proc comment(text: string) =
  call("review-comment")
  doAssert mode == "review-comment"
  setMini(text)
  confirmMini()
proc waitAgent() =
  let deadline = epochTime() + 5
  while agentProcess != nil and epochTime() < deadline:
    discard pollAgent()
    sleep(10)
  doAssert agentProcess == nil
proc rejected(name: string) =
  var failed = false
  try: call(name)
  except CatchableError: failed = true
  doAssert failed, name

echo "workflow: init"
renderer = Renderer(frameCols: 100, frameRows: 40)
layoutPanes()
eval(defaultBindings)
for source in defaults: eval(source)
eval("(setq understanding-ledger nil)")
eval("(setq agent-notify nil)")
let globals = keymap
echo "workflow: git"
git("init -b main")
git("config user.name Test")
git("config user.email test@example.invalid")
writeFile(repo / "file.nim", "before\ncontext\n")
git("add .")
git("commit -m initial")
writeFile(repo / "file.nim", "after\ncontext\n")
let origin = newBuffer("after\ncontext\n")
origin.path = repo / "file.nim"
switchTo(origin)

# A fake local Claude never calls a service; its arguments and stdin are evidence.
let bin = home / "bin"
createDir(bin)
let fake = bin / "claude"
let input = home / "input"
let argv = home / "argv"
let reply = home / "reply"
writeFile(fake, "#!/bin/sh\nprintf '%s\\n' \"$@\" > " & quoteShell(argv) &
  "\ncat > " & quoteShell(input) & "\ncat " & quoteShell(reply) & "\n")
setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})
putEnv("PATH", bin & ":" & getEnv("PATH"))
writeFile(reply, "{\"type\":\"result\",\"result\":\"# Plan\\nDo the task\\n\",\"is_error\":false}\n")

echo "workflow: branch"
openBranchDiff()
let diff = b
at("+after")
let originalDiff = b.text
comment("追加行を直して")
doAssert b.text == originalDiff and comments.len == 1
doAssert comments[0].anchor.line == 1 and comments[0].anchor.content == "after"
doAssert pictures(diff).extra[diff.cursor.line] == 1
let pics = pictures(diff)
doAssert pics.pictures[0].annotation == "追加行を直して"
doAssert pointAt(diff.lines, @[], 0, 0, 0, 3, diff.cursor.line + 1, pics.extra).line == diff.cursor.line
key("branch-diff-key", "g")
at("+after")
doAssert pictures(diff).extra[diff.cursor.line] == 1
call("review-comments")
doAssert candAll.len == 1
setMini(candAll[0])
confirmMini()
doAssert b == diff and ($b.lines[b.cursor.line]) == "+after"
comment("更新したコメント")
doAssert comments.len == 1
call("review-comment-delete")
doAssert comments.len == 0
comment("再送コメント")
at("-before")
comment("削除の理由は？")
doAssert comments.len == 2
echo "workflow: send"
# Launch refusal leaves all comments available for retry.
eval("(setq agent-chat-command \"\")")
rejected("review-comments-send")
doAssert comments.len == 2
eval("(setq agent-chat-command \"claude -p --session-id {id}\")")
call("review-comments-send")
doAssert comments.len == 2
waitAgent()
doAssert comments.len == 0
doAssert "file.nim:1" in readFile(input) and "-before" in readFile(input)
doAssert readFile(input).endsWith("これらのコメントに対応して")
let session = chats[repo]
let sessionId = session.id

echo "workflow: magit"
# The same anchor in magit reuses comments, including after refresh and folds.
switchTo(origin)
call("magit-status")
let status = b
doAssert status.hasLocalKey("c") and status.hasLocalKey("C")
doAssert status.hasLocalKey("C-c C-k") and not status.hasLocalKey("S")
key("magit-key", "tab")
at("+after")
comment("magit コメント")
key("magit-key", "g")
at("+after")
doAssert pictures(status).extra[status.cursor.line] == 1
switchTo(diff)
key("branch-diff-key", "g")
at("+after")
doAssert pictures(diff).extra[diff.cursor.line] == 1

echo "workflow: review"
# Review annotations never modify the target or alter y/k decisions.
switchTo(origin)
beginReview("proposal\ncontext\n")
let display = b
at("+proposal")
comment("提案のコメント")
doAssert origin.text == "after\ncontext\n" and "+proposal" in display.text
doAssert pictures(display).extra[display.cursor.line] == 1
dispatchReview("|")
doAssert sideBufs[1].hasLocalKey("c")
switchTo(sideBufs[1])
at("proposal")
doAssert pictures(b).extra[b.cursor.line] == 1
dispatchReview("|")
dispatchReview("k")
dispatchReview("q")
doAssert origin.text == "after\ncontext\n"
doAssert keymap == globals

echo "workflow: plan"
# Plan-only request resumes the same session, and approval sends the edited plan.
switchTo(origin)
call("agent-plan")
setMini("改善 / 計画")
confirmMini()
waitAgent()
let plan = b
doAssert reg.displayName(plan) == "*agent-plan*" and langOf(plan).name == "Markdown"
doAssert not plan.isReadOnly and plan.hasLocalKey("c")
doAssert plan.hasLocalKey("C-c C-c") and plan.hasLocalKey("C-c C-k")
doAssert "--resume\n" & sessionId in readFile(argv)
doAssert "--permission-mode\nplan" in readFile(argv)
doAssert "コードはまだ変更せず" in readFile(input)
let view = commentView(plan)
let saved = repo / view.anchors[0].path
doAssert fileExists(saved) and readFile(saved) == plan.text
plan.splice(0, plan.text.runeLen, "# Edited plan\nTest first\n")
plan.cursor = (1, 0)
comment("回帰も確認")
rejected("review-comments-send")
doAssert agentProcess == nil
writeFile(reply, "{\"type\":\"result\",\"result\":\"failed implementation\",\"is_error\":true}\n")
call("agent-plan-approve")
waitAgent()
doAssert comments.anyIt(it.text == "回帰も確認")
switchTo(plan)
writeFile(reply, "Implemented; review the changes\n")
call("agent-plan-approve")
doAssert readFile(saved) == "# Edited plan\nTest first\n"
waitAgent()
doAssert "--resume\n" & sessionId in readFile(argv)
doAssert "--permission-mode\ndefault" in readFile(argv)
doAssert "この計画どおりに実装して" in readFile(input)
doAssert "# Edited plan" in readFile(input) and "回帰も確認" in readFile(input)
doAssert comments.allIt(it.anchor.path != view.anchors[0].path)
doAssert comments.len == 2 # unrelated diff comments retained
switchTo(plan)
rejected("agent-plan-approve")

echo "workflow: nil"
# nil storage, busy/changed-session protection and discard do not launch work.
eval("(setq agent-plan-directory nil)")
switchTo(origin)
call("agent-plan")
setMini("unsaved plan")
confirmMini()
rejected("agent-plan")
let retained = comments
rejected("review-comments-send")
doAssert comments == retained
waitAgent()
let unsaved = b
let unsavedPath = repo / commentView(b).anchors[0].path
doAssert not fileExists(unsavedPath)
comment("discard this")
chats[repo].id = "changed-session"
rejected("agent-plan-approve")
doAssert agentProcess == nil
call("agent-plan-discard")
doAssert b == origin and not fileExists(unsavedPath)
doAssert comments.allIt(it.anchor.path != relativePath(unsavedPath, repo))
switchTo(unsaved)
rejected("agent-plan-approve")
chats[repo].id = sessionId

echo "workflow: failed"
# Failed output cannot become an approvable plan.
let before = reg.slots.len
writeFile(reply, "{\"type\":\"result\",\"result\":\"bad\",\"is_error\":true}\n")
switchTo(origin)
call("agent-plan")
setMini("fail")
confirmMini()
waitAgent()
doAssert reg.slots.len == before and "failed or cancelled" in echoLine
# A failed feedback turn preserves all comments too.
switchTo(diff)
let beforeFailedSend = comments
call("review-comments-send")
waitAgent()
doAssert comments == beforeFailedSend

# A fresh session uses the configured plan command and relative storage directory.
writeFile(reply, "# Fresh plan\nNo code yet\n")
switchTo(origin)
call("agent-chat-new")
eval("(setq agent-plan-command \"claude -p --session-id {id} --permission-mode plan --custom-test\")")
eval("(setq agent-plan-directory \"alternate-plans\")")
call("agent-plan")
setMini("fresh")
confirmMini()
waitAgent()
let fresh = b
let freshId = chats[repo].id
doAssert "--session-id\n" & freshId in readFile(argv) and "--custom-test" in readFile(argv)
let freshPath = repo / commentView(fresh).anchors[0].path
doAssert parentDir(freshPath) == repo / "alternate-plans" and fileExists(freshPath)
call("agent-plan-discard")
doAssert fileExists(freshPath)

# Cancellation drops the reply and does not manufacture a plan buffer.
switchTo(origin)
let countBeforeCancel = reg.slots.len
call("agent-plan")
setMini("cancel")
confirmMini()
cancelAgent()
waitAgent()
doAssert reg.slots.len == countBeforeCancel and "failed or cancelled" in echoLine

doAssert keymap == globals
let disk = decodeComments(readFile(home / ".darger-review-comments.json"))
doAssert disk == comments

echo "diff/magit/review comments, display-only rows, persistence, session plans and approval guards ok"
