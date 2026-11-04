## Pinned font downloads and platform font lookup.
import std/[os, strutils, uri]

type
  FontFile* = object
    member*, sha256*, name*: string
  CatalogFont* = object
    name*, title*, homepage*, license*, url*, sha256*, size*, fallback*: string
    files*: seq[FontFile]

const catalog* = [
  CatalogFont(name: "rinmincho",
    title: "RinMincho",
    homepage: "https://rinmincho.pages.dev/",
    license: "SIL OFL 1.1",
    url: "https://rinmincho.pages.dev/RinMincho_v1.0.0.zip",
    sha256: "029306c2591fb0d65296df287da8cbbcab72a472a59ba7683db3b9e8d3336872",
    size: "6.3MB",
    fallback: "",
    files: @[
      FontFile(member: "RinMincho_v1.0.0/RinMincho-Regular.ttf",
        sha256: "ccd33fd39367fe59b65d2973a2c4aa64e5beeaa50813a53924d1cb9f7891b0ff", name: "RinMincho-Regular.ttf"),
      FontFile(member: "RinMincho_v1.0.0/RinMincho-Bold.ttf",
        sha256: "8296b57e1f2a95e0f3149fbb8d7a12761aa5a525cb35a4825ae650b3ae219d40", name: "RinMincho-Bold.ttf"),
      FontFile(member: "RinMincho_v1.0.0/OFL.txt",
        sha256: "edf803d9986a507793815af2bb8914cc532da4b0de4e6eb09492fd5e7c984517", name: "RinMincho-OFL.txt")]),
  CatalogFont(name: "nerd-symbols",
    title: "Nerd Fonts Symbols",
    homepage: "https://www.nerdfonts.com/",
    license: "MIT",
    url: "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/NerdFontsSymbolsOnly.zip",
    sha256: "fdca3682534f6f65e1ccb2345b0362ccf67d9b8eca7c8025330946e93e2473bc",
    size: "3.1MB",
    fallback: "SymbolsNerdFontMono-Regular.ttf",
    files: @[
      FontFile(member: "SymbolsNerdFontMono-Regular.ttf",
        sha256: "fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749", name: "SymbolsNerdFontMono-Regular.ttf"),
      FontFile(member: "LICENSE",
        sha256: "84a7a98c82140fb12c37fe42b93805baa16024cb3e5acc599b7ffe612c55d847", name: "SymbolsNerdFont-LICENSE.txt")])]

proc safeFileName*(name: string): bool =
  name.len > 0 and name[0] != '.' and not name.contains({'/', '\\', '\0', ':'})

proc lookup*(name: string): CatalogFont =
  for font in catalog:
    if font.name == name: return font

proc catalogForFile*(name: string): CatalogFont =
  if not safeFileName(name): return
  for font in catalog:
    for file in font.files:
      if file.name == name: return font

proc fontFiles*(font: CatalogFont): seq[string] =
  for file in font.files:
    if file.name.endsWith(".ttf") or file.name.endsWith(".otf"): result.add file.name

proc checkEntry*(font: CatalogFont): string =
  proc hashOk(hash: string): bool =
    hash.len == 64 and hash.allCharsInSet({'0'..'9', 'a'..'f'})
  if not font.url.startsWith("https://"): return "Expected HTTPS URL"
  if not hashOk(font.sha256): return "Invalid archive hash"
  if font.files.len == 0: return "No font files"
  var names: seq[string]
  for file in font.files:
    if not safeFileName(file.name): return "Unsafe file name"
    if file.name in names: return "Duplicate file name"
    names.add file.name
    if not hashOk(file.sha256): return "Invalid member hash"

proc installDir*(setting, home: string): string =
  if setting.len == 0: home / ".darger-fonts"
  elif setting[0] == '~': home / setting[1..^1].strip(leading = true, trailing = false, chars = {'/', '\\'})
  elif setting.isAbsolute: setting
  else: home / setting

proc candidateRow*(font: CatalogFont, installed: bool): string =
  font.name & "  " & (if installed: "installed" else: "missing") & "  " & font.size & "  " & font.license

proc catalogName*(row: string): string =
  let words = row.splitWhitespace
  if words.len > 0: words[0] else: ""

proc fontHost*(font: CatalogFont): string = parseUri(font.url).hostname

proc consentQuestion*(font: CatalogFont): string =
  font.title & " が見つかりません。" & font.fontHost & " から取得しますか (" &
    font.size & ", " & font.license & ") (y/n) "

proc fontDirs*(home, localAppData: string): seq[string] =
  ## Where fonts are installed; those missing on this system are simply empty.
  @[home / "Library/Fonts", "/Library/Fonts", home / ".local/share/fonts", home / ".fonts",
    "/usr/share/fonts", "/usr/local/share/fonts", localAppData / "Microsoft/Windows/Fonts",
    "C:/Windows/Fonts"]

proc findFont*(name: string, dirs: seq[string]): string =
  ## A path as given, a bare file name in the first dir that has it (subdirectories
  ## included, as /usr/share/fonts nests them); "" when there is none.
  if name.len == 0: return ""
  if name.splitPath.head.len > 0:
    return if fileExists(name): name else: ""
  for dir in dirs:
    if fileExists(dir / name): return dir / name
  for dir in dirs:
    if dirExists(dir):
      for path in walkDirRec(dir):
        if path.extractFilename == name: return path

