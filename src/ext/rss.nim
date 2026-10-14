## An RSS / Atom reader: a list view of every subscribed feed's entries, each shown as a
## page by the web view. Feeds come from (rss-feed "url") and the a key.
import std/[os, strutils, unicode, tables, sets, times, browsers]
from windy import closeIme  # not the whole module: vmath's colour accessor b would shadow the buffer
import ../[core, buffer, buffers, render, lisp, html, feed, fetch, complete, syntax]
import web

const
  rssMessage* = "RSS  Enter:read  r/u:read/unread  R:all read  g:refresh  a:add  s:filter  &:browser  w:copy  q:close"

var
  rssBuf*: Buffer
  rssFaces*: seq[seq[Face]]
  rssSubs*: seq[Subscription]
  rssEntries*: seq[feed.Entry]          # every feed's entries, newest first
  rssShown*: seq[int]                   # rssEntries indexes of the listed rows
  rssRead*: seq[string]                 # read entry keys, oldest first, and the same as a set
  rssReadSet*: HashSet[string]
  rssFetches*: seq[Fetch]
  rssTotal*: int                        # feeds in the current refresh
  rssBefore*: HashSet[string]           # keys known before it, to count new entries
  rssFailed*: seq[string]
  rssStatus*, rssFilter*: string
  rssTop*, rssWidth*: int                # the list's scroll while an entry is shown; its layout width
  rssLoaded*: bool

proc showEntry*(e: feed.Entry) =
  ## An RSS entry as a page: its body with the title linked to the article; q returns here.
  if overlayOf(mode) == "rss": rssTop = renderer.top
  webReturn = proc() =
    if rssBuf == nil: finishOverlay()
    else:
      mode = "rss"
      echoLine = ""
      renderer.top = rssTop
      renderer.left = 0
  webHistory = @[]
  webForward = @[]
  webHtml = entryPage(e)
  webUrl = e.link
  webIsHtml = true
  buildWeb()
  enterWeb()

proc markRead*(e: feed.Entry, read = true) =
  let key = e.entryKey
  if read == (key in rssReadSet): return
  if read:
    rssRead.add key
    rssReadSet.incl key
  else:
    rssRead.delete(rssRead.find(key))
    rssReadSet.excl key
  saveRead(rssRead)

proc buildRss*(selected = "") =
  ## The entry list: date, feed and title per row, read rows dim; selected (a key) keeps
  ## its row, else the cursor stays on the same row number.
  let row = if rssBuf != nil: rssBuf.cursor.line else: 1
  rssWidth = max(20, (if renderer.cols > 0: renderer.cols else: 80) - 1)
  rssShown = @[]
  var unread = 0
  for i, e in rssEntries:
    if e.entryKey notin rssReadSet: inc unread
    if rssFilter.len == 0 or matches(rssFilter, e.feed & " " & e.title): rssShown.add i
  var header = $rssSubs.len & " feeds  " & $unread & " unread / " & $rssEntries.len & " entries"
  if rssFilter.len > 0: header.add "  filter: " & rssFilter
  if rssFetches.len > 0: header.add "  fetching " & $(rssTotal - rssFetches.len) & "/" & $rssTotal
  elif rssStatus.len > 0: header.add "  " & rssStatus
  var lines = @[header]
  var faces = @[newSeq[Face]()]
  var feedWidth = 0
  for i in rssShown: feedWidth = max(feedWidth, min(20, cells(rssEntries[i].feed)))
  var cursor = row
  for n, i in rssShown:
    let e = rssEntries[i]
    if selected.len > 0 and e.entryKey == selected: cursor = n + 1
    let date = if e.date != times.Time(): e.date.local.format("yyyy-MM-dd HH:mm") else: spaces(16)
    let title = e.title.replace("\r", " ").replace("\n", " ").replace("\t", " ")
    let text = cutCells(date & "  " & padCells(e.feed, feedWidth) & "  " & title, rssWidth)
    lines.add text
    var f = newSeq[Face](text.runeLen)
    let read = e.entryKey in rssReadSet
    for col in 0..<f.len:
      f[col] = if read: dimFace elif col < 16: fConstant elif col < 18 + feedWidth: fType else: fPlain
    faces.add f
  if rssShown.len == 0:
    lines.add(if rssSubs.len == 0: "No feeds yet: a adds one, or (rss-feed \"url\") in ~/.darger.el"
      elif rssEntries.len == 0 and rssFetches.len > 0: "Fetching..."
      elif rssFilter.len > 0: "(no matching entries)" else: "(no entries)")
  rssBuf = newBuffer(lines.join("\n"))
  rssBuf.path = "*RSS*"
  rssFaces = faces
  rssBuf.cursor = (clamp(cursor, 1, max(1, rssShown.len)), 0)

