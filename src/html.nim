## HTML for the eww-style viewer: a tolerant tokenizer (no external libraries, so
## Windows behaves the same), block layout wrapped to a width, links and faces.
import std/[strutils, unicode, uri, tables, encodings]
import buffer, syntax

type
  Link* = object
    line*, startCol*, endCol*: int  ## rune columns of the link text, endCol exclusive
    url*: string
  Page* = object
    title*: string
    lines*: seq[string]
    faces*: seq[seq[Face]]
    links*: seq[Link]
  TokKind = enum tkText, tkOpen, tkClose
  Tok = object
    kind: TokKind
    name, text: string
    attrs: seq[(string, string)]

const
  linkFace* = fString     ## blue-ish in both themes
  headingFace* = fFnname
  dimFace* = fComment
  codeFace* = fConstant
  entities = {
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
    "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
    "bull": "•", "middot": "·", "times": "×", "divide": "÷", "deg": "°", "plusmn": "±",
    "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶",
    "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "lArr": "⇐", "rArr": "⇒",
    "hearts": "♥", "spades": "♠", "clubs": "♣", "diams": "♦", "dagger": "†", "Dagger": "‡",
    "iexcl": "¡", "iquest": "¿", "brvbar": "¦", "uml": "¨", "ordf": "ª", "ordm": "º",
    "not": "¬", "shy": "", "macr": "¯", "sup1": "¹", "sup2": "²", "sup3": "³", "frac14": "¼",
    "frac12": "½", "frac34": "¾", "micro": "µ", "acute": "´", "cedil": "¸", "curren": "¤",
    "ensp": " ", "emsp": " ", "thinsp": " ", "zwnj": "", "zwj": "", "lrm": "", "rlm": "",
    "prime": "′", "Prime": "″", "oline": "‾", "frasl": "⁄", "infin": "∞", "ne": "≠",
    "le": "≤", "ge": "≥", "asymp": "≈", "equiv": "≡", "minus": "−", "lowast": "∗",
    "radic": "√", "sum": "∑", "prod": "∏", "part": "∂", "nabla": "∇", "isin": "∈",
    "forall": "∀", "exist": "∃", "empty": "∅", "and": "∧", "or": "∨", "cap": "∩", "cup": "∪",
    "int": "∫", "there4": "∴", "sim": "∼", "cong": "≅", "sub": "⊂", "sup": "⊃",
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "lambda": "λ",
    "mu": "μ", "pi": "π", "sigma": "σ", "tau": "τ", "phi": "φ", "omega": "ω", "Omega": "Ω",
    "Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ", "Pi": "Π", "Sigma": "Σ",
    "AElig": "Æ", "aelig": "æ", "Oslash": "Ø", "oslash": "ø", "szlig": "ß", "Ccedil": "Ç",
    "ccedil": "ç", "Ntilde": "Ñ", "ntilde": "ñ", "Agrave": "À", "agrave": "à", "Aacute": "Á",
    "aacute": "á", "Acirc": "Â", "acirc": "â", "Atilde": "Ã", "atilde": "ã", "Auml": "Ä",
    "auml": "ä", "Aring": "Å", "aring": "å", "Egrave": "È", "egrave": "è", "Eacute": "É",
    "eacute": "é", "Ecirc": "Ê", "ecirc": "ê", "Euml": "Ë", "euml": "ë", "Igrave": "Ì",
    "igrave": "ì", "Iacute": "Í", "iacute": "í", "Icirc": "Î", "icirc": "î", "Iuml": "Ï",
    "iuml": "ï", "Ograve": "Ò", "ograve": "ò", "Oacute": "Ó", "oacute": "ó", "Ocirc": "Ô",
    "ocirc": "ô", "Otilde": "Õ", "otilde": "õ", "Ouml": "Ö", "ouml": "ö", "Ugrave": "Ù",
    "ugrave": "ù", "Uacute": "Ú", "uacute": "ú", "Ucirc": "Û", "ucirc": "û", "Uuml": "Ü",
    "uuml": "ü", "Yacute": "Ý", "yacute": "ý", "yuml": "ÿ", "ETH": "Ð", "eth": "ð",
    "THORN": "Þ", "thorn": "þ", "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š",
    "Yuml": "Ÿ", "fnof": "ƒ", "circ": "ˆ", "tilde": "˜", "sbquo": "‚", "bdquo": "„",
    "permil": "‰", "lsaquo": "‹", "rsaquo": "›", "loz": "◊", "crarr": "↵", "check": "✓"}.toTable
  # Numeric references in 0x80..0x9F mean Windows-1252, as browsers do.
  cp1252 = ["€", "�", "‚", "ƒ", "„", "…", "†", "‡", "ˆ", "‰", "Š", "‹", "Œ", "�", "Ž",
    "�", "�", "‘", "’", "“", "”", "•", "–", "—", "˜", "™", "š", "›", "œ", "�",
    "ž", "Ÿ"]
  rawText = ["script", "style"]
  skipped = ["script", "style", "noscript", "template", "svg", "math", "iframe", "object",
    "embed", "canvas", "video", "audio", "map", "datalist", "head"]
  paragraphs = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "ul", "ol",
    "dl", "table", "figure", "form", "fieldset", "article", "section", "header", "footer",
    "main", "aside", "details", "address", "hr", "body", "html"]
  lineBlocks = ["div", "li", "dt", "dd", "tr", "nav", "center", "summary", "figcaption",
    "option", "caption", "legend", "menu", "thead", "tbody", "tfoot"]
  voids = ["br", "hr", "img", "input", "meta", "link", "base", "area", "col", "wbr",
    "source", "track", "embed", "param"]
  feedTypes = ["application/rss+xml", "application/atom+xml", "application/rdf+xml",
    "application/feed+json"]

