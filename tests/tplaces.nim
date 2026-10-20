import std/[os, strutils]
import ../src/places

doAssert cookieDirectory("-*- mode: grep; default-directory: \"/Users/x/proj/\" -*-") == "/Users/x/proj/"
doAssert cookieDirectory("-*- mode: grep; default-directory: /p/q -*-") == "/p/q"
doAssert cookieDirectory("plain") == "" and isPlacesText("-*- mode: grep; default-directory: \"/\" -*-") and not isPlacesText("x")
let dir = getTempDir() / "darger-tplaces"
removeDir(dir); createDir(dir / "app")
writeFile(dir / "app" / "a.rb", "1\n2\n3\n4\n5\n")
writeFile(dir / "b.erb", "x\ny\n")
let text = "-*- mode: grep; default-directory: \"" & dir & "/\" -*-\nQuestion here (n / p で移動)\n\n== 1. Section\napp/a.rb:3: the loop (〜5)\nb.erb:2: view\nmissing.rb:1: gone\n== 2. Next\napp/a.rb:5:2: with col\n"
let trail = parsePlacesList(text, "/nowhere")
doAssert trail.len == 3, $trail
doAssert trail[0].row == 4 and trail[0].path == dir / "app" / "a.rb" and trail[0].line == 2 and trail[0].note == "the loop (〜5)"
doAssert trail[1].row == 5 and trail[2].row == 8 and trail[2].col == 1
doAssert placeRows(trail) == @[4, 5, 8]
doAssert nextPlace(trail, 0, 1) == 0 and nextPlace(trail, 4, 1) == 1 and nextPlace(trail, 8, 1) == -1
doAssert nextPlace(trail, 8, -1) == 1 and nextPlace(trail, 4, -1) == -1
doAssert placeAt(trail, 5) == 1 and placeAt(trail, 6) == -1
doAssert parsePlacesList("no cookie\nb.erb:1: ok\n", dir).len == 1   # the fallback directory
removeDir(dir)
echo "places ok"
