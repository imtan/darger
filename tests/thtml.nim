import std/[strutils, unicode]
import ../src/html
import ../src/syntax

# entities
doAssert decodeEntities("a &amp; b &lt;c&gt; &quot;d&quot; &#65;&#x42; &nbsp;&hellip;") == "a & b <c> \"d\" AB  …"
doAssert decodeEntities("&unknown; & &amp &#;") == "&unknown; & &amp &#;"
doAssert decodeEntities("&#150;&#0;&#1114112;") == "–��"
doAssert sanitizeUtf8("ok\xff\xfe日本\xe3\x81") == "ok��日本��"
doAssert sanitizeUtf8("日本語") == "日本語"

# urls
doAssert resolveUrl("https://example.com/a/b.html", "c.html") == "https://example.com/a/c.html"
doAssert resolveUrl("https://example.com/a/b.html", "/x") == "https://example.com/x"
doAssert resolveUrl("https://example.com/a/", "//cdn.example.org/y") == "https://cdn.example.org/y"
doAssert resolveUrl("https://example.com/a", "http://other/z") == "http://other/z"
doAssert resolveUrl("", "rel.html") == "rel.html"
doAssert resolveUrl("https://example.com/a", "  ") == ""

# layout: paragraphs, wrapping, links and faces
let page = layout("""<html><head><title> My &amp; Page
</title><style>p{color:red}</style><script>var x = "<p>";</script></head>
<body><h1>Heading</h1><p>Hello <a href="/link">world</a>, this is a paragraph that wraps.</p>
<p>second</p><!-- comment --><ul><li>one</li><li>two <b>bold</b></li></ul><ol><li>first</li></ol>
<pre>  code   here
	tab</pre><p>日本語の文章はスペースがなくても折り返されます。</p><hr><p>Visit <a href="https://example.com/x?a=1&amp;b=2">x</a><img alt="pic" src="p.png"></p>
<table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table></body></html>""", "https://example.com/dir/page.html", 20)
doAssert page.title == "My & Page"
doAssert page.lines[0] == "Heading"
doAssert page.faces[0][0] == headingFace
doAssert page.lines[1] == ""
doAssert page.lines[2] == "Hello world, this is"
doAssert page.lines[3] == "a paragraph that"
doAssert page.lines[4] == "wraps."
for line in page.lines: doAssert line.toRunes.len <= 20 or line.startsWith("  code") or line.startsWith("\t"), line
doAssert page.links[0].url == "https://example.com/link"
doAssert page.links[0].line == 2 and page.links[0].startCol == 6 and page.links[0].endCol == 11
doAssert page.faces[2][6] == linkFace and page.faces[2][5] == fPlain and page.faces[2][11] == fPlain
doAssert page.lines[5] == ""
doAssert page.lines[6] == "second"
doAssert page.lines[7] == ""
doAssert page.lines[8] == "• one"
doAssert page.lines[9] == "• two bold"
doAssert page.lines[10] == ""
doAssert page.lines[11] == "1. first"
doAssert page.lines[12] == ""
doAssert page.lines[13] == "  code   here"
doAssert page.lines[14] == "\ttab"
doAssert page.lines[15] == ""
doAssert page.lines[16] == "日本語の文章はスペー"
doAssert page.lines[17] == "スがなくても折り返さ"
doAssert page.lines[18] == "れます。"
doAssert page.lines[19] == ""
doAssert page.lines[20] == "─".repeat(20)
doAssert page.lines[21] == ""
doAssert page.lines[22] == "Visit x[pic]"
doAssert page.links[1].url == "https://example.com/x?a=1&b=2"
doAssert page.links[1].line == 22 and page.links[1].startCol == 6 and page.links[1].endCol == 7
doAssert page.lines[23] == ""
doAssert page.lines[24] == "a  b"
doAssert page.lines[25] == "c"
doAssert page.lines.len == 26
doAssert page.links.len == 2

# a link wrapping across lines becomes two ranges; nested lists indent; br stacks
let wrapped = layout("<p>x <a href=a>one two three</a> y</p><ul><li>a<ul><li>b</li></ul></li></ul><div>l1<br><br>l3</div>", "", 10)
doAssert wrapped.lines[0] == "x one two"
doAssert wrapped.lines[1] == "three y"
doAssert wrapped.links.len == 2 and wrapped.links[0].line == 0 and wrapped.links[1].line == 1
doAssert wrapped.links[1].startCol == 0 and wrapped.links[1].endCol == 5
doAssert wrapped.lines[3] == "• a"
doAssert wrapped.lines[4] == "  • b"
doAssert wrapped.lines[6] == "l1" and wrapped.lines[7] == "" and wrapped.lines[8] == "l3"
doAssert layout("<ol><li>" & "x</li><li>".repeat(9) & "ten words that wrap around</li></ol>", "", 16).lines[9..10] == @["10. ten words", "    that wrap"]

