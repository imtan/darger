import std/[os, times, strutils]
import pixie
import ../src/pictures

let dir = getTempDir() / "darger-tpictures"
removeDir(dir)
createDir(dir)
let stamp = fromUnix(1_700_000_000)
let c = convertedPath("/a/b.webp", stamp, dir)
doAssert c.startsWith(dir) and c.endsWith("-1700000000.png") and c != convertedPath("/a/c.webp", stamp, dir)
doAssert convertToPng(dir / "missing.webp", dir) == ""   # no such file
when defined(macosx):
  let img = newImage(8, 6)
  img.fill(rgba(0, 128, 255, 255))
  img.writeFile(dir / "src.png")
  let out1 = convertToPng(dir / "src.png", dir)
  doAssert out1.len > 0 and fileExists(out1), out1
  doAssert readImage(out1).width == 8
  doAssert convertToPng(dir / "src.png", dir) == out1   # cached
removeDir(dir)
echo "pictures ok"
