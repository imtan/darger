## Filesystem tree model, independent of the editor and renderer.
import std/[os, strutils, algorithm, tables]

type
  Node* = ref object
    path*, name*: string
    depth*: int
    isDir*, expanded*, loaded*: bool
    children*: seq[Node]
  Tree* = ref object
    root*: Node
    collapseDirs*: int
  Row* = object
    path*, name*: string
    depth*: int
    isDir*, expanded*: bool
    firstPath*: string       # start of a compressed directory chain

proc newTree*(root: string, collapseDirs = 3): Tree =
  let path = normalizedPath(absolutePath(root))
  Tree(root: Node(path: path, name: path, isDir: true, expanded: true), collapseDirs: collapseDirs)

proc load(n: Node) =
  if n.loaded or not n.isDir: return
  var children: seq[Node]
  try:
    for kind, path in walkDir(n.path):
      children.add Node(path: path, name: extractFilename(path), depth: n.depth + 1,
        isDir: kind in {pcDir, pcLinkToDir})
  except OSError: discard  # an unreadable directory lists as empty
  children.sort(proc(a, b: Node): int =
    if a.isDir != b.isDir: return (if a.isDir: -1 else: 1)
    result = cmp(a.name.toLowerAscii, b.name.toLowerAscii)
    if result == 0: result = cmp(a.name, b.name))
  n.children = children
  n.loaded = true

proc inside(path, root: string): bool =
  path == root or path.startsWith(root & (if root.endsWith(DirSep): "" else: $DirSep))

proc find(tree: Tree, path: string): Node =
  let target = normalizedPath(absolutePath(path))
  if not inside(target, tree.root.path): return
  var n = tree.root
  while n.path != target:
    n.load()
    var next: Node
    for child in n.children:
      if inside(target, child.path):
        next = child
        break
    if next == nil: return
    n = next
  n

proc expand*(tree: Tree, path: string) =
  let n = tree.find(path)
  if n != nil and n.isDir:
    n.load()
    n.expanded = true

proc collapse*(tree: Tree, path: string) =
  let n = tree.find(path)
  if n != nil: n.expanded = false

proc toggle*(tree: Tree, path: string) =
  let n = tree.find(path)
  if n != nil and n.isDir:
    if n.expanded: tree.collapse(path)
    else: tree.expand(path)

proc rows*(tree: Tree, showHidden = false): seq[Row] =
  var output: seq[Row]
  proc add(node: Node, depth: int) =
    var n = node
    var name = n.name
    var count = 1
    if n != tree.root and n.isDir:
      while count < tree.collapseDirs and not symlinkExists(n.path):
        n.load()
        if n.children.len != 1 or not n.children[0].isDir: break
        let child = n.children[0]
        if symlinkExists(child.path): break
        if not showHidden and child.name.startsWith("."): break
        name.add "/" & child.name
        n = child
        inc count
    output.add Row(path: n.path, firstPath: node.path, name: name, depth: depth,
      isDir: n.isDir, expanded: n.expanded)
    if n.isDir and n.expanded:
      n.load()
      for child in n.children:
        if showHidden or not child.name.startsWith("."): add(child, depth + 1)
  add(tree.root, 0)
  output

proc render*(row: Row): string =
  repeat(' ', row.depth * 2) & (if row.isDir: (if row.expanded: "▾ " else: "▸ ") else: "  ") &
    row.name & (if row.isDir: "/" else: "")

proc reveal*(tree: Tree, filePath: string, showHidden = false): int =
  let target = normalizedPath(absolutePath(filePath))
  if not inside(target, tree.root.path): return -1
  var dir = parentDir(target)
  while inside(dir, tree.root.path):
    tree.expand(dir)
    if dir == tree.root.path: break
    dir = parentDir(dir)
  for i, row in tree.rows(showHidden):
    if row.path == target or (row.isDir and inside(target, row.firstPath) and inside(row.path, target)):
      return i
  -1

proc refresh*(tree: Tree) =
  ## Reload cached listings, preserving expansions even inside compressed chains.
  proc reload(n: Node) =
    if not n.loaded: return
    var old: Table[string, Node]
    for child in n.children: old[child.path] = child
    n.loaded = false
    n.load()
    for child in n.children.mitems:
      if child.path in old and child.isDir == old[child.path].isDir:
        child = old[child.path]
        reload(child)
  reload(tree.root)
