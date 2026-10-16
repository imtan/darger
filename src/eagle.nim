## Eagle (eagle.cool) items for inserting image links: parsing the local API's JSON,
## filtering images, labelling items with their tags, and the library paths.
import std/[json, strutils, os, uri]

type
  EagleItem* = object
    id*, name*, ext*: string
    tags*: seq[string]
  EagleFolder* = object
    id*, label*: string  ## label: "parent/child"

const imageExts* = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "avif"]

proc apiData*(body: string): JsonNode =
  ## The `data` of an API reply; raises on a non-success status.
  let obj = parseJson(body)
  if obj{"status"}.getStr != "success":
    raise newException(ValueError, "Eagle API error: " & obj{"status"}.getStr("no status"))
  obj["data"]

proc libraryPath*(body: string): string =
  ## From /api/library/info: the library directory.
  let d = apiData(body)
  if d.hasKey("library") and d["library"].hasKey("path"): d["library"]["path"].getStr
  else: d{"path"}.getStr

proc items*(body: string): seq[EagleItem] =
  ## From /api/item/list: the image items, in the API's order.
  for it in apiData(body):
    let ext = it{"ext"}.getStr.toLowerAscii
    if ext notin imageExts: continue
    var tags: seq[string]
    if it.hasKey("tags"):
      for t in it["tags"]: tags.add t.getStr
    result.add EagleItem(id: it{"id"}.getStr, name: it{"name"}.getStr, ext: ext, tags: tags)

proc flattenFolders(nodes: JsonNode, prefix: string, into: var seq[EagleFolder]) =
  for f in nodes:
    let label = if prefix.len > 0: prefix & "/" & f{"name"}.getStr else: f{"name"}.getStr
    into.add EagleFolder(id: f{"id"}.getStr, label: label)
    if f.hasKey("children") and f["children"].kind == JArray: flattenFolders(f["children"], label, into)

proc folders*(body: string): seq[EagleFolder] =
  ## From /api/folder/list: every folder as "parent/child", depth first.
  flattenFolders(apiData(body), "", result)

proc itemLabel*(it: EagleItem): string =
  ## `name.ext  [tag, tag, ...]` with up to five tags, as the user's Emacs list shows.
  result = it.name & "." & it.ext
  if it.tags.len > 0: result.add "  [" & it.tags[0..<min(5, it.tags.len)].join(", ") & "]"

proc originalPath*(it: EagleItem, library: string): string =
  ## The item's file in the library: images/ID.info/NAME.EXT.
  library / "images" / (it.id & ".info") / (it.name & "." & it.ext)

proc thumbnailPath*(it: EagleItem, library: string): string =
  ## Eagle's small preview of the item: images/ID.info/NAME_thumbnail.png (not every
  ## item has one; fall back to originalPath).
  library / "images" / (it.id & ".info") / (it.name & "_thumbnail.png")

proc abbreviateHome*(path, home: string): string =
  ## /Users/x/Dropbox/a -> ~/Dropbox/a, so the link works wherever the library sits under HOME.
  let h = home.strip(leading = false, trailing = true, chars = {'/'})  # getHomeDir() ends in "/"
  if h.len > 0 and path.startsWith(h & "/"): "~" & path[h.len..^1] else: path

proc abbreviateHome*(path: string): string = abbreviateHome(path, getHomeDir())

proc listQuery*(keyword = "", folder = ""): string =
  ## The /api/item/list path for the newest 200 items, by keyword or folder.
  result = "/api/item/list?limit=200&orderBy=-MTIME"
  if keyword.len > 0: result.add "&keyword=" & encodeUrl(keyword)
  if folder.len > 0: result.add "&folders=" & folder