proc sanitizeUtf8*(s: string): string =
  ## s with every invalid UTF-8 sequence replaced by U+FFFD.
  if validateUtf8(s) == -1: return s
  var i = 0
  while i < s.len:
    let c = s[i].uint8
    let n = if c < 0x80: 1 elif c shr 5 == 0b110: 2 elif c shr 4 == 0b1110: 3
            elif c shr 3 == 0b11110: 4 else: 0
    var ok = n > 0 and i + n <= s.len
    if ok:
      for k in 1..<n:
        if s[i + k].uint8 shr 6 != 0b10: ok = false
    if ok and n > 1:  # overlong forms, surrogates and > U+10FFFF
      let r = int(s.runeAt(i))
      ok = (n == 2 and r >= 0x80) or (n == 3 and r >= 0x800 and r notin 0xD800..0xDFFF) or
        (n == 4 and r in 0x10000..0x10FFFF)
    if ok:
      result.add s[i..<i + n]
      i += n
    else:
      result.add "�"
      inc i

proc decodeEntities*(s: string): string =
  ## &amp; &#NNN; &#xHH; and the common named references; the rest stay literal.
  var i = 0
  while i < s.len:
    if s[i] != '&':
      result.add s[i]
      inc i
      continue
    let semi = s.find(';', i + 1, min(s.len - 1, i + 12))
    if semi < 0:
      result.add '&'
      inc i
      continue
    let name = s[i + 1..<semi]
    if name.len > 1 and name[0] == '#':
      var code = -1
      try:
        code = if name[1] in {'x', 'X'}: parseHexInt(name[2..^1]) else: parseInt(name[1..^1])
      except ValueError: discard
      if code < 0:
        result.add '&'
        inc i
        continue
      if code in 0x80..0x9F: result.add cp1252[code - 0x80]
      elif code == 0 or code > 0x10FFFF or code in 0xD800..0xDFFF: result.add "�"
      else: result.add $Rune(code)
    elif name in entities: result.add entities[name]
    else:
      result.add '&'
      inc i
      continue
    i = semi + 1

proc isSpace(c: char): bool = c in {' ', '\t', '\n', '\r', '\f'}

