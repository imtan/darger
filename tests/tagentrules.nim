import std/[os, tempfiles, strutils, sequtils]
import ../src/[agentrules, review]

let fixture = createTempDir("darger-rules-", "")
let home = fixture / "home"
let root = home / "parent/project"
for dir in [home / ".claude", home / ".codex", root / ".claude", root / ".cursor/rules", root / ".github"]:
  createDir(dir)
let paths = @[home / ".claude/CLAUDE.md", home / ".codex/AGENTS.md",
  home / "parent/AGENTS.md", root / "CLAUDE.md", root / ".claude/CLAUDE.md",
  root / "AGENTS.md", root / ".cursor/rules/a.mdc", root / ".cursor/rules/z.mdc",
  root / ".github/copilot-instructions.md", root / "CLAUDE.local.md"]
for path in paths: writeFile(path, "one\ntwo\n")
writeFile(root / ".cursor/rules/ignored.md", "ignored")
let rows = collectRules(root, home)
doAssert rows.mapIt(it.path).filterIt(it.startsWith(fixture)) == paths
doAssert rows.filterIt(it.scope == "user").len == 2
doAssert rows[^1].scope == "local"
for row in rows:
  if row.path.startsWith(fixture): doAssert row.lines == 2
doAssert defaultMemoryPath(root) == root / "CLAUDE.md"
let other = fixture / "other"
createDir(other)
doAssert defaultMemoryPath(other) == other / "CLAUDE.md"
writeFile(other / "AGENTS.md", "")
doAssert defaultMemoryPath(other) == other / "AGENTS.md"
for (text, count) in [("", 0), ("one", 1), ("one\n", 1), ("\n\n", 2), ("one\r\ntwo", 2), (repeat("x", 5000) & "\n", 1)]:
  writeFile(other / "count", text)
  doAssert agentrules.countLines(other / "count") == count
doAssert agentrules.countLines(other / "missing") == -1
for old in ["", "existing", "existing\n"]:
  let addition = memoryAppend(old, "  日本語 memory  ")
  doAssert (old & addition).endsWith("- 日本語 memory\n")
  let r = newReview("", addition)
  doAssert r.hunks.len == 1 and r.stats(0).removed == 0
for text in ["", " \t ", "one\ntwo", "one\rtwo"]:
  var rejected = false
  try: discard memoryAppend("", text)
  except ValueError: rejected = true
  doAssert rejected
doAssert '\n' notin ruleLabel(RuleFile(path: "a\nb\tc", scope: "project", lines: -1))
echo "rule order, scopes, counts, default destinations and one-hunk append ok"
