import std/[unicode, strutils, times, os]
import ../src/[orgmode, roam]

proc rs(s: string): seq[Rune] = s.toRunes
proc lines(s: string): seq[seq[Rune]] =
  for l in s.split('\n'): result.add l.toRunes

# headlines
let h = headline(rs"** TODO Write tests  :work:now:")
doAssert h.level == 2 and h.todo == "TODO" and h.title == "Write tests" and h.tags == ":work:now:"
doAssert headline(rs"*not a headline").level == 0
doAssert headline(rs"* ").level == 1 and headline(rs"* ").title == ""  # an empty headline, as in Org
doAssert headline(rs"* DONE").todo == "DONE" and headline(rs"* DONE").title == ""
doAssert headline(rs"* 日本語の見出し").title == "日本語の見出し"
doAssert headline(rs"* :tagsonly:").tags == ":tagsonly:" and headline(rs"* :tagsonly:").title == ""

# TODO cycling keeps the rest of the line
doAssert $cycleTodo(rs"* Task") == "* TODO Task"
doAssert $cycleTodo(rs"* TODO Task") == "* DONE Task"
doAssert $cycleTodo(rs"* DONE Task  :t:") == "* Task  :t:"
doAssert $cycleTodo(rs"* TODO") == "* DONE"
doAssert $cycleTodo(rs"* DONE") == "* "
doAssert $cycleTodo(rs"plain") == "plain"

# levels
doAssert $shiftLevel(rs"** A", 1) == "*** A"
doAssert $shiftLevel(rs"** A", -1) == "* A"
doAssert $shiftLevel(rs"* A", -1) == "* A"
doAssert $shiftLevel(rs"text", 1) == "text"

# subtrees
let doc = lines("#+title: T\n* A\nbody\n** A1\n*** A1a\n** A2\n* B\n")
doAssert subtreeEnd(doc, 1) == 5
doAssert subtreeEnd(doc, 3) == 4
doAssert subtreeEnd(doc, 6) == 7
doAssert subtreeEnd(doc, 2) == 2
doAssert headlineAbove(doc, 2) == 1
doAssert headlineAbove(doc, 0) == -1
doAssert outline(doc).len == 5 and outline(doc)[1] == (3, "** A1")

# checkboxes and list items
doAssert $toggleCheckbox(rs"- [ ] milk") == "- [X] milk"
doAssert $toggleCheckbox(rs"  3. [X] eggs") == "  3. [ ] eggs"
doAssert $toggleCheckbox(rs"- [-] partial") == "- [ ] partial"
doAssert $toggleCheckbox(rs"- no box") == "- no box"
doAssert $toggleCheckbox(rs"[ ] bare") == "[ ] bare"
doAssert newItemPrefix(rs"** Head") == "** "
doAssert newItemPrefix(rs"- item") == "- "
doAssert newItemPrefix(rs"  + item") == "  + "
doAssert newItemPrefix(rs"2. second") == "3. "
doAssert newItemPrefix(rs"9) ninth") == "10) "
doAssert newItemPrefix(rs"- [X] done") == "- [ ] "
doAssert newItemPrefix(rs"plain text") == ""
doAssert newItemPrefix(rs"-dash") == ""

# links
let l = rs"see [[id:abc][Note A]] and [[https://x.y]] here"
doAssert linkAt(l, 0) == ("", "")
doAssert linkAt(l, 4) == ("id:abc", "Note A")
doAssert linkAt(l, 21) == ("id:abc", "Note A")
doAssert linkAt(l, 22) == ("", "")
doAssert linkAt(l, 30) == ("https://x.y", "")
doAssert linkAt(rs"[[unclosed", 3) == ("", "")

# timestamps
let day = dateTime(2026, mOct, 7, 0, 0, 0)
doAssert timestamp(day) == "<2026-10-07 Wed>"
doAssert timestamp(day, active = false) == "[2026-10-07 Wed]"

# file keywords and properties
let note = lines(":PROPERTIES:\n:ID:       1234\n:END:\n#+TITLE: My Note\n\n* H\nlink [[id:5678][B]] and [[id:9]]\n")
doAssert keyword(note, "title") == "My Note"
doAssert keyword(note, "author") == ""
doAssert property(note, "id") == "1234"
doAssert property(lines("* H\n:PROPERTIES:\n:ID: x\n:END:"), "ID") == ""  # not file-level

# org-roam
let node = parseNode("/n/a.org", ":PROPERTIES:\n:ID:       1234\n:END:\n#+TITLE: My Note\n\n* H\nlink [[id:5678][B]] and [[id:9]]\n")
doAssert node.id == "1234" and node.title == "My Note"
doAssert node.refs.len == 2 and node.refs[0].id == "5678" and node.refs[1] == ("9", 6, "link [[id:5678][B]] and [[id:9]]")
doAssert parseNode("/n/untitled.org", ":PROPERTIES:\n:ID: z\n:END:\n").title == "untitled"
doAssert slug("Hello, World! 2026") == "hello_world_2026"
doAssert slug("日本語 ノート") == "日本語_ノート"
doAssert slug("  --  ") == ""
doAssert newId().len == 36 and newId() != newId()
doAssert newNoteText("i", "T") == ":PROPERTIES:\n:ID:       i\n:END:\n#+title: T\n\n"
doAssert newNotePath("/r", "A b", day).replace('\\', '/') == "/r/20261007000000-a_b.org"
doAssert dailyPath("/r", day).replace('\\', '/') == "/r/daily/2026-10-07.org"
doAssert linkText("i", "T") == "[[id:i][T]]"

# a directory of notes
let dir = getTempDir() / "darger-roam-test"
removeDir(dir)
createDir(dir / "sub")
createDir(dir / ".hidden")
writeFile(dir / "a.org", newNoteText("ida", "Alpha") & "to [[id:idb][Beta]]\n")
writeFile(dir / "sub" / "b.org", newNoteText("idb", "Beta") & "back [[id:ida]] twice [[id:ida][A]]\n")
writeFile(dir / "plain.org", "* no id\n")
writeFile(dir / ".hidden" / "h.org", newNoteText("idh", "Hidden"))
let nodes = scanNodes(dir)
doAssert nodes.len == 2 and nodes[0].title == "Alpha" and nodes[1].title == "Beta"
doAssert nodes.byId("idb") == 1 and nodes.byId("nope") == -1
doAssert nodes.byTitle("Beta") == 1
let back = backlinks(nodes, "ida")
doAssert back.len == 2 and back[0].title == "Beta" and back[0].line == 5 and back[0].text.startsWith("back")
doAssert backlinks(nodes, "idb").len == 1
doAssert scanNodes(dir / "missing").len == 0
removeDir(dir)
echo "org tests passed"
