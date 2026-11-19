## Persistent review anchors and prompts, independent of the editor and filesystem.
import std/[json, strutils]

type
  CommentAnchor* = object
    path*: string
    line*: int                 ## new-side line, 1-based; deletions use the next line
    content*, excerpt*: string
  ReviewComment* = object
    root*: string
    anchor*: CommentAnchor
    text*: string

proc sameLine*(a, b: CommentAnchor): bool =
  a.path == b.path and a.line == b.line and a.content == b.content

proc findComment*(comments: seq[ReviewComment], root: string, anchor: CommentAnchor): int =
  for i, c in comments:
    if c.root == root and c.anchor.sameLine(anchor): return i
  -1

proc putComment*(comments: var seq[ReviewComment], comment: ReviewComment) =
  let i = comments.findComment(comment.root, comment.anchor)
  if i >= 0: comments[i] = comment
  else: comments.add comment

proc encodeComments*(comments: seq[ReviewComment]): string =
  let repos = newJObject()
  for c in comments:
    if c.root notin repos: repos[c.root] = newJArray()
    repos[c.root].add %*{"path": c.anchor.path, "line": c.anchor.line,
      "content": c.anchor.content, "excerpt": c.anchor.excerpt, "text": c.text}
  $(%*{"version": 1, "repositories": repos})

proc decodeComments*(text: string): seq[ReviewComment] =
  if text.strip.len == 0: return
  let doc = parseJson(text)
  if doc.kind != JObject or doc["version"].getInt != 1 or doc["repositories"].kind != JObject:
    raise newException(ValueError, "Unsupported review comments file")
  for root, rows in doc["repositories"]:
    if rows.kind != JArray: raise newException(ValueError, "Invalid review comments")
    for row in rows:
      let c = ReviewComment(root: root, anchor: CommentAnchor(path: row["path"].getStr,
        line: row["line"].getInt, content: row["content"].getStr, excerpt: row["excerpt"].getStr),
        text: row["text"].getStr)
      if c.anchor.path.len == 0 or c.anchor.line < 1 or c.text.len == 0:
        raise newException(ValueError, "Invalid review comment anchor")
      result.putComment(c)

proc commentPrompt*(comments: seq[ReviewComment], root: string, ending = true): string =
  for c in comments:
    if c.root != root: continue
    result.add c.anchor.path & ":" & $c.anchor.line & "\n" &
      c.anchor.excerpt & "\nコメント: " & c.text & "\n\n"
  if result.len > 0 and ending: result.add "これらのコメントに対応して"

proc withoutSent*(comments, sent: seq[ReviewComment]): seq[ReviewComment] =
  for c in comments:
    let i = sent.findComment(c.root, c.anchor)
    if i < 0 or sent[i].text != c.text: result.add c