proc rssEntry*(): int =
  ## The rssEntries index on the cursor row, -1 off the rows.
  let n = rssBuf.cursor.line - 1
  if n in 0..rssShown.high: rssShown[n] else: -1

proc rssFetch*(url, tag: string) =
  for f in rssFetches:
    if f.url == url: return  # already on its way
  rssFetches.add startFetch(fetchCommand(), url, tag)

proc rssRefresh*() =
  ## Fetches every subscription; the list fills in as each one arrives.
  if rssSubs.len == 0:
    echoLine = "No feeds: a adds one, or (rss-feed \"url\") in ~/.darger.el"
    return
  if rssFetches.len == 0:
    rssFailed = @[]
    rssBefore = initHashSet[string]()
    for e in rssEntries: rssBefore.incl e.entryKey
    rssTotal = 0
  for s in rssSubs:
    inc rssTotal
    rssFetch(s.url, "rss")
  rssStatus = ""

proc rssFinished*() =
  ## The refresh is complete: say what is new and what failed.
  var fresh = 0
  for e in rssEntries:
    if e.entryKey notin rssBefore: inc fresh
  rssStatus = (if fresh > 0: $fresh & " new" else: "up to date") &
    (if rssFailed.len > 0: "  " & $rssFailed.len & " failed: " & rssFailed[0] else: "")
  if overlayOf(mode) notin ["rss", "web"]: echoLine = "RSS: " & rssStatus & " (C-c r)"

proc rssArrived*(f: Fetch) =
  let subUrl = if f.tag.startsWith("rss-alt:"): f.tag[8..^1] else: f.url
  var failure = ""
  if f.error.len > 0: failure = f.error
  elif not looksLikeFeed(f.body, f.contentType):
    # A site URL: follow its advertised feed once.
    let links = if "html" in f.contentType.toLowerAscii or f.contentType.len == 0:
        feedLinks(decodeDocument(f.body, f.contentType), f.finalUrl) else: @[]
    if links.len > 0 and f.tag == "rss":
      rssFetch(links[0], "rss-alt:" & f.url)
      return
    failure = "not a feed"
  if failure.len > 0: rssFailed.add hostOf(subUrl) & ": " & failure
  else:
    var parsed = parseFeed(f.body, subUrl)
    for s in rssSubs.mitems:
      if s.url == subUrl:
        if s.title.len == 0: s.title = parsed.title
        if s.title.len == 0: s.title = hostOf(subUrl)
        for e in parsed.entries.mitems: e.feed = s.title
    var kept: seq[feed.Entry]
    for e in rssEntries:
      if e.feedUrl != subUrl: kept.add e
    rssEntries = kept & parsed.entries
    sortEntries(rssEntries)
  if rssFetches.len == 0: rssFinished()
  if overlayOf(mode) == "rss":
    let i = rssEntry()
    buildRss(if i >= 0: rssEntries[i].entryKey else: "")

proc beginRss*() =
  beginOverlay("rss")
  if not rssLoaded:
    rssLoaded = true
    rssRead = loadRead()
    for k in rssRead: rssReadSet.incl k
    for s in loadSubscriptions():
      var known = false
      for have in rssSubs:
        if have.url == s.url: known = true
      if not known: rssSubs.add s
    if rssSubs.len > 0: rssRefresh()
  buildRss()

proc finishRss*() =
  finishOverlay()
  rssBuf = nil  # the fetches go on; the list is rebuilt when opened again

