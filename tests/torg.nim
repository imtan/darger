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

# folding
block:
  let doc = lines("""#+title: T
#+startup: folded
intro
* A
a body
** A1
a1 body
*** A1x
deep
** A2
* B
b body""")
  doAssert startupState(doc) == "OVERVIEW"
  doAssert startupState(lines("#+STARTUP: content indent")) == "CONTENTS"
  doAssert startupState(lines("* no keyword")) == "SHOW ALL"
  doAssert children(doc, 3) == @[5, 9] and children(doc, 5) == @[7] and children(doc, 10).len == 0
  doAssert bodyEnd(doc, 3) == 4 and bodyEnd(doc, 9) == 9

  # overview: only the top-level headlines and the text before them show
  let overview = globalFolds(doc, "OVERVIEW")
  var map = foldMap(doc, overview)
  doAssert map == @[0'i8, 0, 0, 2, 1, 1, 1, 1, 1, 1, 2, 1]
  # contents: every headline shows, every body hides
  map = foldMap(doc, globalFolds(doc, "CONTENTS"))
  doAssert map == @[0'i8, 0, 0, 2, 1, 2, 1, 2, 1, 0, 2, 1]
  doAssert foldMap(doc, globalFolds(doc, "SHOW ALL")) == newSeq[int8](doc.len)

  # TAB on A from overview: FOLDED -> CHILDREN (body and folded children) -> SUBTREE -> FOLDED
  doAssert foldState(doc, overview, 3) == "FOLDED"
  var (folds, state) = cycleFold(doc, overview, 3)
  doAssert state == "CHILDREN"
  doAssert foldMap(doc, folds) == @[0'i8, 0, 0, 0, 0, 2, 1, 1, 1, 0, 2, 1]
  (folds, state) = cycleFold(doc, folds, 3)
  doAssert state == "SUBTREE" and foldMap(doc, folds) == @[0'i8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1]
  (folds, state) = cycleFold(doc, folds, 3)
  doAssert state == "FOLDED" and foldMap(doc, folds) == @[0'i8, 0, 0, 2, 1, 1, 1, 1, 1, 1, 2, 1]
  # a headline without children: FOLDED <-> SUBTREE; one without a body: nothing to fold
  (folds, state) = cycleFold(doc, @[fold(doc, 10)], 10)
  doAssert state == "SUBTREE" and folds.len == 0
  doAssert cycleFold(doc, @[], 9).state == ""
  # a body-only fold (contents) opens with TAB
  doAssert cycleFold(doc, globalFolds(doc, "CONTENTS"), 10).state == "SUBTREE"

  # revealing a line deep in a folded subtree opens the path to it, siblings stay folded
  let shown = revealFolds(doc, overview, 8)
  map = foldMap(doc, shown)
  doAssert map == @[0'i8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1]
  doAssert revealFolds(doc, overview, 2) == overview  # already shown: unchanged

  # edits: inserting a line above moves the folds; editing a headline keeps its fold
  var edited = doc
  edited.insert(rs"new intro", 2)
  let moved = remapFolds(overview, edited, 1)
  doAssert moved.len == 2 and moved[0].line == 4 and moved[1].line == 11
  edited = doc
  edited[3] = rs"* A renamed"
  let renamed = remapFolds(overview, edited, 0)
  doAssert renamed.len == 2 and renamed[0].line == 3 and $renamed[0].text == "* A renamed"
  edited = doc
  edited.delete(3)  # the folded headline is gone: its fold is dropped, B's moves up
  let dropped = remapFolds(overview, edited, -1)
  doAssert dropped.len == 1 and dropped[0].line == 9

# journal: strftime, English and Japanese
let tue = dateTime(2026, mOct, 13, 9, 4, 0)
doAssert strftime("%Y%m%d.org", tue) == "20261013.org"
doAssert strftime("%A, %d %B %Y", tue) == "Tuesday, 13 October 2026"
doAssert strftime("%A, %d %B %Y", tue, japanese = true) == "火曜日, 13 10月 2026"
doAssert strftime("%a %b %e %j %y", tue, japanese = true) == "火 10月 13 286 26"
doAssert strftime("=%R=\n", tue) == "=09:04=\n"
doAssert strftime("%H:%M:%S 100%% %q", tue) == "09:04:00 100% %q"
doAssert strftime("#+title: %Y-%m-%d Journal\n#+startup: folded\n\n", tue) == "#+title: 2026-10-13 Journal\n#+startup: folded\n\n"
doAssert appendedText("", "* x\n") == "* x\n" and appendedText("a", "b") == "a\nb" and appendedText("a\n", "b") == "a\nb"

# capture: under a headline's subtree, at the end, or under a headline created at the end
block:
  let tasks = "#+title: t\n* Inbox\n** TODO old\n* Tasks\n** TODO a\n   note\n* Later\ntext\n"
  var (text, at) = insertUnder(tasks, "Tasks", "** TODO new\n")
  doAssert text == "#+title: t\n* Inbox\n** TODO old\n* Tasks\n** TODO a\n   note\n** TODO new\n* Later\ntext\n"
  doAssert text[at..^1].startsWith("** TODO new")
  (text, at) = insertUnder(tasks, "", "* TODO end\n")
  doAssert text == tasks & "* TODO end\n" and at == tasks.len
  (text, at) = insertUnder("* A\nbody", "Missing", "** TODO x\n")
  doAssert text == "* A\nbody\n* Missing\n** TODO x\n"
  (text, at) = insertUnder("* Tasks\n** TODO a", "Tasks", "** TODO b\n")  # no final newline
  doAssert text == "* Tasks\n** TODO a\n** TODO b\n"
  doAssert insertUnder("", "Tasks", "** TODO x\n").text == "* Tasks\n** TODO x\n"
  doAssert fillTemplate("** TODO %? %t\n", "buy milk", tue) == "** TODO buy milk <2026-10-13 Tue>\n"
  doAssert fillTemplate("%u %U 50%%", "x", tue) == "[2026-10-13 Tue] [2026-10-13 Tue 09:04] 50%"
