## Inline images in Org buffers, as org-display-inline-images: a line with
## `[[file:...png]]` shows the picture in the rows under it, scaled to at most
## org-image-max-rows rows and the text width. Files are read once per modification
## time. M-x org-toggle-inline-images hides and shows them.
import std/[os, tables, times, math]
import pixie
import ../[core, buffer, buffers, lisp, orgmode, syntax, render]

type Loaded = object
  stamp: times.Time
  key: string
  w, h: int   ## the source image's size, after downscaling very large files
  ok: bool

var
  loaded: Table[string, Loaded]   # by resolved path
  shown = true

proc fetch(path: string): Loaded =
  ## The image at path, loaded (and kept by the renderer) when the file changed.
  var stamp: times.Time
  try: stamp = getLastModificationTime(path)
  except CatchableError: return Loaded()
  if path in loaded and loaded[path].stamp == stamp: return loaded[path]
  result = Loaded(stamp: stamp, key: "picture:" & path)
  try:
    var img = readImage(path)
    while img.width > 2048 or img.height > 2048: img = img.minifyBy2()
    renderer.addPicture(result.key, img)
    result.w = img.width
    result.h = img.height
    result.ok = img.width > 0 and img.height > 0
  except CatchableError: result.ok = false
  loaded[path] = result

proc resolve(buf: Buffer, link: string): string =
  let p = expandTilde(link)
  if p.isAbsolute: p
  elif buf.path.len > 0: parentDir(buf.path) / p
  else: getCurrentDir() / p

proc orgPictures(buf: Buffer): tuple[extra: seq[int], pictures: seq[Picture]] =
  if not shown or langOf(buf).name != "Org" or renderer.cellH == 0: return
  let maxRows = max(1, interp.env.values["org-image-max-rows"].asNumber.int)
  let maxW = max(4, renderer.cols - gutterFor(buf) - 2) * renderer.cellW
  let maxH = maxRows * renderer.cellH
  for n, line in buf.lines:
    let link = imageLink(line)
    if link.len == 0: continue
    let img = fetch(resolve(buf, link))
    if not img.ok: continue
    let scale = min(1.0, min(maxW / img.w, maxH / img.h))
    let (w, h) = (max(1, int(img.w.float * scale)), max(1, int(img.h.float * scale)))
    if result.extra.len < buf.lines.len: result.extra.setLen(buf.lines.len)
    result.extra[n] = int(ceil(h / renderer.cellH))
    result.pictures.add Picture(line: n, key: img.key, w: w, h: h)

pictureHook = orgPictures

interp.defPrimitive("org-toggle-inline-images", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  shown = not shown
  echoLine = if shown: "Inline images shown" else: "Inline images hidden"
  nilValue())

defaults.add """
(setq org-image-max-rows 15)
"""
