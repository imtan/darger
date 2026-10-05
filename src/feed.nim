## RSS 2.0, Atom and RSS 1.0 (RDF) feeds parsed with std/parsexml, the subscription
## list in ~/.darger-feeds and the read entries in ~/.darger-rss-read.
import std/[parsexml, streams, strutils, times, os, algorithm, unicode]
import html, fileio

type
  Entry* = object
    feed*, feedUrl*: string      ## the feed's title and subscribed URL
    title*, link*, id*, author*: string
    date*: Time                  ## Time() when the feed gave none
    content*: string             ## HTML: content when present, else the summary
  Feed* = object
    title*, link*: string
    entries*: seq[Entry]
  Subscription* = object
    url*, title*: string         ## title: "" until the feed is fetched, unless given

const
  maxRead* = 5000
  months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
  zones = {"gmt": 0, "ut": 0, "utc": 0, "z": 0, "est": -5, "edt": -4, "cst": -6, "cdt": -5,
    "mst": -7, "mdt": -6, "pst": -8, "pdt": -7, "jst": 9}

proc feedsPath*(): string = getHomeDir() / ".darger-feeds"
proc readPath*(): string = getHomeDir() / ".darger-rss-read"

proc entryKey*(e: Entry): string =
  ## What marks an entry read: its id, else its link, else its feed and title.
  if e.id.len > 0: e.id elif e.link.len > 0: e.link else: e.feedUrl & "\t" & e.title

proc digits(s: string): bool = s.len > 0 and s.allCharsInSet({'0'..'9'})

proc parseOffset(s: string): int =
  ## "+0900", "+09:00", "-05", "Z", "GMT", "EST" ... in seconds; low(int) when unknown.
  let z = s.toLowerAscii
  if z.len == 0: return low(int)
  for (name, hours) in zones:
    if z == name: return hours * 3600
  if z[0] notin {'+', '-'}: return low(int)
  var body = z[1..^1].replace(":", "")
  if body.len == 2: body.add "00"
  if body.len != 4 or not body.digits: return low(int)
  result = (parseInt(body[0..1]) * 60 + parseInt(body[2..3])) * 60
  if z[0] == '-': result = -result

proc utc(year, month, day, hour, minute, second, offset: int): Time =
  if month notin 1..12 or day notin 1..31 or hour notin 0..23 or minute notin 0..59 or
      second notin 0..60: return Time()
  try:
    let local = dateTime(year, Month(month), day, hour, minute, min(59, second), zone = utc())
    result = local.toTime - initDuration(seconds = offset)
  except CatchableError: result = Time()

proc parseRfc822(s: string): Time =
  ## "Sun, 05 Oct 2026 12:34:56 +0900"; the weekday, seconds and zone are optional.
  var parts = strutils.splitWhitespace(s.replace(",", " "))
  if parts.len > 0 and parts[0].toLowerAscii[0..<min(3, parts[0].len)] in months and parts.len > 1 and parts[1].digits:
    parts.insert("", 0)  # "Oct 05 2026": day and month swapped (seen in the wild)
    swap(parts[1], parts[2])
  if parts.len > 0 and not parts[0].digits: parts.delete(0)  # the weekday
  if parts.len < 3: return
  if not parts[0].digits: return
  let day = parseInt(parts[0])
  let month = months.find(parts[1].toLowerAscii[0..<min(3, parts[1].len)]) + 1
  if month == 0 or not parts[2].digits: return
  var year = parseInt(parts[2])
  if year < 100: year += (if year < 70: 2000 else: 1900)
  var hour, minute, second = 0
  var offset = 0
  if parts.len > 3:
    let clock = parts[3].split(':')
    if clock.len >= 2 and clock[0].digits and clock[1].digits:
      hour = parseInt(clock[0])
      minute = parseInt(clock[1])
      if clock.len > 2 and clock[2].digits: second = parseInt(clock[2])
    if parts.len > 4:
      offset = parseOffset(parts[4])
      if offset == low(int): offset = 0
  utc(year, month, day, hour, minute, second, offset)

proc parseIso(s: string): Time =
  ## "2026-10-05T12:34:56.789+09:00", "2026-10-05 12:34Z", "2026-10-05".
  var text = s
  var offset = 0
  var zoneAt = -1
  for i in countdown(text.high, 10):
    if text[i] in {'+', '-', 'Z', 'z'}:
      zoneAt = i
      break
  if zoneAt > 0:
    offset = parseOffset(text[zoneAt..^1])
    if offset == low(int): return
    text = text[0..<zoneAt]
  let datePart = text.split({'T', 't', ' '})
  let ymd = datePart[0].split('-')
  if ymd.len != 3 or not (ymd[0].digits and ymd[1].digits and ymd[2].digits) or ymd[0].len != 4: return
  var hour, minute, second = 0
  if datePart.len > 1 and datePart[1].len > 0:
    let clock = datePart[1].split(':')
    if clock.len < 2 or not clock[0].digits or not clock[1].digits: return
    hour = parseInt(clock[0])
    minute = parseInt(clock[1])
    if clock.len > 2:
      let sec = clock[2].split('.')[0]
      if sec.digits: second = parseInt(sec)
  utc(parseInt(ymd[0]), parseInt(ymd[1]), parseInt(ymd[2]), hour, minute, second, offset)

