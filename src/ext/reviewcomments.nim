## Shared line comments for diff views, reviews and editable plans.
import std/[os, strutils, tables, sequtils, tempfiles]
import ../[core, buffer, buffers, render, lisp, review, reviewcomments, chat]
import agent, orgimage
export reviewcomments

type CommentView* = object
  root*: string
  anchors*: seq[CommentAnchor]

var
  commentViews: Table[Buffer, CommentView]
  commentProviders*: seq[proc(buf: Buffer): CommentView]
  commentSendChecks*: seq[proc(root: string)]
  comments*: seq[ReviewComment]
  loadedPath: string

proc commentsPath(): string = getHomeDir() / ".darger-review-comments.json"

proc loadComments*() =
  let path = commentsPath()
  if loadedPath == path: return
  let loaded = if fileExists(path): decodeComments(readFile(path)) else: @[]
  comments = loaded
  loadedPath = path

proc saveComments*(next: seq[ReviewComment]) =
  let path = commentsPath()
  let (file, temporary) = createTempFile(".darger-comments-", ".json", parentDir(path))
  try:
    file.write(encodeComments(next))
  finally: file.close()
  moveFile(temporary, path)
  comments = next
  loadedPath = path

proc setCommentView*(buf: Buffer, root: string, anchors: seq[CommentAnchor]) =
  commentViews[buf] = CommentView(root: root, anchors: anchors)

proc commentView*(buf: Buffer): CommentView =
  if buf in commentViews: return commentViews[buf]
  for provider in commentProviders:
    let view = provider(buf)
    if view.root.len > 0: return view

proc commentRoot*(): string =
  let view = commentView(b)
  if view.root.len > 0: view.root else: currentChatRoot()

proc anchorAt(buf: Buffer): CommentAnchor =
  let view = commentView(buf)
  if buf.cursor.line in 0..<view.anchors.len: result = view.anchors[buf.cursor.line]
  if result.path.len == 0 or result.line < 1:
    raise newException(ValueError, "Select a diff or plan text line")

proc bindCommentKeys*(buf: Buffer, key = "c", send = true, delete = true) =
  setLocalKey(buf, key, symbol("review-comment"))
  if send: setLocalKey(buf, "S", symbol("review-comments-send"))
  if delete: setLocalKey(buf, "C-c C-k", symbol("review-comment-delete"))

var pendingComment: ReviewComment
var pendingBuffer: Buffer

definePrompt(Prompt(kind: "review-comment", text: true, onAccept: proc(value: string): bool =
  if strutils.strip(value).len == 0: return false
  if pendingBuffer notin reg:
    echoLine = "Comment buffer was killed"
    return true
  let view = commentView(pendingBuffer)
  if view.root != pendingComment.root or not view.anchors.anyIt(it.sameLine(pendingComment.anchor)):
    echoLine = "Comment line changed; select it again"
    return true
  loadComments()
  var next = comments
  pendingComment.text = value
  next.putComment(pendingComment)
  saveComments(next)
  echoLine = "Comment saved"
  true))

interp.defPrimitive("review-comment", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  loadComments()
  pendingComment = ReviewComment(root: commentRoot(), anchor: anchorAt(b))
  pendingBuffer = b
  let i = comments.findComment(pendingComment.root, pendingComment.anchor)
  beginMini("review-comment", "Comment: ", if i >= 0: comments[i].text else: "")
  nilValue())

interp.defPrimitive("review-comment-delete", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  loadComments()
  let i = comments.findComment(commentRoot(), anchorAt(b))
  if i >= 0:
    var next = comments
    next.delete(i)
    saveComments(next)
    echoLine = "Comment deleted"
  else: echoLine = "No comment on this line"
  nilValue())

