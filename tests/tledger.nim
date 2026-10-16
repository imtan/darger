import std/[strutils, times, os]
import ../src/ledger

let at = dateTime(2026, mOct, 16, 17, 30, 0)
let debt = LedgerEntry(file: "/p/src/a.nim", line: 12, project: "my proj", source: "Agent",
  removed: "old line\n", added: "new line\nmore\n", at: at)
let text = orgEntry(debt)
doAssert text.startsWith("* TODO a.nim:12  taken without explanation  :debt:my_proj:\n:PROPERTIES:\n:FILE:     /p/src/a.nim\n"), text
doAssert ":BRANCH:" notin text and ":REV:" notin text
var onBranch = debt
onBranch.branch = "feature/x"
onBranch.rev = "abc1234"
let btext = orgEntry(onBranch)
doAssert btext.startsWith("* TODO a.nim:12  taken without explanation  :debt:my_proj:feature_x:\n"), btext
doAssert ":BRANCH:   feature/x\n:REV:      abc1234\n" in btext
doAssert "#+begin_src diff\n-old line\n+new line\n+more\n#+end_src\n" in text
var done = debt
done.explanation = "Renames the field.\n- okuri :: the kana sent after a kanji stem\n"
let dtext = orgEntry(done)
doAssert dtext.startsWith("* DONE a.nim:12  understood  :understood:my_proj:") and dtext.endsWith("kanji stem\n"), dtext
doAssert debtCount(text & dtext) == (1, 1)
let found = debtEntries(text & dtext & "* TODO no file here\n")
doAssert found.len == 1 and found[0].file == "/p/src/a.nim" and found[0].line == 12, $found
doAssert found[0].label.startsWith("a.nim:12")
var bdone = onBranch
bdone.explanation = "(understood)"
let ledgerText = text & btext & orgEntry(bdone)
doAssert debtEntries(ledgerText, "feature/x").len == 1 and debtEntries(ledgerText, "main").len == 0 and debtEntries(ledgerText).len == 2
doAssert understoodRevs(ledgerText, "feature/x").len == 0   # a TODO at the same revision is still open
doAssert understoodRevs(orgEntry(bdone), "feature/x") == @[("/p/src/a.nim", "abc1234")] and understoodRevs(ledgerText, "main").len == 0
var cmp = onBranch
cmp.source = "branch base"
doAssert orgEntry(cmp).startsWith("* TODO a.nim:12  not yet understood  :debt:")

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