proc parseDate*(s: string): Time =
  ## RFC 822 (RSS) or ISO 8601 (Atom, dc:date); Time() when it cannot be read.
  let text = strutils.strip(s)
  if text.len == 0: return
  if text.len >= 10 and text[4] == '-' and text[0..3].digits: parseIso(text)
  else: parseRfc822(text)

proc escapeXml(s: string): string =
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

proc local(name: string): string =
  (if ':' in name: name.split(':')[^1] else: name).toLowerAscii

proc stripTags(s: string): string =
  var inTag = false
  for c in s:
    if c == '<': inTag = true
    elif c == '>': inTag = false
    elif not inTag: result.add c
  strutils.strip(result)

proc parseFeed*(xml, url: string): Feed =
  ## The feed's title, site link and entries, in document order. Items are the
  ## <item>/<entry> elements near the root; their text fields are taken by local name,
  ## so RSS 2.0, Atom, RDF and namespaced extensions (dc:date, content:encoded) share
  ## one path. Embedded XHTML content is serialized back to HTML.
  let text = decodeDocument(xml, "")
  var x: XmlParser
  x.open(newStringStream(text), url, {allowUnquotedAttribs, allowEmptyAttribs, reportWhitespace})
  defer: x.close()
  var feed: Feed
  var path: seq[string]        # local names of the open elements
  var entry: Entry
  var inEntry, hadTitle, atomLink = false
  var entryDepth = 0
  var field = ""               # the text field being read, "" = none
  var fieldDepth = 0           # path.len inside the field's element
  var value, linkRel, linkHref, published, updated, summary, content: string

  proc openElement(name: string, attrs: seq[(string, string)]) =
    let l = local(name)
    if field.len > 0:  # markup inside an XHTML field: keep it as HTML
      value.add "<" & l
      for (k, v) in attrs: value.add " " & k & "=\"" & v.replace("\"", "&quot;") & "\""
      value.add ">"
      path.add l
      return
    path.add l
    if not inEntry and path.len in 2..3 and l in ["item", "entry"]:
      inEntry = true
      entryDepth = path.len
      entry = Entry(feedUrl: url)
      (published, updated, summary, content) = ("", "", "", "")
      return
    let feedField = not inEntry and path.len in 2..3 and path[^2] in ["channel", "feed"]
    let entryField = inEntry and path.len == entryDepth + 1
    if not (feedField or entryField): return
    field = l
    fieldDepth = path.len
    value = ""
    atomLink = false
    linkRel = ""
    linkHref = ""
    if l == "link":
      for (k, v) in attrs:
        if k == "rel": linkRel = v.toLowerAscii
        elif k == "href":
          linkHref = v
          atomLink = true

  proc closeElement() =
    if path.len == 0: return
    let l = path.pop()
    if field.len > 0 and path.len >= fieldDepth:
      value.add "</" & l & ">"
      return
    if field.len > 0 and path.len == fieldDepth - 1:
      let v = strutils.strip(value)
      case field
      of "title":
        if inEntry: entry.title = v
        elif not hadTitle:
          feed.title = v
          hadTitle = true
      of "link":
        let href = strutils.strip(if atomLink: linkHref else: v)
        if href.len > 0 and linkRel in ["", "alternate"]:
          if inEntry:
            if entry.link.len == 0 or linkRel == "alternate": entry.link = href
          elif feed.link.len == 0: feed.link = href
      of "id", "guid":
        if inEntry: entry.id = v
      of "pubdate", "published", "issued", "date":
        if inEntry: published = v
      of "updated", "modified":
        if inEntry: updated = v
      of "description", "summary":
        if inEntry: summary = v
      of "encoded", "content", "body":
        if inEntry: content = v
      of "creator":
        if inEntry: entry.author = v
      of "author":
        if inEntry and entry.author.len == 0:
          let start = v.find("<name>")
          let stop = v.find("</name>")
          entry.author = if start >= 0 and stop > start: strutils.strip(v[start + 6..<stop]) else: stripTags(v)
      else: discard
      field = ""
      return
    if inEntry and path.len == entryDepth - 1:
      inEntry = false
      entry.date = parseDate(if published.len > 0: published else: updated)
      entry.content = if content.len > 0: content else: summary
      if entry.title.len == 0: entry.title = "(untitled)"
      feed.entries.add entry

  while true:
    x.next()
    case x.kind
    of xmlElementStart: openElement(x.elementName, @[])
    of xmlElementOpen:
      let name = x.elementName
      var attrs: seq[(string, string)]
      while true:
        x.next()
        if x.kind == xmlAttribute: attrs.add (x.attrKey.toLowerAscii, x.attrValue)
        elif x.kind in {xmlElementClose, xmlEof, xmlError}: break
      openElement(name, attrs)
    of xmlCharData, xmlWhitespace:
      if field.len > 0: value.add(if path.len > fieldDepth: escapeXml(x.charData) else: x.charData)
    of xmlCData:
      if field.len > 0: value.add x.charData
    of xmlEntity:
      if field.len > 0: value.add decodeEntities("&" & x.entityName & ";")
    of xmlElementEnd: closeElement()
    of xmlEof: break
    of xmlError: discard  # tolerated: the rest of the document still parses
    else: discard
  for e in feed.entries.mitems: e.feed = feed.title
  feed

