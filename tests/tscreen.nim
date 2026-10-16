import std/[strutils, sequtils]
import ../src/termscreen

block basics:
  var s = initScreen(10, 3)
  s.feed("hello")
  doAssert s.lines == @["hello", "", ""] and (s.row, s.col) == (0, 5)
  s.feed("\r\nworld\n")
  doAssert s.lines == @["hello", "world", ""] and (s.row, s.col) == (2, 5)
  s.feed("x\n")                                     # past the bottom: the top line scrolls into the scrollback
  doAssert s.lines == @["world", "     x", ""] and s.scrollbackLines == @["hello"]
  doAssert s.text == "hello\nworld\n     x\n"

block wrapping:
  var s = initScreen(5, 2)
  s.feed("abcdefg")                                 # wraps at the right margin
  doAssert s.lines == @["abcde", "fg"] and (s.row, s.col) == (1, 2)
  var d = initScreen(5, 2)
  d.feed("abcde\r\nX")                              # a newline right after the last column does not wrap twice
  doAssert d.lines == @["abcde", "X"]

block cursor:
  var s = initScreen(10, 4)
  s.feed("\x1b[2;3Hab")                             # CUP is 1-based
  doAssert s.lines[1] == "  ab" and (s.row, s.col) == (1, 4)
  s.feed("\x1b[A\x1b[3DZ")                         # up one, left three
  doAssert s.lines[0] == " Z"
  s.feed("\x1b[4;1H\x1b[5Gx\x1b[2dq")               # column 5 of row 4, then row 2 (same column)
  doAssert s.lines[3] == "    x" and s.lines[1] == "  ab q"
  s.feed("\x1b[s\x1b[1;1HS\x1b[uR")                 # save / restore
  doAssert s.lines[0] == "SZ" and s.lines[1] == "  ab qR"
  s.feed("\x1b7\x1b[H\x1b8!")                       # DECSC / DECRC
  doAssert s.lines[1] == "  ab qR!"

block erasing:
  var s = initScreen(6, 3)
  s.feed("aaaaaa\r\nbbbbbb\r\ncccccc")
  s.feed("\x1b[2;3H\x1b[K")                         # EL 0: to the end of line
  doAssert s.lines[1] == "bb"
  s.feed("\x1b[3;3H\x1b[1K")                        # EL 1: to the cursor, inclusive
  doAssert s.lines[2] == "   ccc"
  s.feed("\x1b[1;3H\x1b[J")                         # ED 0: to the end of screen
  doAssert s.lines == @["aa", "", ""]
  s.feed("\x1b[2J")
  doAssert s.lines == @["", "", ""]
  var e = initScreen(6, 2)
  e.feed("abcdef\x1b[1;2H\x1b[2X")                   # ECH: two cells blanked
  doAssert e.lines[0] == "a  def"
  e.feed("\x1b[1;2H\x1b[2P")                        # DCH pulls left
  doAssert e.lines[0] == "adef"
  e.feed("\x1b[1;2H\x1b[1@")                        # ICH pushes right
  doAssert e.lines[0] == "a def"

block regions:
  var s = initScreen(4, 4)
  s.feed("1\r\n2\r\n3\r\n4")
  s.feed("\x1b[2;3r")                               # region rows 2-3, cursor home
  s.feed("\x1b[3;1H\n")                             # a line feed at the region bottom scrolls only the region
  doAssert s.lines == @["1", "3", "", "4"] and s.scrollbackLines.len == 0
  s.feed("\x1b[2;1H\x1bM")                          # reverse index at the region top scrolls it down
  doAssert s.lines == @["1", "", "3", "4"]
  s.feed("\x1b[2;1H\x1b[L")                         # insert line inside the region
  doAssert s.lines == @["1", "", "", "4"]
  s.feed("\x1b[r")                                  # the region resets to the whole screen
  s.feed("\x1b[4;1H\n")
  doAssert s.scrollbackLines == @["1"]

block alternate:
  var s = initScreen(8, 2)
  s.feed("main\r\nline")
  s.feed("\x1b[?1049h")                             # a full-screen program takes the alternate screen
  doAssert s.lines == @["", ""] and (s.row, s.col) == (0, 0)
  s.feed("tui\x1b[2;1Hbottom\n")                    # scrolling here never reaches the scrollback
  doAssert s.lines == @["bottom", ""] and s.scrollbackLines.len == 0
  s.feed("\x1b[?1049l")                             # back: the main screen as it was
  doAssert s.lines == @["main", "line"] and (s.row, s.col) == (1, 4)

block colours:
  var s = initScreen(8, 1)
  s.feed("\x1b[31mre\x1b[0md\x1b[92mg")
  doAssert s.colors[0] == @[2'i8, 2, 0, 3]
  doAssert s.cellAt(0, 0).color == 2

block resizing:
  var s = initScreen(6, 3)
  s.feed("one\r\ntwo\r\nthree")
  s.resize(4, 2)                                    # the top line goes to the scrollback, lines are cut
  doAssert s.lines == @["two", "thre"] and s.scrollbackLines == @["one"] and s.row == 1
  s.resize(8, 4)
  doAssert s.lines == @["two", "thre", "", ""]
  s.feed("\x1b[4;1Hlast")
  doAssert s.lines[3] == "last"

block splitSequences:
  var s = initScreen(8, 2)
  s.feed("a\x1b[")
  s.feed("3")
  s.feed("1mb")
  doAssert s.lines[0] == "ab" and s.colors[0] == @[0'i8, 2]
  s.feed("\x1b]0;title")
  s.feed("\x07c")
  doAssert s.lines[0] == "abc"

echo "screen ok"