iterator tokens(html: string): Tok =
  ## Tags, text and nothing else: comments, doctypes and processing instructions vanish.
  var i = 0
  var text = ""
  template flushText() =
    if text.len > 0:
      yield Tok(kind: tkText, text: decodeEntities(text))
      text = ""
  while i < html.len:
    let c = html[i]
    if c != '<':
      text.add c
      inc i
      continue
    if html.continuesWith("<!--", i):
      let close = html.find("-->", i + 4)
      flushText()
      i = if close < 0: html.len else: close + 3
      continue
    if i + 1 < html.len and html[i + 1] in {'!', '?'}:
      let close = html.find('>', i)
      flushText()
      i = if close < 0: html.len else: close + 1
      continue
    var j = i + 1
    let closing = j < html.len and html[j] == '/'
    if closing: inc j
    if j >= html.len or html[j] notin {'a'..'z', 'A'..'Z'}:
      text.add c  # a lone "<"
      inc i
      continue
    var name = ""
    while j < html.len and html[j] notin {' ', '\t', '\n', '\r', '\f', '>', '/'}:
      name.add html[j].toLowerAscii
      inc j
    var attrs: seq[(string, string)]
    while j < html.len and html[j] != '>':
      if html[j].isSpace or html[j] == '/':
        inc j
        continue
      var key = ""
      while j < html.len and html[j] notin {' ', '\t', '\n', '\r', '\f', '>', '/', '='}:
        key.add html[j].toLowerAscii
        inc j
      while j < html.len and html[j].isSpace: inc j
      var value = ""
      if j < html.len and html[j] == '=':
        inc j
        while j < html.len and html[j].isSpace: inc j
        if j < html.len and html[j] in {'"', '\''}:
          let quote = html[j]
          let close = html.find(quote, j + 1)
          value = html[j + 1..<(if close < 0: html.len else: close)]
          j = if close < 0: html.len else: close + 1
        else:
          while j < html.len and not html[j].isSpace and html[j] != '>':
            value.add html[j]
            inc j
      if key.len > 0: attrs.add (key, decodeEntities(value))
    i = min(html.len, j + 1)
    flushText()
    if closing:
      yield Tok(kind: tkClose, name: name)
      continue
    yield Tok(kind: tkOpen, name: name, attrs: attrs)
    if name in rawText or name == "textarea" or name == "title":
      # Raw text up to the closing tag; textarea and title still decode entities.
      let close = html.toLowerAscii.find("</" & name, i)
      let stop = if close < 0: html.len else: close
      let body = html[i..<stop]
      if name notin rawText and body.len > 0:
        yield Tok(kind: tkText, text: decodeEntities(body))
      i = stop
  flushText()

proc attr(t: Tok, key: string): string =
  for (k, v) in t.attrs:
    if k == key: return v

proc hasAttr(t: Tok, key: string): bool =
  for (k, _) in t.attrs:
    if k == key: return true

proc resolveUrl*(base, href: string): string =
  ## href against base; a bare fragment keeps base, a scheme or unparsable href stays.
  let h = strutils.strip(href)
  if h.len == 0: return ""
  if base.len == 0: return h
  try:
    let rel = parseUri(h)
    if rel.scheme.len > 0: return h
    result = $combine(parseUri(base), rel)
  except ValueError: result = h

type Writer = object
  width, indent, col, pending: int
  lines: seq[seq[Rune]]
  faces: seq[seq[Face]]
  spans: seq[seq[(int, int, int)]]  # per line: start col, end col, link index
  cur: seq[Rune]
  curFaces: seq[Face]
  curSpans: seq[(int, int, int)]
  space, started: bool
  prefix: string  # a list bullet, written once at the start of the next line

