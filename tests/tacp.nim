import std/[json, strutils, tables, unittest]
import ../src/acp

suite "ACP v1 messages and presentation":
  test "wire capabilities, partial NDJSON and notifications":
    let init = request(1, "initialize", initializeParams())
    check init["params"]["protocolVersion"].getInt == 1
    check init["params"]["clientCapabilities"]["fs"]["writeTextFile"].getBool
    check init["params"]["clientCapabilities"]["terminal"].getBool
    var input = ($init)[0..12]
    check takeMessages(input).len == 0
    input.add ($init)[13..^1] & "\n" & $notification("session/cancel", %*{"sessionId": "s"}) & "\n"
    let frames = takeMessages(input)
    check frames.len == 2 and input == ""
    check not frames[1].hasKey("id")
    check promptParams("s", "こんにちは")["prompt"][0]["text"].getStr == "こんにちは"
    check permissionResult("always")["outcome"]["optionId"].getStr == "always"
    check permissionResult()["outcome"]["outcome"].getStr == "cancelled"
  test "reject malformed and oversized frames":
    for text in ["{}\n", "junk\n", repeat('x', maxAcpMessage + 1)]:
      var input = text
      expect CatchableError: discard takeMessages(input)
  test "partial tool updates, thoughts, plan and coloured diffs":
    var s: AcpState
    s.update(%*{"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Hello"}})
    s.update(%*{"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": " world"}})
    s.update(%*{"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "secret thought"}})
    s.update(%*{"sessionUpdate": "tool_call", "toolCallId": "t", "kind": "edit", "title": "Change file",
      "content": [{"type": "diff", "path": "/tmp/file", "oldText": "before\n", "newText": "after\n"}]})
    s.update(%*{"sessionUpdate": "tool_call_update", "toolCallId": "t", "status": "completed", "title": nil})
    s.update(%*{"sessionUpdate": "plan", "entries": [{"content": "Tests", "status": "completed"}, {"content": "Code", "status": "in_progress"}]})
    check s.reply == "Hello world"
    check s.tools["t"]["title"].getStr == "Change file"
    let view = s.render()
    check "secret thought" notin view.text
    check "secret thought" in s.render(true).text
    check "- [x] Tests" in view.text and "- [>] Code" in view.text
    check "edit · completed · Change file" in view.text
    check "-before" in view.text and "+after" in view.text
    check 2'i8 in view.colors and 3'i8 in view.colors
  test "line ranges preserve newlines and output truncates on UTF-8 boundaries":
    check readSlice("a\nb\nc\n", 2, 1) == "b\n"
    check readSlice("a\nb", 3) == ""
    expect ValueError: discard readSlice("a", 0)
    var output = "あいう"
    check trimOutput(output, 5)
    check output == "う"

  test "terminal output never emits incomplete UTF-8 in JSON":
    check terminalText("hello あ") == "hello あ"
    check terminalText("hello \xe3\x81") == "hello "
    check terminalText("x\xffy") == "x�y"
