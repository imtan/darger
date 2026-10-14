## eww: a text web browser view over the editor, fetching with curl (fetch.nim) and
## laying HTML out with html.nim. Other views can show a page and take it back (webReturn).
import std/[os, strutils, unicode, tables, uri, browsers]
from windy import closeIme  # not the whole module: vmath's colour accessor b would shadow the buffer
import ../[core, buffer, buffers, render, lisp, html, feed, fetch, complete, syntax]

const
  webMessage* = "Web  Tab:next link  Enter:follow  l/r:back/forward  g:reload  G:url  &:browser  w:copy  v:source  q:close"
  webHead* = 2  # rows above the page: its URL and a blank line

type
  WebNav* = enum wnFollow, wnBack, wnForward, wnReload

var
  webBuf*: Buffer
  webFaces*: seq[seq[Face]]
  webPage*: Page
  webHtml*, webUrl*: string              # the shown document and its URL
  webIsHtml*: bool                      # false: shown as plain text
  webWidth*: int                        # the width webPage was laid out for
  webHistory*, webForward*: seq[(string, int)]  # l / r: URL and cursor line
  webFetch*: Fetch                      # the page being loaded, nil = none
  webNav*: WebNav                       # what webFetch is for
  webNavLine*: int                      # the cursor line to restore after back / forward / reload
  webReturn*: proc()                   # where q goes instead of the editor (a list's entry); nil = none

proc fetchCommand*(): seq[string] = splitCommand(interp.env.values["fetch-command"].asString)

proc webLayoutWidth*(): int = clamp((if renderer.cols > 0: renderer.cols else: 80) - 1, 20, 100)

proc buildWeb*(line = webHead) =
  ## Lays the document out for the current width; the first rows show its URL.
  webWidth = webLayoutWidth()
  webPage = if webIsHtml: layout(webHtml, webUrl, webWidth) else: plainPage(webHtml)
  var lines = @[webUrl, ""]
  var faces = @[newSeq[Face](webUrl.runeLen), newSeq[Face]()]
  for f in faces[0].mitems: f = dimFace
  lines.add webPage.lines
  faces.add webPage.faces
  webBuf = newBuffer(lines.join("\n"))
  webBuf.path = if webPage.title.len > 0: webPage.title else: webUrl  # the mode line
  webFaces = faces
  webBuf.cursor = (clamp(line, 0, webBuf.lines.high), 0)

proc enterWeb*() =
  ## Shows the page: over the editor, or in place of the RSS list it was opened from.
  if overlayOf(mode).len > 0:  # over another view, which webReturn brings back
    mode = "web"
    prefix = ""
    renderer.top = 0
    renderer.left = 0
    window.closeIme()
  else: beginOverlay("web")
  recenterCycle = 0

proc finishWeb*(toList = true) =
  if toList and webReturn != nil: webReturn()
  else: finishOverlay()
  webReturn = nil

proc webTarget*(input: string): string =
  ## A URL as typed, a host-like word with https://, anything else as a search.
  let s = strutils.strip(input)
  if s.len == 0: return ""
  if "://" in s or s.startsWith("file:") or s.startsWith("about:"): return s
  if ' ' notin s and ('.' in s[0..^2] or s.startsWith("localhost")): return "https://" & s
  interp.env.values["eww-search-prefix"].asString & encodeUrl(s)

proc loadWeb*(url: string, nav: WebNav, line = webHead) =
  ## Starts loading url; the page replaces the current one when it arrives.
  if webFetch != nil: webFetch.cancel()
  webFetch = startFetch(fetchCommand(), url, "web")
  webNav = nav
  webNavLine = line
  echoLine = "Loading " & url

proc webFollow*(url: string) = loadWeb(url, wnFollow)

proc webLinkAt*(): int =
  ## The link under the cursor, else the first one on its line; -1 when none.
  let line = webBuf.cursor.line - webHead
  result = -1
  for i, l in webPage.links:
    if l.line != line: continue
    if webBuf.cursor.col in l.startCol..<l.endCol: return i
    if result < 0: result = i

proc webLinkUrl*(): string =
  ## The link at point, else the page's URL.
  let i = webLinkAt()
  if i >= 0: webPage.links[i].url else: webUrl