proc dispatchRss*(c: string) =
  if c in ["q", "C-g", "escape"]:
    finishRss()
    return
  let full = overlayKey(c)
  if full.len == 0: return
  let command = keymap.getOrDefault(full).symName
  if full != "C-l": recenterCycle = 0
  let i = rssEntry()
  if full in ["enter", "C-m", "C-j", "f"]:
    if i < 0: echoLine = "No entry here"
    else:
      markRead(rssEntries[i])
      showEntry(rssEntries[i])
  elif full in ["&", "b"]:
    if i < 0 or rssEntries[i].link.len == 0: echoLine = "No link"
    else:
      markRead(rssEntries[i])
      buildRss(rssEntries[i].entryKey)
      openDefaultBrowser(rssEntries[i].link)
      echoLine = "Opened " & rssEntries[i].link
  elif full in ["r", "u"]:
    if i >= 0:
      markRead(rssEntries[i], full == "r")
      buildRss(rssEntries[i].entryKey)
      if full == "r": rssBuf.vertical(1)
  elif full == "R":
    for n in rssShown: markRead(rssEntries[n])
    buildRss(if i >= 0: rssEntries[i].entryKey else: "")
  elif full == "g":
    rssRefresh()
    buildRss(if i >= 0: rssEntries[i].entryKey else: "")
  elif full == "a": beginMini("rss-add", "Add feed URL: ")
  elif full == "s": beginMini("rss-filter", "Filter entries: ", rssFilter)
  elif full == "w":
    if i < 0 or rssEntries[i].link.len == 0: echoLine = "No link"
    else: copyText(rssEntries[i].link)
  elif full == "f1" or command == "help":
    finishRss()
    dispatch(full)
  elif full == "C-x C-c": quitEditor()
  elif command == "rss": finishRss()
  elif overlayMove(rssBuf, full, command):
    rssBuf.cursor = (clamp(rssBuf.cursor.line, 1, max(1, rssShown.len)), 0)
  else: echoLine = full & " is undefined"

proc pollRss(): bool =
  ## Finished downloads become feed entries; true when something changed.
  var i = 0
  while i < rssFetches.len:
    if rssFetches[i].poll():
      let f = rssFetches[i]
      rssFetches.delete(i)
      rssArrived(f)
      result = true
    else: inc i

interp.defPrimitive("rss", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if mode == "rss": finishRss()
  elif mode in ["", "eval", "execute"]: beginRss()
  else: echoLine = "rss is unavailable here"
  nilValue())

interp.defPrimitive("rss-feed", proc(args: seq[Value]): Value =
  args.arity(1, 2)
  let url = strutils.strip(args[0].asString)
  if url.len == 0 or ' ' in url: raise newException(LispError, "Expected a URL")
  for s in rssSubs:
    if s.url == url: return args[0]
  rssSubs.add Subscription(url: url, title: (if args.len > 1: args[1].asString else: ""))
  args[0])

defineMode(Mode(name: "rss", tag: "[RSS]", modeName: "RSS", buffer: proc(): Buffer = rssBuf,
  faces: proc(): seq[seq[Face]] = rssFaces,
  message: proc(): string =
    (if echoLine.len > 0: echoLine
     elif rssFetches.len > 0: "RSS  fetching " & $(rssTotal - rssFetches.len) & "/" & $rssTotal & "  q:close"
     else: rssMessage),
  beforeDraw: proc() = (if max(20, renderer.cols - 1) != rssWidth: buildRss()),
  onKey: dispatchRss, onClose: finishRss))

definePrompt(Prompt(kind: "rss-add", text: true, over: "rss", onAccept: proc(value: string): bool =
  mode = "rss"
  if value.len == 0: return true
  let url = strutils.strip(value)
  for s in rssSubs:
    if s.url == url:
      echoLine = "Already subscribed: " & url
      return true
  addSubscription(url)
  rssSubs.add Subscription(url: url)
  if rssFetches.len == 0:
    rssFailed = @[]
    rssBefore = initHashSet[string]()
    for e in rssEntries: rssBefore.incl e.entryKey
    rssTotal = 0
  inc rssTotal
  rssFetch(url, "rss")
  buildRss()
  true))

definePrompt(Prompt(kind: "rss-filter", text: true, over: "rss", onAccept: proc(value: string): bool =
  mode = "rss"
  rssFilter = strutils.strip(value)
  buildRss()
  rssBuf.cursor = (1, 0)
  true))

argCommands.add "rss-feed"
tickHooks.add pollRss
exitHooks.add proc() =
  for f in rssFetches: f.cancel()
defaults.add """
(global-set-key "C-c r" 'rss)
"""