proc flushLine(w: var Writer) =
  while w.cur.len > 0 and w.cur[^1] == Rune(' '):
    w.cur.setLen(w.cur.len - 1)
    w.curFaces.setLen(w.cur.len)
  if w.curSpans.len > 0 and w.curSpans[^1][1] > w.cur.len:
    w.curSpans[^1][1] = w.cur.len
  w.lines.add w.cur
  w.faces.add w.curFaces
  w.spans.add w.curSpans
  w.cur = @[]
  w.curFaces = @[]
  w.curSpans = @[]
  w.col = 0
  w.space = false

proc breakLine(w: var Writer, blank: bool) =
  if w.started: w.pending = max(w.pending, if blank: 2 else: 1)
  w.space = false

proc hardBreak(w: var Writer) =
  ## <br>: consecutive ones stack into empty lines.
  if not w.started: return
  if w.pending > 0:
    w.flushLine()
    if w.pending == 2: w.lines.add @[]; w.faces.add @[]; w.spans.add @[]
    w.pending = 0
  if w.cur.len > 0: w.flushLine()
  else:
    w.lines.add @[]
    w.faces.add @[]
    w.spans.add @[]

proc put(w: var Writer, r: Rune, face: Face, link: int) =
  if w.pending > 0:
    if w.cur.len > 0: w.flushLine()
    if w.pending == 2 and w.lines.len > 0 and w.lines[^1].len > 0:
      w.lines.add @[]
      w.faces.add @[]
      w.spans.add @[]
    w.pending = 0
  if w.col == 0:
    let indent = min(w.indent, w.width div 2)
    let head = indent - min(indent, w.prefix.runeLen)
    for _ in 0..<head:
      w.cur.add Rune(' ')
      w.curFaces.add fPlain
    for p in w.prefix.runes:
      w.cur.add p
      w.curFaces.add fPlain
    w.col = head + w.prefix.runeLen
    w.prefix = ""
  w.started = true
  if link >= 0:
    if w.curSpans.len > 0 and w.curSpans[^1][2] == link and w.curSpans[^1][1] == w.cur.len:
      w.curSpans[^1][1] = w.cur.len + 1
    else: w.curSpans.add (w.cur.len, w.cur.len + 1, link)
  w.cur.add r
  w.curFaces.add face
  w.col += cellWidth(r, w.col)

proc newLine(w: var Writer) =
  w.flushLine()

proc cells(rs: openArray[Rune]): int =
  for r in rs: result += runeWidth(r)

proc flow(w: var Writer, s: string, face: Face, link: int) =
  ## Normal text: whitespace collapses, words wrap at spaces and around wide (CJK) runes.
  let runes = s.toRunes
  var i = 0
  while i < runes.len:
    let r = runes[i]
    if r == Rune(' ') or r == Rune('\t') or r == Rune('\n') or r == Rune('\r') or
        r == Rune(0x0C) or r == Rune(0xA0):
      if w.cur.len > 0 and w.pending == 0: w.space = true
      inc i
      continue
    var word: seq[Rune]
    while i < runes.len:
      let c = runes[i]
      if c == Rune(' ') or c == Rune('\t') or c == Rune('\n') or c == Rune('\r') or
          c == Rune(0x0C) or c == Rune(0xA0): break
      if word.len > 0 and (runeWidth(c) == 2 or runeWidth(word[^1]) == 2): break
      if int(c) < 32 or int(c) == 127:
        inc i
        continue
      word.add c
      inc i
    if word.len == 0: continue
    let indent = min(w.indent, w.width div 2)
    let width = cells(word)
    let gap = if w.space: 1 else: 0
    if w.pending == 0 and w.col > indent and w.col + gap + width > w.width: w.newLine()
    elif w.space and w.pending == 0:
      # A space inside a link joins its range; one before it stays plain.
      let joins = link >= 0 and w.curSpans.len > 0 and w.curSpans[^1][2] == link and
        w.curSpans[^1][1] == w.cur.len
      w.put(Rune(' '), if joins: face else: fPlain, if joins: link else: -1)
    w.space = false
    for c in word:
      if w.col > indent and w.col + runeWidth(c) > w.width: w.newLine()
      w.put(c, face, link)