proc webMoveLink*(delta: int) =
  ## Tab / Shift-Tab: the cursor goes to the next / previous link.
  let at = (webBuf.cursor.line - webHead, webBuf.cursor.col)
  var best = -1
  for i, l in webPage.links:
    let pos = (l.line, l.startCol)
    if delta > 0 and pos > at and (best < 0 or pos < (webPage.links[best].line, webPage.links[best].startCol)): best = i
    if delta < 0 and pos < at and (best < 0 or pos > (webPage.links[best].line, webPage.links[best].startCol)): best = i
  if best < 0:
    echoLine = if delta > 0: "No next link" else: "No previous link"
    return
  webBuf.cursor = (webPage.links[best].line + webHead, webPage.links[best].startCol)
  webBuf.goal = -1

proc webArrived*(f: Fetch) =
  ## The fetched document becomes the page; failures leave the current one.
  if f.error.len > 0 and (f.body.len == 0 or not f.error.startsWith("HTTP")):
    if not f.cancelled: echoLine = "Web: " & f.error
    return
  let kind = f.contentType.toLowerAscii
  var isHtml = true
  var document: string
  if looksLikeFeed(f.body, kind): document = feedPage(parseFeed(f.body, f.finalUrl), f.finalUrl)
  elif kind.len == 0 or kind.startsWith("text/") or "html" in kind or "xml" in kind or
      "json" in kind or "javascript" in kind:
    document = decodeDocument(f.body, f.contentType)
    isHtml = kind.len == 0 or "html" in kind or "xml" in kind
    if isHtml and kind.len == 0 and "<" notin document[0..<min(document.len, 512)]: isHtml = false
  else:
    echoLine = "Web: not shown (" & kind & "); & opens it in your browser"
    return
  let old = if webBuf != nil: (webUrl, webBuf.cursor.line) else: ("", 0)
  case webNav
  of wnFollow:
    if webBuf != nil: webHistory.add old  # from a list's entry too: l returns to the entry
    webForward = @[]
    if webHistory.len > 100: webHistory.delete(0)
  of wnBack: webForward.add old
  of wnForward: webHistory.add old
  of wnReload: discard
  webHtml = document
  webUrl = f.finalUrl
  webIsHtml = isHtml
  buildWeb(if webNav == wnFollow: webHead else: webNavLine)
  echoLine = if f.error.len > 0: "Web: " & f.error else: ""
  if mode in ["", "web", "rss"]:
    if mode != "web": enterWeb()
    renderer.top = 0
  elif overlayOf(mode) != "web": echoLine = "Page loaded (C-c w Enter)"  # shown behind a G prompt

proc overlayMove*(buf: Buffer, full, command: string): bool =
  ## Cursor movement shared by the web page and the RSS list; false when full is none.
  result = true
  if full in ["n", "C-n", "down", "p", "C-p", "up"] or command in ["next-line", "previous-line"]:
    buf.vertical(if full in ["p", "C-p", "up"] or command == "previous-line": -1 else: 1)
  elif full in ["C-v", "M-v", "pagedown", "pageup", " ", "backspace"]:
    page(buf, if full in [" ", "C-v", "pagedown"]: "C-v" else: "M-v")
  elif command in ["bob", "eob"] or full in ["M-<", "M->"]:
    let line = if command == "eob" or full == "M->": buf.lines.high else: 0
    buf.cursor = (line, 0)
    buf.goal = -1
  elif command in ["forward", "backward", "bol", "eol"]:
    discard buf.command(command)
  elif full == "C-l": recenter(buf)
  else: result = false

