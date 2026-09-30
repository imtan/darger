import std/[os, tempfiles]
import ../src/chat

let id = sessionId()
doAssert id.len == 36
for i, c in id:
  if i in [8, 13, 18, 23]: doAssert c == '-'
  else: doAssert c in {'0'..'9', 'a'..'f'}
doAssert id[14] == '4'
doAssert id[19] in {'8', '9', 'a', 'b'}
doAssert sessionId() != id
doAssert expandId("cli {id} --resume {id}", id) == "cli " & id & " --resume " & id
doAssert expandId("cli", id) == "cli"

let tree = createTempDir("darger-chat-test-", "")
try:
  let nested = tree / "project" / "src"
  createDir(nested)
  doAssert rootFromDir(nested) == nested
  createDir(tree / ".git")
  doAssert rootFromDir(nested) == tree
  writeFile(tree / "project" / ".git", "gitdir: elsewhere")
  doAssert rootFromDir(nested) == tree / "project"
  doAssert rootFromDir(tree / "project") == tree / "project"
finally:
  removeDir(tree)

let heading = "# Agent chat: /project"
let turn = appendTurn("", "/project", "hello 日本語")
let prefix = heading & "\n\n## You\nhello 日本語\n\n## Agent\n"
doAssert turn.text == prefix & "..."
doAssert turn.agentLine == 5
doAssert turn.replyStart == prefix.len
doAssert replaceReply(turn, "reply\r\n  \t") == prefix & "reply"
let reply = "```md\r\n...\r\n## Agent\r\n```\r\n"
let answered = replaceReply(turn, reply)
doAssert answered == prefix & "```md\n...\n## Agent\n```"
let next = appendTurn(answered, "/project", "next\nline")
doAssert next.text == answered & "\n\n## You\nnext\nline\n\n## Agent\n..."
doAssert replaceReply(next, "done") == answered & "\n\n## You\nnext\nline\n\n## Agent\ndone"
doAssert failureLine("\r\n \t\r\n error here \r\nmore", 1) == "error here"
doAssert failureLine(" \r\n", 7) == "exit code 7"
doAssert replaceReply(turn, "(failed: " & failureLine("error", 1) & ")") == prefix & "(failed: error)"
doAssert replaceReply(turn, "(cancelled)") == prefix & "(cancelled)"
doAssert replaceReply(turn, "(failed: reply is not valid UTF-8)") == prefix & "(failed: reply is not valid UTF-8)"
doAssert replaceReply(turn, "") == prefix

echo "chat ok"
