import std/[os, tempfiles, times, strutils]
import ../src/feed

# dates
let t = parseDate("Sun, 05 Oct 2026 12:34:56 +0900")
doAssert t != Time()
doAssert t.utc.format("yyyy-MM-dd HH:mm:ss") == "2026-10-05 03:34:56"
doAssert parseDate("05 Oct 2026 12:34 GMT") == parseDate("Sun, 05 Oct 2026 12:34:00 +0000")
doAssert parseDate("Mon, 5 Oct 26 12:34:56 EST") == parseDate("2026-10-05T17:34:56Z")
doAssert parseDate("2026-10-05T12:34:56+09:00") == t
doAssert parseDate("2026-10-05T03:34:56.123Z") == t
doAssert parseDate("2026-10-05 03:34:56") == t
doAssert parseDate("2026-10-05").utc.format("yyyy-MM-dd HH:mm") == "2026-10-05 00:00"
doAssert parseDate("") == Time()
doAssert parseDate("yesterday") == Time()
doAssert parseDate("2026-13-45") == Time()
doAssert parseDate("Sun, 32 Oct 2026 12:34:56 +0900") == Time()

# RSS 2.0 with namespaces, CDATA, escaped HTML and entities
let rss = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:atom="http://www.w3.org/2005/Atom">
<channel>
  <title>Example &amp; Blog</title>
  <link>https://example.com/</link>
  <atom:link href="https://example.com/feed" rel="self" type="application/rss+xml"/>
  <image><title>logo title</title><url>x</url></image>
  <item>
    <title>First &lt;post&gt;</title>
    <link>https://example.com/1</link>
    <guid isPermaLink="false">tag:1</guid>
    <pubDate>Sun, 05 Oct 2026 12:34:56 +0900</pubDate>
    <dc:creator>Alice</dc:creator>
    <description>&lt;p&gt;Summary &amp;amp; more&lt;/p&gt;</description>
    <content:encoded><![CDATA[<p>Full <b>body</b> &nbsp;here</p>]]></content:encoded>
  </item>
  <item>
    <title>Second</title>
    <link>https://example.com/2</link>
    <description>Plain&nbsp;text&#8217;s</description>
    <author>bob@example.com (Bob)</author>
  </item>
  <item><link>https://example.com/3</link></item>
</channel>
</rss>"""
let f = parseFeed(rss, "https://example.com/feed")
doAssert f.title == "Example & Blog", f.title
doAssert f.link == "https://example.com/"
doAssert f.entries.len == 3
doAssert f.entries[0].title == "First <post>"
doAssert f.entries[0].link == "https://example.com/1"
doAssert f.entries[0].id == "tag:1"
doAssert f.entries[0].date == t
doAssert f.entries[0].author == "Alice"
doAssert f.entries[0].content == "<p>Full <b>body</b> &nbsp;here</p>", f.entries[0].content
doAssert f.entries[0].feed == "Example & Blog" and f.entries[0].feedUrl == "https://example.com/feed"
doAssert f.entries[0].entryKey == "tag:1"
doAssert f.entries[1].content == "Plain text’s", f.entries[1].content
doAssert f.entries[1].author == "bob@example.com (Bob)"
doAssert f.entries[1].date == Time()
doAssert f.entries[1].entryKey == "https://example.com/2"
doAssert f.entries[2].title == "(untitled)"

# Atom with xhtml content, alternate links and author/name
let atom = """<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title type="text">Atom Feed</title>
  <link rel="self" href="https://a.example/feed.atom"/>
  <link rel="alternate" type="text/html" href="https://a.example/"/>
  <updated>2026-10-01T00:00:00Z</updated>
  <entry>
    <title>Entry one</title>
    <link rel="enclosure" href="https://a.example/1.mp3"/>
    <link href="https://a.example/1"/>
    <id>urn:uuid:1</id>
    <published>2026-10-05T03:34:56Z</published>
    <updated>2026-10-06T00:00:00Z</updated>
    <author><name>Carol</name><uri>https://a.example/carol</uri></author>
    <summary>short</summary>
    <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Para <a href="/x">link</a> &amp; <em>em</em></p></div></content>
  </entry>
  <entry>
    <title>Entry two</title>
    <link rel="alternate" href="https://a.example/2"/>
    <updated>2026-10-04T00:00:00Z</updated>
    <content type="html">&lt;p&gt;html&lt;/p&gt;</content>
  </entry>
