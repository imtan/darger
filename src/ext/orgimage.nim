## Inline images in Org buffers, as org-display-inline-images: a line with
## `[[file:...png]]` shows the picture in the rows under it, scaled to at most
## org-image-max-rows rows and the text width. Files are read once per modification
## time. M-x org-toggle-inline-images hides and shows them.
import std/[os, math, tables]
import ../[core, buffer, lisp, orgmode, syntax, render]

var shown = true

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
    let img = renderer.loadPicture(resolve(buf, link))
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