proc feedPage*(feed: Feed, url: string): string =
  ## A feed shown in the browser: its entries as a list of links.
  result = "<h1>" & escapeXml(if feed.title.len > 0: feed.title else: url) & "</h1>"
  if feed.link.len > 0: result.add "<p><a href=\"" & feed.link.replace("\"", "&quot;") & "\">" & escapeXml(feed.link) & "</a></p>"
  result.add "<ul>"
  for e in feed.entries:
    result.add "<li>"
    if e.date != Time(): result.add "<small>" & e.date.local.format("yyyy-MM-dd") & "</small> "
    if e.link.len > 0: result.add "<a href=\"" & e.link.replace("\"", "&quot;") & "\">" & escapeXml(e.title) & "</a>"
    else: result.add escapeXml(e.title)
    result.add "</li>"
  result.add "</ul>"

proc entryPage*(e: Entry): string =
  ## An entry shown in the browser: title (linked), feed, date and author, then the body.
  result = "<h1>" & (if e.link.len > 0: "<a href=\"" & e.link.replace("\"", "&quot;") & "\">" & escapeXml(e.title) & "</a>" else: escapeXml(e.title)) & "</h1><p><small>"
  var meta = @[e.feed]
  if e.date != Time(): meta.add e.date.local.format("yyyy-MM-dd HH:mm")
  if e.author.len > 0: meta.add e.author
  result.add escapeXml(meta.join(" · ")) & "</small></p>"
  result.add e.content

proc sortEntries*(entries: var seq[Entry]) =
  ## Newest first; undated entries after the dated ones in feed order.
  entries.sort(proc(a, b: Entry): int =
    if a.date == b.date: 0
    elif a.date == Time(): 1
    elif b.date == Time(): -1
    else: cmp(b.date, a.date))

proc loadSubscriptions*(path = feedsPath()): seq[Subscription] =
  ## One URL per line, optionally followed by a space and a title; # starts a comment.
  var text: string
  try: text = readFile(path)
  except CatchableError: return
  for raw in text.splitLines:
    let line = strutils.strip(raw)
    if line.len == 0 or line[0] == '#' or validateUtf8(line) != -1: continue
    let cut = line.find({' ', '\t'})
    let url = if cut < 0: line else: line[0..<cut]
    var seen = false
    for s in result:
      if s.url == url: seen = true
    if seen: continue
    result.add Subscription(url: url, title: (if cut < 0: "" else: strutils.strip(line[cut..^1])))

proc addSubscription*(url: string, path = feedsPath()) =
  ## Appends url to the feeds file, keeping the file's other lines as they are.
  if url.len == 0 or '\n' in url or '\r' in url or ' ' in url: raise newException(ValueError, "Expected a URL")
  for s in loadSubscriptions(path):
    if s.url == url: raise newException(ValueError, "Already subscribed: " & url)
  var text: string
  try: text = readFile(path)
  except CatchableError: text = ""
  if text.len > 0 and not text.endsWith("\n"): text.add "\n"
  atomicWrite(path, text & url & "\n")

proc loadRead*(path = readPath()): seq[string] =
  ## Keys of the read entries, oldest first.
  var text: string
  try: text = readFile(path)
  except CatchableError: return
  for line in text.splitLines:
    if line.len > 0 and validateUtf8(line) == -1 and line notin result: result.add line

proc saveRead*(keys: seq[string], path = readPath()) =
  ## The newest maxRead keys, oldest first; errors are ignored like the recent list.
  let kept = if keys.len > maxRead: keys[keys.len - maxRead..^1] else: keys
  try: atomicWrite(path, kept.join("\n") & (if kept.len > 0: "\n" else: ""))
  except CatchableError: discard