proc dispatchWeb*(c: string) =
  if c == "C-g" and webFetch != nil:
    webFetch.cancel()
    webFetch = nil
    echoLine = "Cancelled"
    return
  if c in ["q", "C-g", "escape"]:
    finishWeb()
    return
  let full = overlayKey(c)
  if full.len == 0: return
  let command = keymap.getOrDefault(full).symName
  if full != "C-l": recenterCycle = 0
  if full in ["enter", "C-m", "C-j", "f"]:
    let i = webLinkAt()
    if i < 0: echoLine = "No link here"
    else: webFollow(webPage.links[i].url)
  elif full == "tab" or full == "C-i": webMoveLink(if shift(): -1 else: 1)
  elif full == "l":
    if webHistory.len > 0:
      let (url, line) = webHistory.pop()
      loadWeb(url, wnBack, line)
    elif webReturn != nil: finishWeb()
    else: echoLine = "No previous page"
  elif full == "r":
    if webForward.len == 0: echoLine = "No next page"
    else:
      let (url, line) = webForward.pop()
      loadWeb(url, wnForward, line)
  elif full == "g":
    if webReturn != nil and webHistory.len == 0: echoLine = "Opened from a list; g refreshes there"
    else: loadWeb(webUrl, wnReload, webBuf.cursor.line)
  elif full == "G": beginMini("wurl", "URL or search: ")
  elif full == "&":
    let url = webLinkUrl()
    if url.len == 0: echoLine = "No URL"
    else:
      openDefaultBrowser(url)
      echoLine = "Opened " & url
  elif full == "w":
    if webLinkUrl().len == 0: echoLine = "No URL"
    else: copyText(webLinkUrl())
  elif full == "v":
    finishWeb(false)
    var buf = reg.byName("*web source*")
    if buf == nil:
      buf = newBuffer()
      reg.add(buf, "*web source*")
    buf.splice(0, buf.text.runeLen, webHtml)
    buf.modified = false
    buf.cursor = (0, 0)
    buf.finish()
    switchTo(buf)
    renderer.top = 0
  elif full == "f1" or command == "help":
    finishWeb(false)
    dispatch(full)
  elif full == "C-x C-c": quitEditor()
  elif command == "eww": finishWeb()
  elif not overlayMove(webBuf, full, command): echoLine = full & " is undefined"

proc pollWeb(): bool =
  ## A finished download becomes the page; true when it did.
  if webFetch != nil and webFetch.poll():
    let f = webFetch
    webFetch = nil
    webArrived(f)
    result = true

interp.defPrimitive("eww", proc(args: seq[Value]): Value =
  args.arity(0, 1)
  if args.len > 0:
    let url = webTarget(args[0].asString)
    if url.len == 0: raise newException(LispError, "Expected a URL")
    try: webFollow(url)
    except CatchableError as e: raise newException(LispError, e.msg)
  elif mode == "web": finishWeb()
  elif mode in ["", "eval", "execute"]:
    beginMini("web-url", (if webBuf != nil: "URL or search (Enter: last page): " else: "URL or search: "))
  else: echoLine = "eww is unavailable here"
  nilValue())

defineMode(Mode(name: "web", tag: "[Web]", modeName: "Web", buffer: proc(): Buffer = webBuf,
  faces: proc(): seq[seq[Face]] = webFaces,
  message: proc(): string =
    (if webFetch != nil: "Loading " & webFetch.url & "  " & webFetch.elapsedText & "  C-g:cancel"
     elif echoLine.len > 0: echoLine else: webMessage),
  beforeDraw: proc() = (if webLayoutWidth() != webWidth: buildWeb(webBuf.cursor.line)),
  onKey: dispatchWeb, onClose: proc() = finishWeb(false)))

proc acceptWeb*(value: string): bool =
  let kind = mode
  if kind == "wurl": mode = "web"
  let url = webTarget(value)
  if url.len == 0:
    if kind == "web-url":
      if webBuf != nil: enterWeb() else: echoLine = "No page yet: type a URL or a search"
    return mode != kind
  webFollow(url)
  true
definePrompt(Prompt(kind: "web-url", text: true, onAccept: acceptWeb))
definePrompt(Prompt(kind: "wurl", text: true, over: "web", onAccept: acceptWeb))

tickHooks.add pollWeb
exitHooks.add proc() =
  if webFetch != nil: webFetch.cancel()
defaults.add """
(global-set-key "C-c w" 'eww)
(setq fetch-command "curl -sSL --max-time 30 --max-redirs 10 --compressed -A darger/0.1")
(setq eww-search-prefix "https://duckduckgo.com/html/?q=")
"""
