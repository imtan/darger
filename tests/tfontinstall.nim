import std/[os, strutils, tables, tempfiles]
import zippy/ziparchives
import ../src/[sha256, fontcatalog, fontinstall]

doAssert sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
doAssert sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
doAssert sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
  "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
doAssert sha256Hex("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn" &
  "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu") ==
  "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
doAssert sha256Hex(repeat('a', 1_000_000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
# Boundary vectors obtained with shasum -a 256 over repeated 'a' bytes.
for (n, hash) in [
  (55, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
  (56, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
  (63, "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34"),
  (64, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
  (65, "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0")]:
  doAssert sha256Hex(repeat('a', n)) == hash

let root = createTempDir("darger-font-test-", "")
let tempRoot = root / "staging"
createDir(tempRoot)

proc empty(dir: string): bool =
  if dirExists(dir):
    for kind, path in walkDir(dir): return false
  true

block catalogChecks:
  let font = lookup("rinmincho")
  doAssert font.title == "RinMincho"
  doAssert lookup("unknown").name == ""
  doAssert catalogForFile("RinMincho-Regular.ttf") == font
  doAssert catalogForFile("SymbolsNerdFontMono-Regular.ttf").name == "nerd-symbols"
  for name in ["/RinMincho-Regular.ttf", "a/RinMincho-Regular.ttf", "a\\RinMincho-Regular.ttf"]:
    doAssert catalogForFile(name).name == ""
  doAssert font.fontFiles == @["RinMincho-Regular.ttf", "RinMincho-Bold.ttf"]
  for entry in catalog:
    doAssert checkEntry(entry) == ""
    for installed in [false, true]: doAssert catalogName(entry.candidateRow(installed)) == entry.name
  doAssert font.candidateRow(false) == "rinmincho  missing  6.3MB  SIL OFL 1.1"
  doAssert font.candidateRow(true) == "rinmincho  installed  6.3MB  SIL OFL 1.1"
  doAssert font.consentQuestion == "RinMincho が見つかりません。rinmincho.pages.dev から取得しますか (6.3MB, SIL OFL 1.1) (y/n) "
  for name in ["", ".", "..", ".hidden", "../x.ttf", "a/b.ttf", "a\\b.ttf", "x\0.ttf", "C:x.ttf"]:
    doAssert not safeFileName(name)
  doAssert safeFileName("Font-Regular.ttf")
  var bad = font
  bad.url = "http://example.com/font.zip"
  doAssert checkEntry(bad).len > 0
  bad = font
  bad.sha256 = "abc"
  doAssert checkEntry(bad).len > 0
  for name in ["../x.ttf", "a/b.ttf", ".."]:
    bad = font
    bad.files[0].name = name
    doAssert checkEntry(bad).len > 0
  bad = font
  bad.files[0].sha256 = repeat('A', 64)
  doAssert checkEntry(bad).len > 0
  doAssert checkEntry(font) == ""
  doAssert installDir("", root) == root / ".darger-fonts"
  doAssert installDir("~/.darger-fonts/", root) == root / ".darger-fonts/"
  doAssert installDir("~", root) == root
  doAssert installDir("fonts", root) == root / "fonts"
  doAssert installDir(root / "absolute", "elsewhere") == root / "absolute"

block fontLookup:
  let dir = root / "lookup"
  createDir(dir / "nested")
  writeFile(dir / "nested" / "Deep.ttf", "x")
  writeFile(dir / "Flat.ttf", "x")
  doAssert findFont("Flat.ttf", @[dir]) == dir / "Flat.ttf"
  doAssert findFont("Deep.ttf", @["/nonexistent", dir]) == dir / "nested" / "Deep.ttf"
  doAssert findFont("Missing.ttf", @[dir]) == ""
  doAssert findFont(dir / "Flat.ttf", @[]) == dir / "Flat.ttf"
  doAssert findFont(dir / "Missing.ttf", @[dir]) == ""
  doAssert findFont("", @[dir]) == ""
  removeDir(dir)
  doAssert fontDirs("/h", "/l")[0] == "/h" / "Library/Fonts"

let entries = {"pack/Regular.ttf": "regular", "pack/Bold.otf": "bold", "OFL": "license",
  "ignore.ttf": "ignored"}.toTable
let archive = createZipArchive(entries)
let font = CatalogFont(name: "test", url: "https://example.com/font.zip", sha256: sha256Hex(archive), files: @[
  FontFile(member: "pack/Regular.ttf", name: "Regular.ttf", sha256: sha256Hex("regular")),
  FontFile(member: "pack/Bold.otf", name: "Bold.otf", sha256: sha256Hex("bold")),
  FontFile(member: "OFL", name: "Test-OFL.txt", sha256: sha256Hex("license"))])

proc finish(i: FontInstall): FontInstall =
  var ticks = 0
  while not i.step():
    inc ticks
    doAssert ticks < 20
  doAssert i.done
  doAssert empty(tempRoot)
  if dirExists(i.dir):
    for kind, path in walkDir(i.dir): doAssert not path.extractFilename.startsWith(".darger-font-")
  i

proc failed(entry: CatalogFont, body, name: string, reason = "") =
  let dir = root / name
  let i = finish(startFromArchive(entry, dir, body, tempRoot))
  doAssert i.error.len > 0
  doAssert reason in i.error, i.error
  doAssert not dirExists(dir)
  doAssert empty(tempRoot)

try:
  block success:
    let dir = root / "installed"
    createDir(dir)
    writeFile(dir / "unrelated", "keep")
    for run in 0..1:
      if run == 1: writeFile(dir / "Regular.ttf", "old")
      let i = finish(startFromArchive(font, dir, archive, tempRoot))
      doAssert i.error == "", i.error
      for (name, content) in [("Regular.ttf", "regular"), ("Bold.otf", "bold"), ("Test-OFL.txt", "license")]:
        doAssert readFile(dir / name) == content
        when defined(posix):
          doAssert getFilePermissions(dir / name) == {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead}
      doAssert readFile(dir / "unrelated") == "keep"
      doAssert not fileExists(dir / "ignore.ttf")
  block archiveHash:
    var bad = font
    bad.sha256 = repeat('0', 64)
    failed(bad, archive, "bad-archive", "archive hash mismatch")
  block memberHash:
    var bad = font
    bad.files[1].sha256 = repeat('0', 64)
    failed(bad, archive, "bad-member", "Bold.otf: hash mismatch")
  block missing:
    var bad = font
    bad.files[1].member = "missing"
    failed(bad, archive, "missing")
  block invalidZip:
    var bad = font
    bad.sha256 = sha256Hex("not a zip")
    failed(bad, "not a zip", "invalid")
  block hostile:
    var extra = entries
    extra["xx/evil.ttf"] = "evil"
    let body = createZipArchive(extra).replace("xx/evil.ttf", "../evil.ttf")
    var entry = font
    entry.sha256 = sha256Hex(body)
    let dir = root / "hostile"
    let i = finish(startFromArchive(entry, dir, body, tempRoot))
    doAssert i.error == "", i.error
    doAssert readFile(dir / "Regular.ttf") == "regular"
    doAssert not fileExists(root / "evil.ttf")
    doAssert not fileExists(tempRoot / "evil.ttf")
    doAssert not fileExists(dir / "evil.ttf")
  block occupied:
    let dir = root / "occupied"
    writeFile(dir, "keep")
    let i = finish(startFromArchive(font, dir, archive, tempRoot))
    doAssert i.error.len > 0
    doAssert readFile(dir) == "keep"
  block rollback:
    for existing in [false, true]:
      let dir = root / ("rollback-" & $existing)
      createDir(dir / "Bold.otf")
      writeFile(dir / "unrelated", "keep")
      if existing: writeFile(dir / "Regular.ttf", "old")
      let i = finish(startFromArchive(font, dir, archive, tempRoot))
      doAssert i.error.len > 0
      doAssert readFile(dir / "unrelated") == "keep"
      doAssert dirExists(dir / "Bold.otf")
      if existing: doAssert readFile(dir / "Regular.ttf") == "old"
      else: doAssert not fileExists(dir / "Regular.ttf")
      doAssert not fileExists(dir / "Test-OFL.txt")
  block cancellation:
    for steps in 0..3:
      let dir = root / ("cancel-" & $steps)
      let i = startFromArchive(font, dir, archive, tempRoot)
      for n in 0..<steps: discard i.step()
      i.cancel()
      discard finish(i)
      doAssert i.error == "cancelled"
      doAssert not dirExists(dir)
  when defined(posix):
    block symlink:
      let dir = root / "symlink"
      createDir(dir)
      let target = root / "target"
      writeFile(target, "untouched")
      createSymlink(target, dir / "Regular.ttf")
      let i = finish(startFromArchive(font, dir, archive, tempRoot))
      doAssert i.error == "", i.error
      doAssert not symlinkExists(dir / "Regular.ttf")
      doAssert readFile(dir / "Regular.ttf") == "regular"
      doAssert readFile(target) == "untouched"
    block unwritable:
      let dir = root / "unwritable"
      createDir(dir)
      setFilePermissions(dir, {fpUserRead, fpUserExec})
      try:
        let i = finish(startFromArchive(font, dir, archive, tempRoot))
        doAssert i.error.len > 0
        doAssert empty(dir)
      finally: setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
finally:
  removeDir(root)
echo "fontinstall ok"
