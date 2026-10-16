## Images from Eagle (eagle.cool), as the user's Emacs does: pick an item from the
## local API by keyword (C-M-e) or folder (C-c e) and insert an Org link to the
## library file itself, written ~/... so the link works on every machine that has the
## library under HOME. Eagle must be running. The highlighted item's thumbnail is
## previewed beside the list, as the user's consult preview did.
import std/[os, strutils, osproc, tables]
import ../[core, buffer, lisp, eagle]

var
  eagleItems: seq[EagleItem]
  eagleRows: seq[string]
  eagleFolders: seq[EagleFolder]
  folderRows: seq[string]
  eagleLibrary: string

proc eagleGet(path: string): string =
  ## GET from the local API (curl, 8 s); raises with a readable message when Eagle is away.
  let base = interp.env.values["eagle-api-base"].asString
  let (output, code) = execCmdEx("curl -s --max-time 8 " & quoteShell(base & path), options = {poUsePath})
  if code != 0 or output.len == 0:
    raise newException(IOError, "Cannot reach Eagle at " & base & " (is Eagle running?)")
  output

proc pickFrom(query: string) =
  ## Lists the images the query returns; Enter inserts the chosen one's link.
  eagleLibrary = libraryPath(eagleGet("/api/library/info"))
  eagleItems = items(eagleGet(query))
  if eagleItems.len == 0:
    echoLine = "No image items in Eagle for that"
    return
  eagleRows = @[]
  for it in eagleItems: eagleRows.add itemLabel(it)
  beginMini("eagle-item", "Eagle image: ")

proc insertEagle(value: string): bool =
  let i = eagleRows.find(value)
  if i < 0: return false
  let src = originalPath(eagleItems[i], eagleLibrary)
  if not fileExists(src):
    echoLine = "Eagle file not found: " & src
    return true
  let link = abbreviateHome(src)
  b.insert("[[file:" & link & "]]")
  echoLine = "Inserted from Eagle: " & link
  true

definePrompt(Prompt(kind: "eagle-keyword", text: true, onAccept: proc(value: string): bool =
  try: pickFrom(listQuery(keyword = value))
  except CatchableError as e: echoLine = e.msg
  true))
proc previewOf(value: string): string =
  ## The highlighted item's thumbnail (its file when Eagle made none), shown beside the list.
  let i = eagleRows.find(value)
  if i < 0: return ""
  let thumb = thumbnailPath(eagleItems[i], eagleLibrary)
  if fileExists(thumb): thumb else: originalPath(eagleItems[i], eagleLibrary)

definePrompt(Prompt(kind: "eagle-item", text: true, candidates: proc(): seq[string] = eagleRows,
  onAccept: insertEagle, thumbnail: previewOf))
definePrompt(Prompt(kind: "eagle-folder", text: true, candidates: proc(): seq[string] = folderRows,
  onAccept: proc(value: string): bool =
    let i = folderRows.find(value)
    if i < 0: return false
    try: pickFrom(listQuery(folder = eagleFolders[i].id))
    except CatchableError as e: echoLine = e.msg
    true))

interp.defPrimitive("org-insert-eagle-image", proc(args: seq[Value]): Value =
  ## C-M-e: a keyword (empty = the newest), then the matching images to choose from.
  args.arity(0, 0)
  beginMini("eagle-keyword", "Eagle keyword (empty = newest): ")
  nilValue())
interp.defPrimitive("org-insert-eagle-image-from-folder", proc(args: seq[Value]): Value =
  ## C-c e: an Eagle folder, then its images to choose from.
  args.arity(0, 0)
  try:
    eagleFolders = folders(eagleGet("/api/folder/list"))
    if eagleFolders.len == 0:
      echoLine = "Eagle has no folders"
      return nilValue()
    folderRows = @[]
    for f in eagleFolders: folderRows.add f.label
    beginMini("eagle-folder", "Eagle folder: ")
  except CatchableError as e: echoLine = e.msg
  nilValue())

defaults.add """
(setq eagle-api-base "http://localhost:41595")
(global-set-key "C-M-e" 'org-insert-eagle-image)
(global-set-key "C-c e" 'org-insert-eagle-image-from-folder)
"""