var listed: seq[ReviewComment]
var labels: seq[string]
proc jumpComment(c: ReviewComment) =
  # Prefer the originating view, including removed lines and unsaved proposals.
  let origin = b
  let point = b.cursor
  let top = renderer.top
  let left = renderer.left
  for buf in @[origin] & reg.slots.mapIt(it.buf):
    let view = commentView(buf)
    if view.root != c.root: continue
    for line, anchor in view.anchors:
      if anchor.sameLine(c.anchor):
        switchTo(buf)
        pushXref(origin, point, top, left)
        b.cursor = (line, 0)
        return
  let path = c.root / c.anchor.path
  if not fileExists(path):
    echoLine = "Comment source is unavailable: " & c.anchor.path
    return
  visit(path)
  pushXref(origin, point, top, left)
  b.cursor = (clamp(c.anchor.line - 1, 0, b.lines.high), 0)
  echoLine = c.text

definePrompt(Prompt(kind: "review-comments", text: true, candidates: proc(): seq[string] = labels,
  onAccept: proc(value: string): bool =
    let i = labels.find(value)
    if i >= 0: jumpComment(listed[i])
    true))
interp.defPrimitive("review-comments", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  loadComments()
  let root = commentRoot()
  listed = comments.filterIt(it.root == root)
  labels = @[]
  for i, c in listed:
    labels.add $(i + 1) & "  " & c.anchor.path & ":" & $c.anchor.line & "  " & c.text
  if listed.len == 0: echoLine = "No review comments in this project"
  else: beginMini("review-comments", "Review comment: ")
  nilValue())

interp.defPrimitive("review-comments-send", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  loadComments()
  let root = commentRoot()
  for check in commentSendChecks: check(root)
  let sent = comments.filterIt(it.root == root)
  let prompt = commentPrompt(sent, root)
  if prompt.len == 0: echoLine = "No review comments in this project"
  else:
    chatRoot = root
    sendChat(prompt, onResult = proc(session: ChatSession, text: string, ok: bool) =
      if ok: saveComments(comments.withoutSent(sent)))
  nilValue())

commentProviders.add proc(buf: Buffer): CommentView =
  if reviewTarget == nil or reviewTarget.path.len == 0: return
  var text: string
  var numbers: seq[int]
  var colors: seq[int8]
  if buf == reviewBuf:
    let view = reviewState.view(currentHunk)
    text = view.text
    numbers = view.newLines
    colors = view.colors
  elif buf in sideBufs:
    let view = sideViews[sideBufs.find(buf)]
    text = view.text
    numbers = view.newLines
    colors = view.colors
  else: return
  result.root = rootFromDir(parentDir(reviewTarget.path))
  let path = relativePath(reviewTarget.path, result.root).replace('\\', '/')
  let rows = text.splitLines()
  for i, line in rows:
    if i >= numbers.len or numbers[i] < 1:
      result.anchors.add CommentAnchor()
      continue
    let changed = i < colors.len and colors[i] in 1'i8..4'i8
    let content = if buf == reviewBuf and changed: line[1..^1] else: line
    let prefix = if changed and colors[i] in [1'i8, 3'i8]: "-" elif changed: "+" else: " "
    result.anchors.add CommentAnchor(path: path, line: numbers[i], content: content,
      excerpt: prefix & content)

# Reuse image row reservation, scrolling and mouse mapping; render text instead of pixels.
let previousPictures = pictureHook
pictureHook = proc(buf: Buffer): tuple[extra: seq[int], pictures: seq[Picture]] =
  if previousPictures != nil: result = previousPictures(buf)
  let view = commentView(buf)
  if view.root.len == 0: return
  try: loadComments()
  except CatchableError: return  # commands report malformed stores without overwriting them
  for line, anchor in view.anchors:
    let i = comments.findComment(view.root, anchor)
    if i < 0: continue
    if result.extra.len < buf.lines.len: result.extra.setLen(buf.lines.len)
    result.pictures.add Picture(line: line, annotation: comments[i].text,
      rowOffset: result.extra[line])
    inc result.extra[line]

killHooks.add proc(buf: Buffer) = commentViews.del(buf)