proc preformatted(w: var Writer, s: string, face: Face, link: int) =
  var text = s.replace("\r\n", "\n").replace('\r', '\n')
  if not w.started or (w.pending > 0 and text.startsWith("\n")): text.removePrefix("\n")
  var first = true
  for part in text.split('\n'):
    if not first: w.hardBreak()
    first = false
    for r in part.runes:
      if int(r) < 32 and r != Rune('\t'): continue
      w.put(r, face, link)

type Builder = object
  w: Writer
  base: string
  urls: seq[string]
  title: string
  titled: bool
  stack: seq[string]
  faceStack: seq[Face]
  link: int
  lists: seq[(bool, int)]  # ordered, items so far
  quote, pre, skip, cell: int

proc face(b: Builder): Face =
  if b.link >= 0: linkFace
  elif b.faceStack.len > 0: b.faceStack[^1]
  else: fPlain

proc setIndent(b: var Builder) =
  b.w.indent = 2 * b.lists.len + 4 * b.quote

proc open(b: var Builder, t: Tok) =
  let name = t.name
  if name in skipped:
    if name != "head": inc b.skip
  if b.skip > 0 and name != "title": return
  case name
  of "title":
    if not b.titled: b.titled = true
  of "base":
    if t.attr("href").len > 0: b.base = resolveUrl(b.base, t.attr("href"))
  of "br": b.w.hardBreak()
  of "hr":
    b.w.breakLine(true)
    for _ in 0..<min(b.w.width - b.w.indent, 40): b.w.put(Rune(0x2500), dimFace, -1)
    b.w.breakLine(true)
  of "img":
    let alt = strutils.strip(t.attr("alt"))
    if alt.len > 0: b.w.flow("[" & alt & "]", dimFace, b.link)
    elif b.link >= 0: b.w.flow("[image]", dimFace, b.link)
  of "a":
    let url = resolveUrl(b.base, t.attr("href"))
    if url.len > 0:
      b.urls.add url
      b.link = b.urls.high
    b.stack.add name
  of "ul", "ol":
    b.w.breakLine(b.lists.len == 0)  # nested lists stay inside their item
    b.lists.add (name == "ol", 0)
    b.setIndent()
    b.stack.add name
  of "li":
    b.w.breakLine(false)
    if b.lists.len == 0:
      b.lists.add (false, 0)
      b.setIndent()
    inc b.lists[^1][1]
    b.w.prefix = if b.lists[^1][0]: $b.lists[^1][1] & ". " else: "• "
    # continuation lines align under the text, so "10. " indents more than "• "
    b.w.indent = max(b.w.indent, 2 * b.lists.len - 2 + b.w.prefix.runeLen)
    b.stack.add name
  of "dd", "blockquote":
    b.w.breakLine(name == "blockquote")
    inc b.quote
    b.setIndent()
    b.stack.add name
  of "pre":
    b.w.breakLine(true)
    inc b.pre
    b.stack.add name
  of "h1", "h2", "h3", "h4", "h5", "h6":
    b.w.breakLine(true)
    b.faceStack.add headingFace
    b.stack.add name
  of "code", "kbd", "samp", "tt", "var":
    b.faceStack.add codeFace
    b.stack.add name
  of "cite", "small", "sub", "sup", "del", "s", "time":
    b.faceStack.add dimFace
    b.stack.add name
  of "td", "th":
    if b.w.col > b.w.indent and b.w.pending == 0:
      b.w.put(Rune(' '), fPlain, -1)
      b.w.put(Rune(' '), fPlain, -1)
      b.w.space = false
    b.stack.add name
  of "input":
    let kind = t.attr("type").toLowerAscii
    if kind in ["submit", "button"] and t.attr("value").len > 0:
      b.w.flow("[" & t.attr("value") & "]", dimFace, -1)
    elif kind in ["checkbox", "radio"]: b.w.flow(if t.hasAttr("checked"): "[x]" else: "[ ]", dimFace, -1)
    elif kind notin ["hidden"]: b.w.flow("[" & (if t.attr("placeholder").len > 0: t.attr("placeholder") else: "____") & "]", dimFace, -1)
  else:
    if name in paragraphs: b.w.breakLine(true)
    elif name in lineBlocks: b.w.breakLine(false)
    if name notin voids: b.stack.add name

