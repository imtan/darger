import std/[os, tempfiles, strutils, json]
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

let sample = """{"type":"system","subtype":"hook_started"}
{"type":"system","subtype":"init"}
{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"..."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"C:\\proj\\src\\a.txt"}}]}}
{"type":"rate_limit_event"}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"1\tsample"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"nim r tests/tchat.nim","description":"Run the chat tests"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"The file holds `sample`."}]}}
{"type":"result","subtype":"success","is_error":false,"result":"The file holds `sample`.","num_turns":2}
"""
let rendered = renderOutput(sample)
let tools = "> Read: C:\\proj\\src\\a.txt\n> Bash: Run the chat tests"
doAssert rendered.reply == tools & "\n\nThe file holds `sample`."
doAssert rendered.activity == "Bash: Run the chat tests"
doAssert rendered.resultSeen and not rendered.isError
doAssert renderOutput(sample & "{\"type\":\"assistant\"}\n").reply == rendered.reply
doAssert renderOutput(sample & "\xff\n") == rendered
let cut = sample.find("The file holds") + 5
doAssert renderOutput(sample[0..<cut]).reply == tools
doAssert not renderOutput(sample[0..<cut]).resultSeen
doAssert not renderOutput(sample.strip).resultSeen  # result has no newline yet

let japanese = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"日本語\"}]}}\n"
let beforeText = sample[0..<sample.find("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\"")]
doAssert renderOutput(beforeText & japanese[0..japanese.find("日")]).reply == tools
doAssert renderOutput(beforeText & japanese).reply == tools & "\n\n日本語"

let parts = """{"type":"assistant","message":{"content":[
{"type":"text","text":"First"},
{"type":"tool_use","name":"Bash","input":{"description":"", "command":"echo a\r\necho b\necho c"}},
{"type":"thinking","thinking":"hidden"},
{"type":"tool_use","name":"Read","input":{}},
{"type":"text","text":"Last"}]}}""".replace("\n", "") & "\n"
doAssert renderOutput(parts).reply == "First\n\n> Bash: echo a echo b echo c\n> Read\n\nLast"
doAssert renderOutput(parts).activity == "Read"
let failed = renderOutput(parts & "{\"type\":\"result\",\"is_error\":true,\"result\":\"\\n denied\\nmore\"}\n")
doAssert failed.reply == renderOutput(parts).reply & "\n\n(failed: denied)"
doAssert failed.isError and failed.resultSeen
let onlyResult = renderOutput("{\"type\":\"result\",\"result\":\"Answer\"}\n")
doAssert onlyResult.reply == "Answer" and onlyResult.resultSeen
doAssert onlyResult.activity == "" and not onlyResult.isError
doAssert renderOutput(beforeText & "{\"type\":\"result\",\"result\":\"Answer\"}\n").reply == tools & "\n\nAnswer"
let longTool = %*{"type": "assistant", "message": {"content": [
  {"type": "tool_use", "name": "Search", "input": {"query": repeat("日", 101)}}]}}
doAssert renderOutput($longTool & "\n").reply == "> Search: " & repeat("日", 100) & "…"
doAssert renderOutput("\nplain\r\ntext\nunfinished").reply == "\nplain\r\ntext\n"
doAssert renderOutput("plain\n日"[0..7]).reply == "plain\n"
doAssert renderOutput("42\n").reply == "42\n"
doAssert renderOutput("\n").reply == "\n"
doAssert renderOutput("") == ChatOutput()
doAssert renderOutput("{\"type\":").reply == ""
doAssert renderOutput("{\"type\":\"system\"}\nnot json\n[]\n{\"type\":\"unknown\"}\n") == ChatOutput()
var invalid = false
try: discard renderOutput("\xff\n")
except ValueError: invalid = true
doAssert invalid

echo "chat ok"
