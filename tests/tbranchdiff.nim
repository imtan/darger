import std/[strutils, sequtils]
import ../src/branchdiff

let patch = """diff --git a/src/a.nim b/src/a.nim
index 123..456 100644
--- a/src/a.nim
+++ b/src/a.nim
@@ -2,4 +2,5 @@ proc a()
 context
-old
+new
+extra
 tail
 last
@@ -20,2 +21 @@
-old one
-old two
+replacement
\ No newline at end of file
"""
let files = parseDiff(patch)
doAssert files.len == 1 and files[0].path == "src/a.nim"
doAssert files[0].added == 3 and files[0].removed == 3
doAssert files[0].hunks.len == 2
let first = files[0].hunks[0]
doAssert first.newStart == 2 and first.newCount == 5
doAssert first.lines.mapIt(it.newLine) == @[2, 3, 3, 4, 5, 6]
doAssert files[0].hunks[1].lines.mapIt(it.newLine) == @[21, 21, 21, 21]
let view = diffView(files, "feature", "main")
doAssert view.rows[0].text == "feature ← main   1 files  +3 −3"
doAssert view.headers == @[1]
doAssert view.rows[1].path == "src/a.nim" and view.rows[1].newLine == 1
doAssert view.rows[2].kind == dkHunk and view.rows[2].newLine == 2
doAssert view.rows[4].kind == dkRemoved and view.rows[4].newLine == 3
for row in view.rows[1..^1]: doAssert row.path == "src/a.nim" and row.file == 0

block deletion:
  let f = parseDiff("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -2,3 +2,0 @@\n-x\n-y\n-z\n")
  doAssert f[0].hunks[0].lines.mapIt(it.newLine) == @[2, 2, 2]
  let atEnd = parseDiff("diff --git a/a b/a\n@@ -1,2 +1 @@\n kept\n-removed\n")
  doAssert atEnd[0].hunks[0].lines[1].newLine == 1
  let gone = parseDiff("diff --git a/a b/a\ndeleted file mode 100644\n--- a/a\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone\n")
  doAssert gone[0].deleted and gone[0].path == "a" and gone[0].removed == 1
  doAssert gone[0].hunks[0].lines[0].newLine == 1
  doAssert "(deleted)" in diffView(gone, "f", "b").text

block namesAndMetadata:
  let f = parseDiff("""diff --git a/old name b/new name
similarity index 100%
rename from old name
rename to new name
diff --git a/empty b/empty
new file mode 100644
index 000..e69
diff --git a/picture b/picture
index 123..456 100644
Binary files a/picture and b/picture differ
diff --git "a/\346\227\245\346\234\254\350\252\236\t\"x\"\n" "b/\346\227\245\346\234\254\350\252\236\t\"x\"\n"
old mode 100644
new mode 100755
diff --git a/has b/inside b/has b/inside
old mode 100644
new mode 100755
""")
  doAssert f.len == 5
  doAssert f[0].renamed and f[0].oldPath == "old name" and f[0].path == "new name"
  doAssert f[1].isNew and f[1].hunks.len == 0
  doAssert f[2].binary and f[2].added == 0
  doAssert f[3].path == "日本語\t\"x\"\n", f[3].path
  doAssert f[4].path == "has b/inside", f[4].path
  let v = diffView(f, "f", "b")
  doAssert v.headers == @[1, 2, 3, 4, 5]
  doAssert v.nextHeader(0, 1) == 1 and v.nextHeader(2, 1) == 3
  doAssert v.nextHeader(3, -1) == 2 and v.nextHeader(1, -1) == 1
  doAssert v.nextHeader(5, 1) == 5
  doAssert "(renamed from old name)" in v.text and "(new file)" in v.text and "(binary)" in v.text
  doAssert v.rows[4].text.count('\n') == 0

block whitespaceAndPrefixes:
  let f = parseDiff("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,2 +1,2 @@\n---looks like a header\n+++also content\n \n")
  doAssert f[0].removed == 1 and f[0].added == 1 and f[0].path == "a"
  doAssert f[0].hunks[0].lines[^1].text == " "
  let spaces = parseDiff("diff --git a/a b/a\n@@ -0,0 +1 @@\n+  trailing  \n")
  doAssert spaces[0].hunks[0].lines[0].text == "+  trailing  "

block folding:
  var large = parseDiff("diff --git a/big b/big\nnew file mode 100644\n@@ -0,0 +1,4000 @@\n" & repeat("+added\n", 4000))
  doAssert large[0].folded and large[0].added == 4000
  let closed = diffView(large, "feature", "main")
  doAssert closed.rows.len == 2 and closed.rows[1].text.startsWith("▸ ")
  large[0].folded = false
  let opened = diffView(large, "feature", "main")
  doAssert opened.rows.len == 4003 and opened.rows[^1].newLine == 4000
  doAssert parseDiff(patch, foldBytes = 1)[0].folded
  var multiple = files & files
  multiple[0].folded = true
  let v = diffView(multiple, "f", "b")
  doAssert v.headers == @[1, 2] and v.rows[3].file == 1
  doAssert v.nextHeader(4, -1) == 2

let empty = diffView(parseDiff(""), "main", "main")
doAssert empty.rows.len == 2 and empty.rows[1].text == "nothing changed against main"
doAssert empty.rows[1].file == -1 and empty.nextHeader(0, 1) == 0
echo "branch diff parsing, source positions, metadata and folding ok"
