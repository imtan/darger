import std/strutils
import ../src/agentnotify

doAssert appleScriptString("a\"\\\n\r\t日本語\x00") == "\"a\\\"\\\\\\n\\r\\t日本語\""
doAssert notificationScript("Darger", "done", "") == "display notification \"done\" with title \"Darger\""
doAssert notificationScript("Darger", "\" & do shell script \"bad", "Glass\"\\") ==
  "display notification \"\\\" & do shell script \\\"bad\" with title \"Darger\" sound name \"Glass\\\"\\\\\""

let cases = @[
  ("plain 日本語", 0), ("\a", 1), ("\a\a", 2),
  ("\e]9;ready\a", 1), ("\e]9;ready\e\\", 1),
  ("\e]777;notify;Claude;Permission needed\a", 1),
  ("\e]777;notify;Claude;Permission needed\e\\", 1),
  ("\e]0;title\a", 0), ("\e]2;title\e\\", 0),
  ("\e]99;other\a", 0), ("\e]777;other;test\a", 0),
  ("\e]777;notify;title;" & repeat("x", 10000) & "\a", 1),
  ("\e]9;cancel\x18\a", 1),
  ("\ePignored\a\e\\\a", 1),
  ("\e]0;title\a\e]9;ready\a\a\e]777;notify;title;text\e\\", 3)]
for (input, expected) in cases:
  var parser: NoticeParser
  doAssert parser.feed(input) == expected, repr(input)
  # Every possible read boundary, then byte-at-a-time input.
  for split in 0..input.len:
    parser = NoticeParser()
    doAssert parser.feed(input[0..<split]) + parser.feed(input[split..^1]) == expected
  parser = NoticeParser()
  var total = 0
  for c in input: total += parser.feed($c)
  doAssert total == expected
for enabled in [false, true]:
  for focused in [false, true]:
    for shown in [false, true]:
      doAssert shouldNotify(enabled, focused, shown, false) == enabled
      doAssert shouldNotify(enabled, focused, shown, true) == (enabled and not (focused and shown))
echo "notification escaping, streaming BEL/OSC detection and visibility policy ok"
