import std/[os, tempfiles, sequtils]
import ../src/filetree

let dir = createTempDir("darger-tree-", "")
# The fixture is intentionally retained; it is isolated in the system temp directory.
createDir(dir / "a" / "b" / "c" / "d")
createDir(dir / "Zoo")
createDir(dir / ".hidden")
writeFile(dir / "Beta", "")
writeFile(dir / "alpha", "")
writeFile(dir / ".dot", "")
writeFile(dir / "a" / "b" / "c" / "d" / "leaf", "")
let lazy = newTree(dir, 0)
discard lazy.rows()
for child in lazy.root.children: doAssert not child.loaded
lazy.expand(dir / "Zoo")
doAssert lazy.rows().anyIt(it.name == "Zoo" and it.expanded)
lazy.toggle(dir / "Zoo")
doAssert lazy.rows().anyIt(it.name == "Zoo" and not it.expanded)
lazy.collapse(dir)
doAssert lazy.rows().len == 1
lazy.expand(dir)
doAssert lazy.rows().len == 5
let tree = newTree(dir)
doAssert not tree.root.loaded
var rs = tree.rows()
doAssert rs.mapIt(it.name) == @[dir, "a/b/c", "Zoo", "alpha", "Beta"]
doAssert rs[1].path == dir / "a" / "b" / "c"
doAssert rs[1].render == "  ▸ a/b/c/"
doAssert rs[3].render == "    alpha"
doAssert rs[3].render("X") == "    X alpha"
doAssert rs[1].render("D") == "  ▸ D a/b/c/"
doAssert not tree.root.children[1].expanded
doAssert tree.rows(true).mapIt(it.name) == @[dir, ".hidden", "a/b/c", "Zoo", ".dot", "alpha", "Beta"]
tree.toggle(rs[1].path)
rs = tree.rows()
doAssert rs[1].expanded and rs[2].name == "d"
doAssert rs[1].render == "  ▾ a/b/c/"
tree.collapse(rs[1].path)
doAssert tree.rows().len == 5
let leaf = dir / "a" / "b" / "c" / "d" / "leaf"
let index = tree.reveal(leaf)
rs = tree.rows()
doAssert index == 3 and rs[index].path == leaf and rs[index].depth == 3
doAssert tree.reveal(dir & "-outside/file") == -1
doAssert tree.reveal(dir / "missing") == -1
doAssert tree.reveal(dir / ".dot") == -1
doAssert tree.rows(true)[tree.reveal(dir / ".dot", true)].name == ".dot"
tree.collapseDirs = 0
rs = tree.rows()
doAssert rs[1].name == "a" and rs[2].name == "b" and rs[3].name == "c"
tree.collapseDirs = 2
doAssert tree.rows()[1].name == "a/b"
tree.collapseDirs = 3
writeFile(dir / "a" / "new", "")
doAssert tree.rows()[1].name == "a/b/c" # cached until refresh
tree.refresh()
rs = tree.rows()
doAssert rs[1].name == "a" and rs[1].expanded
doAssert rs.anyIt(it.name == "new")
doAssert rs.anyIt(it.path == leaf)
# Hidden files count as entries: hiding them must not invent a single-child chain.
createDir(dir / "blocked" / "child")
writeFile(dir / "blocked" / ".keep", "")
tree.refresh()
doAssert tree.rows().anyIt(it.name == "blocked")
# Directory symlinks may be opened explicitly, but never compressed in a loop.
createSymlink(dir / "Zoo", dir / "Zoo" / "loop")
tree.refresh()
doAssert tree.rows().anyIt(it.name == "Zoo")
echo "filetree ok"