proc close(b: var Builder, name: string) =
  if name in skipped and name != "head":
    if b.skip > 0: dec b.skip
    return
  if b.skip > 0: return
  if name == "title":
    b.titled = false
    return
  if name in voids or name notin b.stack: return
  # Pop up to and including name, undoing what each popped element set up.
  while b.stack.len > 0:
    let top = b.stack.pop()
    case top
    of "a": b.link = -1
    of "ul", "ol":
      if b.lists.len > 0: discard b.lists.pop()
      b.setIndent()
      b.w.breakLine(b.lists.len == 0)
    of "li":
      b.w.prefix = ""
      b.setIndent()
      b.w.breakLine(false)
    of "dd", "blockquote":
      if b.quote > 0: dec b.quote
      b.setIndent()
      b.w.breakLine(top == "blockquote")
    of "pre":
      if b.pre > 0: dec b.pre
      b.w.breakLine(true)
    of "h1", "h2", "h3", "h4", "h5", "h6", "code", "kbd", "samp", "tt", "var", "cite", "small",
       "sub", "sup", "del", "s", "time":
      if b.faceStack.len > 0: discard b.faceStack.pop()
      if top[0] == 'h': b.w.breakLine(true)
    else:
      if top in paragraphs: b.w.breakLine(true)
      elif top in lineBlocks: b.w.breakLine(false)
    if top == name: break

proc text(b: var Builder, s: string) =
  if b.titled:
    if b.skip == 0: b.title.add s
    return
  if b.skip > 0: return
  if b.pre > 0: b.w.preformatted(s, b.face, b.link)
  else: b.w.flow(s, b.face, b.link)

proc layout*(html, base: string, width: int): Page =
  ## The document as lines of at most width cells (long preformatted lines excepted).
  var b = Builder(base: base, link: -1)
  b.w.width = max(10, width)
  for t in tokens(html):
    case t.kind
    of tkText: b.text(t.text)
    of tkOpen: b.open(t)
    of tkClose: b.close(t.name)
  b.w.flushLine()
  while b.w.lines.len > 0 and b.w.lines[^1].len == 0:
    b.w.lines.setLen(b.w.lines.len - 1)
    b.w.faces.setLen(b.w.lines.len)
    b.w.spans.setLen(b.w.lines.len)
  result.title = strutils.strip(b.title.decodeEntities.replace('\n', ' ').replace('\r', ' ').replace('\t', ' '))
  while "  " in result.title: result.title = result.title.replace("  ", " ")
  for i, line in b.w.lines:
    result.lines.add $line
    result.faces.add b.w.faces[i]
    for (start, stop, link) in b.w.spans[i]:
      result.links.add Link(line: i, startCol: start, endCol: stop, url: b.urls[link])

proc plainPage*(text: string): Page =
  ## A text document shown as is.
  for line in text.replace("\r\n", "\n").split('\n'):
    result.lines.add line
    result.faces.add newSeq[Face](line.runeLen)

proc feedLinks*(html, base: string): seq[string] =
  ## Feed autodiscovery: <link rel=alternate type=application/rss+xml href=...>.
  var baseUrl = base
  for t in tokens(html):
    if t.kind != tkOpen: continue
    if t.name == "body": break
    if t.name == "base" and t.attr("href").len > 0: baseUrl = resolveUrl(baseUrl, t.attr("href"))
    if t.name != "link": continue
    let rel = t.attr("rel").toLowerAscii
    let kind = t.attr("type").toLowerAscii
    if "alternate" in rel and kind in feedTypes and t.attr("href").len > 0:
      result.add resolveUrl(baseUrl, t.attr("href"))

