import ../src/render

# A 20 px title bar over a 400 px wide window: three 30 px buttons.
doAssert titleButtonWidth(20) == 30
doAssert titleHit(20, 400, 200, 25) == thNone  # below the bar
doAssert titleHit(20, 400, -1, 5) == thNone
doAssert titleHit(20, 400, 400, 5) == thNone
doAssert titleHit(20, 400, 200, 0) == thBar
doAssert titleHit(20, 400, 200, 19) == thBar
when defined(macosx):
  doAssert titleHit(20, 400, 0, 0) == thClose
  doAssert titleHit(20, 400, 29, 19) == thClose
  doAssert titleHit(20, 400, 30, 10) == thMinimize
  doAssert titleHit(20, 400, 89, 10) == thMaximize
  doAssert titleHit(20, 400, 90, 10) == thBar
  doAssert titleHit(20, 400, 399, 10) == thBar
else:
  doAssert titleHit(20, 400, 399, 0) == thClose
  doAssert titleHit(20, 400, 370, 19) == thClose
  doAssert titleHit(20, 400, 369, 10) == thMaximize
  doAssert titleHit(20, 400, 310, 10) == thMinimize
  doAssert titleHit(20, 400, 309, 10) == thBar
  doAssert titleHit(20, 400, 0, 10) == thBar
# A window too narrow for three buttons still answers without going out of range.
doAssert titleHit(20, 50, 49, 10) in {thBar, thMinimize, thMaximize, thClose}
echo "ok"