</feed>"""
let a = parseFeed(atom, "https://a.example/feed.atom")
doAssert a.title == "Atom Feed"
doAssert a.link == "https://a.example/"
doAssert a.entries.len == 2
doAssert a.entries[0].link == "https://a.example/1"
doAssert a.entries[0].id == "urn:uuid:1"
doAssert a.entries[0].date == t
doAssert a.entries[0].author == "Carol"
doAssert a.entries[0].content == "<div xmlns=\"http://www.w3.org/1999/xhtml\"><p>Para <a href=\"/x\">link</a> &amp; <em>em</em></p></div>", a.entries[0].content
doAssert a.entries[1].link == "https://a.example/2"
doAssert a.entries[1].date == parseDate("2026-10-04T00:00:00Z")
doAssert a.entries[1].content == "<p>html</p>"
doAssert a.entries[1].entryKey == "https://a.example/2"

# RSS 1.0 (RDF), a non-UTF-8 declaration and a broken document
let rdf = """<?xml version="1.0" encoding="EUC-JP"?>
<rdf:RDF xmlns="http://purl.org/rss/1.0/" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:dc="http://purl.org/dc/elements/1.1/">
<channel rdf:about="https://r.example/"><title>""" & "\xc6\xfc\xcb\xdc" & """</title><link>https://r.example/</link>
<items><rdf:Seq><rdf:li rdf:resource="https://r.example/1"/></rdf:Seq></items></channel>
<item rdf:about="https://r.example/1"><title>RDF item</title><link>https://r.example/1</link><dc:date>2026-10-05T03:34:56Z</dc:date><description>d</description></item>
</rdf:RDF>"""
let r = parseFeed(rdf, "https://r.example/rss")
doAssert r.title == "日本", r.title
doAssert r.entries.len == 1 and r.entries[0].title == "RDF item" and r.entries[0].date == t
doAssert r.entries[0].link == "https://r.example/1" and r.entries[0].content == "d"
let broken = parseFeed("<rss><channel><title>T</title><item><title>a</title><link>l</link></item><item><title>b", "u")
doAssert broken.title == "T" and broken.entries.len == 1 and broken.entries[0].title == "a"
doAssert parseFeed("<html><body>not a feed</body></html>", "u").entries.len == 0
doAssert parseFeed("", "u").entries.len == 0

# pages and sorting
var entries = @[f.entries[1], a.entries[1], f.entries[0]]
sortEntries(entries)
doAssert entries[0].title == "First <post>" and entries[1].title == "Entry two" and entries[2].title == "Second"
let page = feedPage(f, "https://example.com/feed")
doAssert page.startsWith("<h1>Example &amp; Blog</h1><p><a href=\"https://example.com/\">")
doAssert "<a href=\"https://example.com/1\">First &lt;post&gt;</a>" in page
let ep = entryPage(f.entries[0])
doAssert ep.startsWith("<h1><a href=\"https://example.com/1\">First &lt;post&gt;</a></h1><p><small>Example &amp; Blog · ")
doAssert ep.endsWith(" · Alice</small></p><p>Full <b>body</b> &nbsp;here</p>")

# subscriptions and read state
let dir = createTempDir("darger-feed-", "")
let feeds = dir / "feeds"
doAssert loadSubscriptions(feeds).len == 0
writeFile(feeds, "# comment\nhttps://one.example/rss  One Blog\n\nhttps://two.example/atom\nhttps://one.example/rss\n")
let subs = loadSubscriptions(feeds)
doAssert subs.len == 2
doAssert subs[0].url == "https://one.example/rss" and subs[0].title == "One Blog"
doAssert subs[1].url == "https://two.example/atom" and subs[1].title == ""
addSubscription("https://three.example/feed", feeds)
doAssert loadSubscriptions(feeds).len == 3 and loadSubscriptions(feeds)[2].url == "https://three.example/feed"
doAssert readFile(feeds).startsWith("# comment\n")
var refused = false
try: addSubscription("https://one.example/rss", feeds)
except ValueError: refused = true
doAssert refused
refused = false
try: addSubscription("not a url", feeds)
except ValueError: refused = true
doAssert refused
let read = dir / "read"
doAssert loadRead(read).len == 0
saveRead(@["a", "b", "a"], read)
doAssert loadRead(read) == @["a", "b"]
var many: seq[string]
for i in 0..<maxRead + 10: many.add $i
saveRead(many, read)
let kept = loadRead(read)
doAssert kept.len == maxRead and kept[0] == "10" and kept[^1] == $(maxRead + 9)
removeDir(dir)
echo "feed ok"