proc looksLikeFeed*(body, contentType: string): bool =
  ## XML whose root is rss, feed or rdf:RDF, whatever the server called it.
  var i = 0
  while i < body.len:
    i = body.find('<', i)
    if i < 0: return false
    if i + 1 < body.len and body[i + 1] in {'?', '!'}:
      let close = body.find('>', i)
      if close < 0: return false
      i = close + 1
      continue
    var name = ""
    var j = i + 1
    while j < body.len and body[j] notin {' ', '\t', '\n', '\r', '>', '/'}:
      name.add body[j]
      inc j
    return name.toLowerAscii in ["rss", "feed", "rdf:rdf"]
  false

proc charsetOf*(raw, contentType: string): string =
  ## The declared charset, lower-case: the header, a BOM, <meta charset>, <meta
  ## http-equiv>, or an XML declaration; "" when none.
  proc after(s: string, key: string): string =
    let i = s.toLowerAscii.find(key)
    if i < 0: return ""
    var j = i + key.len
    while j < s.len and s[j] in {' ', '\t', '"', '\'', '='}: inc j
    while j < s.len and s[j] notin {' ', '\t', '"', '\'', ';', '>', '/', '\n', '\r', ','}:
      result.add s[j].toLowerAscii
      inc j
  result = after(contentType, "charset=")
  if result.len > 0: return
  if raw.startsWith("\xEF\xBB\xBF"): return "utf-8"
  if raw.startsWith("\xFF\xFE") or raw.startsWith("\xFE\xFF"): return "utf-16"
  let head = raw[0..<min(raw.len, 4096)]
  if head.startsWith("<?xml"):
    let stop = head.find("?>")
    let decl = if stop > 0: head[0..stop] else: head
    result = after(decl, "encoding=")
    if result.len > 0: return
  for t in tokens(head):
    if t.kind != tkOpen: continue
    if t.name == "meta":
      if t.attr("charset").len > 0: return t.attr("charset").toLowerAscii
      if t.attr("http-equiv").toLowerAscii == "content-type":
        result = after(t.attr("content"), "charset=")
        if result.len > 0: return
    elif t.name == "body": break

proc canonicalCharset(name: string): string =
  ## The name std/encodings understands on Windows (code pages) and iconv alike.
  let n = name.toLowerAscii.replace("_", "-")
  case n
  of "", "utf-8", "utf8", "ascii", "us-ascii": ""
  of "shift-jis", "shiftjis", "sjis", "x-sjis", "ms932", "windows-31j", "cp932", "ms-kanji":
    when defined(windows): "shift_jis" else: "CP932"
  of "euc-jp", "eucjp", "x-euc-jp": "EUC-JP"
  of "iso-2022-jp", "csiso2022jp": "ISO-2022-JP"
  of "euc-kr", "ks-c-5601-1987", "cp949": "EUC-KR"
  of "gb2312", "gbk", "gb-2312", "cp936", "x-gbk": "GBK"
  of "gb18030": "GB18030"
  of "big5", "big-5", "cp950": "BIG5"
  of "iso-8859-1", "latin1", "latin-1", "windows-1252", "cp1252": "WINDOWS-1252"
  of "koi8-r": "KOI8-R"
  of "utf-16", "utf-16le": "UTF-16LE"
  of "utf-16be": "UTF-16BE"
  else:
    if n.startsWith("iso-8859-") or n.startsWith("windows-125"): n.toUpperAscii else: ""

proc decodeDocument*(raw, contentType: string): string =
  ## raw as UTF-8: converted from its declared charset when that is known, invalid
  ## bytes replaced, a BOM dropped.
  var s = raw
  let charset = canonicalCharset(charsetOf(raw, contentType))
  if charset.len > 0:
    try: s = convert(raw, "UTF-8", charset)
    except CatchableError: discard  # unknown to this platform: keep the bytes
  s.removePrefix("\xEF\xBB\xBF")
  sanitizeUtf8(s)