# tolerant tokenizer: unquoted attributes, unclosed tags, stray <, uppercase, base href
let odd = layout("<P CLASS=x>a < b &amp; c<p>next<A HREF=\"../up\">up</a><base href='https://h.example/d/e/'><a href=rel>r</a>", "https://h.example/a/b/", 40)
doAssert odd.lines[0] == "a < b & c"
doAssert odd.lines[2] == "nextupr"
doAssert odd.links[0].url == "https://h.example/a/up"
doAssert odd.links[1].url == "https://h.example/d/e/rel"
doAssert layout("", "", 40).lines.len == 0
doAssert layout("<div></div><p></p>", "", 40).lines.len == 0
doAssert layout("<svg><text>hidden</text></svg>shown<noscript>no</noscript>", "", 40).lines == @["shown"]
doAssert layout("<a href=x><img src=y></a>", "", 40).lines == @["[image]"]
doAssert layout("<blockquote>quoted text</blockquote>", "", 40).lines == @["    quoted text"]
doAssert layout("<dl><dt>term</dt><dd>definition</dd></dl>", "", 40).lines == @["term", "    definition"]
doAssert layout("a b   c\n\n d", "", 40).lines == @["a b c d"]
doAssert layout("<textarea>&lt;x&gt; <b>raw</b></textarea>", "", 40).lines == @["<x> <b>raw</b>"]
doAssert layout("<title>T</title><title>second</title>body", "", 40).title == "Tsecond"
doAssert layout("<h2>long heading that must wrap too</h2>", "", 12).lines == @["long heading", "that must", "wrap too"]
doAssert layout("<pre>a very long preformatted line that exceeds the width</pre>", "", 10).lines == @["a very long preformatted line that exceeds the width"]
let inputs = layout("<form><input type=text placeholder=Search><input type=submit value=Go><input type=checkbox checked></form>", "", 40)
doAssert inputs.lines == @["[Search][Go][x]"]

# plain text and feeds
doAssert plainPage("a\r\nb\n").lines == @["a", "b", ""]
doAssert looksLikeFeed("<?xml version=\"1.0\"?>\n<!-- c -->\n<rss version=\"2.0\">", "text/xml")
doAssert looksLikeFeed("\xEF\xBB\xBF<feed xmlns=\"http://www.w3.org/2005/Atom\">", "")
doAssert looksLikeFeed("<rdf:RDF>", "")
doAssert not looksLikeFeed("<!DOCTYPE html><html>", "text/html")
doAssert not looksLikeFeed("plain", "")
doAssert feedLinks("""<html><head><link rel="alternate" type="application/rss+xml" href="/feed.xml">
<link rel="stylesheet" href="s.css"><link rel="alternate" type="application/atom+xml" href="atom"></head><body><link rel=alternate type=application/rss+xml href=late></body>""", "https://s.example/blog/") ==
  @["https://s.example/feed.xml", "https://s.example/blog/atom"]

# charsets
doAssert charsetOf("", "text/html; charset=Shift_JIS") == "shift_jis"
doAssert charsetOf("<html><head><meta charset=\"EUC-JP\">", "text/html") == "euc-jp"
doAssert charsetOf("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1252\">", "") == "windows-1252"
doAssert charsetOf("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><rss>", "application/xml") == "iso-8859-1"
doAssert charsetOf("\xEF\xBB\xBFx", "") == "utf-8"
doAssert charsetOf("<html><body>plain", "text/html") == ""
let sjis = "\x93\xfa\x96\x7b\x8c\xea"  # 日本語 in Shift_JIS
doAssert decodeDocument(sjis, "text/html; charset=Shift_JIS") == "日本語"
doAssert decodeDocument("<meta charset=euc-jp>\xc6\xfc\xcb\xdc", "text/html") == "<meta charset=euc-jp>日本"
doAssert decodeDocument("caf\xe9", "text/html; charset=iso-8859-1") == "café"
doAssert decodeDocument("\xEF\xBB\xBFbom", "") == "bom"
doAssert decodeDocument("bad\xff", "text/html; charset=utf-8") == "bad�"
doAssert decodeDocument("x\xff", "text/html; charset=x-unknown-charset") == "x�"
echo "html ok"
