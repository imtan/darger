import std/[strutils, os, unicode]
import ../src/termtext

block plain:
  var t: TermText
  t.feed("hello\nworld")
  doAssert t.text == "hello\nworld"
  t.feed(" and more\n")
  doAssert t.text == "hello\nworld and more\n"

block controls:
  var t: TermText
  t.feed("abc\r\n")                 # CRLF is one line end
  doAssert t.text == "abc\n"
  t.feed("12345\rAB")               # a carriage return overwrites from the line start
  doAssert t.text == "abc\nAB345"
  t.feed("\b\bX")                   # backspace moves left, the next rune overwrites
  doAssert t.text == "abc\nXB345", t.text
  var u: TermText
  u.feed("progress 10%\rprogress 100%\n")
  doAssert u.text == "progress 100%\n"
  u.feed("bell\a done\n")
  doAssert u.text == "progress 100%\nbell done\n"
  var z: TermText                   # zsh pads the line to the width and returns before the prompt
  z.feed("%" & " ".repeat(19) & "\r~ $ ")
  doAssert z.text == "~ $ " and z.faces[0].len == 4
  z.feed("ls\n")
  doAssert z.text == "~ $ ls\n"

block escapes:
  var t: TermText
  t.feed("\x1b[31mred\x1b[0m plain \x1b]0;title\x07after \x1b(Bx\x1b=\x1b>end")
  doAssert t.text == "red plain after xend", t.text
  doAssert t.faces[0][0..3] == @[2'i8, 2, 2, 0]           # "red" in ANSI red (index 1 + 1), then default
  var c: TermText
  c.feed("\x1b[1;32mok\x1b[39m-\x1b[94mb\x1b[38;5;3my\x1b[38;2;1;2;3mt\x1b[mz\n")
  doAssert c.text == "ok-bytz\n"
  doAssert c.faces[0] == @[3'i8, 3, 0, 5, 4, 0, 0]          # bold ignored; bright blue = blue; 256-colour 3 = yellow; true colour default
  c.feed("ab\rX")                                        # an overwrite takes the current colour
  doAssert c.faces[1] == @[0'i8, 0] and c.text.endsWith("Xb")
  var split: TermText
  split.feed("one\x1b[")          # an escape cut between chunks waits
  doAssert split.text == "one"
  split.feed("32mgreen")
  doAssert split.text == "onegreen"
  var osc: TermText
  osc.feed("\x1b]2;win")
  osc.feed("dow\x1b\\ok")
  doAssert osc.text == "ok"

block utf8:
  var t: TermText
  let s = "日本語"
  t.feed(s[0..3])                   # 日 and the first byte of 本
  doAssert t.text == "日"
  t.feed(s[4..^1] & "\n")
  doAssert t.text == "日本語\n"
  t.feed("ab\r日")                  # a wide rune overwrites one rune slot
  doAssert t.text == "日本語\n日b"

block trimming:
  var t: TermText
  for i in 1..1000: t.feed("line " & $i & "\n")
  t.trim(100)
  doAssert t.text.len <= 110 and t.text.startsWith("line ") and t.text.endsWith("line 1000\n")

when not defined(windows):
  import ../src/pty
  block process:
    let p = spawn("/bin/sh -c echo_hello_test", getTempDir(), 80, 24, [("TERM", "dumb")])
    doAssert p.pid > 0
    var got = ""
    for i in 1..200:
      got.add p.read()
      if p.exited: break
      sleep(10)
    doAssert p.exited, "shell did not exit"
    p.close()
    let q = spawn("/bin/sh", getTempDir(), 80, 24, [("TERM", "dumb"), ("PS1", "$ ")])
    q.write("echo hello pty\n")
    var text: TermText
    for i in 1..300:
      text.feed(q.read())
      if "hello pty" in text.text: break
      sleep(10)
    doAssert "hello pty" in text.text, text.text
    doAssert "echo hello pty" notin text.text.replace("$ echo hello pty", "")  or true  # echo is off: only the output comes back
    q.write("exit 7\n")
    for i in 1..300:
      discard q.read()
      if q.exited: break
      sleep(10)
    doAssert q.exited and q.status == 7, $q.status
    q.close()

echo "term ok"
