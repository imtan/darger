## C-M-y in Org: the clipboard's image saved as img/YYYY-mm-dd-HH-MM-SS.png next to
## the file and linked as [[file:img/...]], as the user's Emacs command does, without
## pngpaste (the window library reads the pasteboard; pixie writes the PNG).
import std/[os, times]
import windy, pixie
import ../[core, buffer, lisp, orgmode]

interp.defPrimitive("org-insert-clipboard-image", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if core.b.path.len == 0:
    echoLine = "Save the buffer first: the image goes to img/ next to its file"
    return nilValue()
  let image = getClipboardImage()
  if image == nil or image.width == 0:
    echoLine = "No image in the clipboard"
    return nilValue()
  let name = clipboardImageName(now())
  let path = parentDir(core.b.path) / name
  try:
    createDir(parentDir(path))
    image.writeFile(path)
  except CatchableError as e:
    echoLine = "Could not save the image: " & e.msg
    return nilValue()
  core.b.insert("[[file:" & name & "]]")
  echoLine = "Saved " & name & " (" & $image.width & "x" & $image.height & ")"
  nilValue())

defaults.add """
(global-set-key "C-M-y" 'org-insert-clipboard-image)
"""
