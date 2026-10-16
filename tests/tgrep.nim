import std/[os, strutils]
import ../src/grep

let rg = parseHit("/a/b.org:12:5:some text: with colons", true)
doAssert rg.path == "/a/b.org" and rg.line == 11 and rg.col == 4 and rg.text == "some text: with colons"
let plain = parseHit("/a/b.org:3:hello", false)
doAssert plain.path == "/a/b.org" and plain.line == 2 and plain.col == 0 and plain.text == "hello"
doAssert parseHit("garbage", true).path.len == 0 and parseHit("/x:notanumber:1:t", true).path.len == 0
doAssert parseHits("/a:1:1:x\n\n/b:2:3:y\n", true).len == 2
doAssert hitRow(rg, "/a") == "b.org:12: some text: with colons"
doAssert hitRow(rg, "") == "/a/b.org:12: some text: with colons"
doAssert hitRow(Hit(path: "/a/c", line: 0, text: "  " & "x".repeat(300)), "/a").len < 220

let dir = getTempDir() / "darger-tgrep"
createDir(dir)
writeFile(dir / "one.org", "* Heading\nneedle here\nnothing\n")
writeFile(dir / "two.txt", "Needle again\n")
let (hits, err) = runGrep(dir, "needle")
doAssert err == "", err
doAssert hits.len == 2, $hits
doAssert hits[0].text.contains("eedle") and hits[1].text.contains("eedle")
let none = runGrep(dir, "zzzz-not-there")
doAssert none.hits.len == 0 and none.error == ""
removeDir(dir)
echo "grep ok"
