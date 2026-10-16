import std/[strutils, times, os]
import ../src/ledger

let at = dateTime(2026, mOct, 16, 17, 30, 0)
let debt = LedgerEntry(file: "/p/src/a.nim", line: 12, project: "my proj", source: "Agent",
  removed: "old line\n", added: "new line\nmore\n", at: at)
let text = orgEntry(debt)
doAssert text.startsWith("* TODO a.nim:12  taken without explanation  :debt:my_proj:\n:PROPERTIES:\n:FILE:     /p/src/a.nim\n"), text
doAssert "#+begin_src diff\n-old line\n+new line\n+more\n#+end_src\n" in text
var done = debt
done.explanation = "Renames the field.\n- okuri :: the kana sent after a kanji stem\n"
let dtext = orgEntry(done)
doAssert dtext.startsWith("* DONE a.nim:12  understood  :understood:my_proj:") and dtext.endsWith("kanji stem\n"), dtext
doAssert debtCount(text & dtext) == (1, 1)
let entries = debtEntries(text & dtext & "* TODO no file here\n")
doAssert entries.len == 1 and entries[0].file == "/p/src/a.nim" and entries[0].line == 12, $entries
doAssert entries[0].label.startsWith("a.nim:12")

let dir = getTempDir() / "darger-tledger"
removeDir(dir); createDir(dir)
let path = dir / "ledger.org"
appendEntries(path, @[debt])
appendEntries(path, @[done])
let all = readFile(path)
doAssert all.startsWith("#+title: Understanding ledger\n") and debtCount(all) == (1, 1)
appendEntries(path, @[])
doAssert readFile(path) == all
removeDir(dir)

doAssert glossaryTerms("text\n- okuri :: kana after the stem\n  - nested :: ignored?\n- bad line\n- x ::\n") ==
  @[("okuri", "kana after the stem"), ("nested", "ignored?")]
let g = mergeGlossary("", @[("Okuri", "a"), ("Hunk", "b")])
doAssert g == "#+title: Glossary\n\n- Okuri :: a\n- Hunk :: b\n", g
doAssert mergeGlossary(g, @[("okuri", "other"), ("New", "c")]) == g & "- New :: c\n"
echo "ledger ok"
