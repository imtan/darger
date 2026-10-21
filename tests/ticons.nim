import std/unicode
import ../src/[icons, syntax]

doAssert iconFor("src", true, false).glyph == ""
doAssert iconFor("src", true, true).glyph == ""
doAssert iconFor("a/b/c", true, false).face == fKeyword
doAssert iconFor("core.nim", false, false).face == fAnsi3
doAssert iconFor("Core.NIM", false, false).glyph == iconFor("darger.nimble", false, false).glyph
doAssert iconFor("Dockerfile", false, false).glyph == ""
doAssert iconFor("Gemfile", false, false).glyph == iconFor("app.rb", false, false).glyph
doAssert iconFor("Gemfile.lock", false, false).glyph == ""
doAssert iconFor("show.html.erb", false, false).glyph == ""
doAssert iconFor("README.ja.md", false, false).glyph == "\uF02D"
doAssert iconFor(".gitignore", false, false).glyph == ""
doAssert iconFor(".darger.el", false, false).glyph == iconFor("init.el", false, false).glyph
doAssert iconFor(".env.local", false, false).glyph == ""
doAssert iconFor("notes.org", false, false).face == fAnsi2
doAssert iconFor("mystery.xyz", false, false).glyph == ""
doAssert iconFor("noext", false, false).glyph == ""
doAssert iconFor(".hidden", false, false).glyph == ""
for icon in [iconFor("a.rb", false, false), iconFor("b", true, false), iconFor("c", false, false)]:
  doAssert icon.glyph.runeLen == 1
echo "icons ok"
