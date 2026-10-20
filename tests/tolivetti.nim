import std/unicode
import ../src/[olivetti, panes]

block margins:
  doAssert olivettiMargin(80, 5, 100) == 0
  doAssert olivettiMargin(0, 5, 100) == 0
  doAssert olivettiMargin(104, 5, 100) == 0
  doAssert olivettiMargin(105, 5, 100) == 0
  doAssert olivettiMargin(106, 5, 100) == 0
  doAssert olivettiMargin(107, 5, 100) == 1
  doAssert olivettiMargin(145, 5, 100) == 20
  doAssert olivettiMargin(146, 5, 100) == 20
  doAssert olivettiMargin(140, 0, 100) == 20
  doAssert olivettiMargin(140, 6, 80) == 27

block clicks:
  let lines = @["abc日本語xyz".toRunes]
  let gutter = gutterWidth(lines.len) + olivettiMargin(145, gutterWidth(lines.len), 100)
  doAssert pointAt(lines, @[], 0, 0, gutter, 0, 0) == (0, 0)
  doAssert pointAt(lines, @[], 0, 0, gutter, gutter - 1, 0) == (0, 0)
  doAssert pointAt(lines, @[], 0, 0, gutter, gutter, 0) == (0, 0)
  doAssert pointAt(lines, @[], 0, 0, gutter, gutter + 5, 0) == (0, 4)
  doAssert pointAt(lines, @[], 0, 3, gutter, gutter + 2, 0) == (0, 4)

echo "olivetti ok"
