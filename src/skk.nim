## Pure DDSKK-like SKK input engine (no GUI imports).
## The editor feeds printable runes and named keys; for each SkkResult it inserts
## `text` (one undo step), moves the cursor by `move`, and when `consumed` is
## false it then handles the key as if SKK were off. `preedit` is drawn at the
## cursor, `echo` replaces the echo area, `tag` goes on the mode line.
import std/[unicode, strutils, tables, sets, algorithm, os, encodings, monotimes, times]
import fileio

type
  SkkKey* = enum skSpace, skEnter, skBackspace, skCtrlJ, skCtrlG, skTab
  KanaMode* = enum Hiragana, Katakana, Latin
  Stage* = enum Direct, Reading, Choosing  ## Reading = ▽, Choosing = ▼
  Dictionary* = Table[string, seq[string]]
  SkkResult* = object
    text*: string     ## insert into the buffer first (also when not consumed)
    consumed*: bool   ## false: the editor then handles the key as usual
    move*: int        ## cursor adjustment after inserting text
    preedit*: string  ## inline segment drawn at the cursor
    echo*: string     ## echo-area text after this key ("" clears)
    tag*: string      ## mode-line tag
  Skk* = ref object
    enabled*, loaded*: bool
    mode*: KanaMode
    stage*: Stage
    reading*, okuri*, pending*: string  ## hiragana reading / okurigana, pending romaji
    okuriActive: bool
    okuriPrefix: string
    candidates*: seq[string]
    index*: int  ## current candidate; from 4 on, the first one of a 7-candidate page
    dictionary*, user*: Dictionary
    userPath*: string  ## user dictionary rewritten on every kakutei when set

const
  tags: array[KanaMode, string] = ["[かな]", "[カナ]", "[SKK]"]
  # ponytail: "l" is the latin-mode key (as in DDSKK), so l-prefixed small kana are omitted.
  kanaRows = """
_ あ い う え お
k か き く け こ
s さ し す せ そ
t た ち つ て と
n な に ぬ ね の
h は ひ ふ へ ほ
m ま み む め も
y や - ゆ いぇ よ
r ら り る れ ろ
w わ うぃ う うぇ を
g が ぎ ぐ げ ご
z ざ じ ず ぜ ぞ
d だ ぢ づ で ど
b ば び ぶ べ ぼ
p ぱ ぴ ぷ ぺ ぽ
f ふぁ ふぃ ふ ふぇ ふぉ
j じゃ じ じゅ じぇ じょ
v ゔぁ ゔぃ ゔ ゔぇ ゔぉ
sh しゃ し しゅ しぇ しょ
ch ちゃ ち ちゅ ちぇ ちょ
ts つぁ つぃ つ つぇ つぉ
th てゃ てぃ てゅ てぇ てょ
dh でゃ でぃ でゅ でぇ でょ
x ぁ ぃ ぅ ぇ ぉ
xy ゃ - ゅ - ょ
"""
  yCombos = "ky=き sy=し ty=ち cy=ち ny=に hy=ひ my=み ry=り gy=ぎ zy=じ jy=じ " &
    "dy=ぢ by=び py=ぴ fy=ふ"
  singles = "nn=ん n'=ん xtu=っ xtsu=っ xwa=ゎ xka=ゕ xke=ゖ -=ー ~=〜 !=！ ?=？ :=： " &
    "[=「 ]=」 z/=・ z.=… z,=‥ z-=〜 zh=← zj=↓ zk=↑ zl=→ z[=『 z]=』"

proc buildRules(): Table[string, string] =
  for line in strutils.strip(kanaRows).splitLines:
    let parts = strutils.splitWhitespace(line)
    let prefix = if parts[0] == "_": "" else: parts[0]
    for i in 0..4:
      if parts[i+1] != "-": result[prefix & "aiueo"[i]] = parts[i+1]
  for pair in strutils.splitWhitespace(yCombos):
    for i, small in ["ゃ", "ぃ", "ゅ", "ぇ", "ょ"]:
      result[pair[0..1] & "aiueo"[i]] = pair[3..^1] & small
  for pair in strutils.splitWhitespace(singles):
    let sep = pair.find('=', 1)
    result[pair[0..<sep]] = pair[sep+1..^1]

const rules = buildRules()

proc buildPrefixes(): HashSet[string] =
  for key in rules.keys:
    for i in 1..<key.len: result.incl key[0..<i]

const prefixes = buildPrefixes()

proc startsRule(romaji: string): bool = romaji in rules or romaji in prefixes

proc doubled(pending: string, c: char): bool =
  pending.len == 1 and pending[0] == c and c in {'b'..'z'} - {'e', 'i', 'o', 'u', 'n'}

proc step(pending: var string, c: char): string =
  ## Feeds one romaji char and returns completed hiragana. "kk" gives っ with
  ## "k" still pending; a lone "n" before a non-continuing char becomes ん.
  if doubled(pending, c): return "っ"
  if not startsRule(pending & c):
    if pending == "n": result = "ん"
    pending = ""
  pending.add c
  if pending in rules:
    result.add rules[pending]
    pending = ""
  elif pending notin prefixes: pending = ""

proc flush(pending: var string): string =
  if pending == "n": result = "ん"
  pending = ""

proc toKana(hiragana: string, mode: KanaMode): string =
  if mode != Katakana: return hiragana
  for r in hiragana.runes:
    result.add(if r.int in 0x3041..0x3096: Rune(r.int + 0x60) else: r)

# Dictionaries

proc okuriAri(key: string): bool =
  key.len > 1 and key[0].ord >= 0x80 and key[^1] in {'a'..'z'}

proc parseDictionary*(data: string): Dictionary =
  for line in data.splitLines:
    if line.len == 0 or line[0] == ';': continue
    let sep = line.find(" /")
    if sep < 1: continue
    let key = line[0..<sep]
    let ari = okuriAri(key)
    var candidates: seq[string]
    for entry in line[sep+2..^1].split('/'):
      # ponytail: okuri-specific "[..]" blocks are ignored; "(concat ...)" stays raw.
      if ari and entry.startsWith('['): break
      let semi = entry.find(';')
      let candidate = if semi >= 0: entry[0..<semi] else: entry
      if candidate.len > 0 and candidate notin candidates: candidates.add candidate
    if candidates.len > 0: result[key] = candidates

proc serializeDictionary*(dictionary: Dictionary): string =
  # ponytail: keys are sorted; real SKK orders the user dictionary by recency.
  var keys: seq[string]
  for key in dictionary.keys: keys.add key
  keys.sort()
  for ari in [true, false]:
    result.add(if ari: ";; okuri-ari entries.\n" else: ";; okuri-nasi entries.\n")
    for key in keys:
      if okuriAri(key) == ari: result.add key & " /" & dictionary[key].join("/") & "/\n"

proc decodeDictionary*(raw: string): string =
  ## EUC-JP when the first line has a "coding: euc-jp" cookie, UTF-8 otherwise.
  let eol = raw.find('\n')
  let first = (if eol < 0: raw else: raw[0..<eol]).toLowerAscii
  if "coding:" notin first or "euc-j" notin first: return raw
  for encoding in ["EUC-JP", "20932"]:
    try: return convert(raw, "UTF-8", encoding)
    except CatchableError: discard
  raise newException(ValueError, "cannot decode EUC-JP dictionary")

proc loadDictionary*(s: Skk, path: string) =
  s.dictionary = parseDictionary(decodeDictionary(readFile(path)))

proc loadUserDictionary*(s: Skk, path: string) =
  ## A missing file is an empty dictionary. userPath is set only after a
  ## successful parse, so a broken file is never overwritten.
  s.user = if fileExists(path): parseDictionary(decodeDictionary(readFile(path)))
           else: initTable[string, seq[string]]()
  s.userPath = path

proc saveUserDictionary*(s: Skk) =
  # ponytail: whole-file rewrite on every kakutei.
  if s.userPath.len > 0: atomicWrite(s.userPath, serializeDictionary(s.user))

proc defaultDictionaryPath*(): string =
  result = getEnv("DARGER_SKK_JISYO")
  if result.len > 0: return
  let home = getHomeDir()
  for path in [home / "Dropbox/.emacs.d/skk-get-jisyo/SKK-JISYO.L",
               home / ".emacs.d/skk-get-jisyo/SKK-JISYO.L",
               home / ".skk/SKK-JISYO.L", "/usr/share/skk/SKK-JISYO.L"]:
    if fileExists(path): return path

proc loadDefaults*(s: Skk): string =
  ## Loads ~/.darger-skk-jisyo and the main dictionary; returns the echo message.
  let started = getMonoTime()
  s.loaded = true
  try: s.loadUserDictionary(getHomeDir() / ".darger-skk-jisyo")
  except CatchableError as e: result = "SKK user dictionary: " & e.msg & "; "
  let path = defaultDictionaryPath()
  if path.len == 0: return result & "SKK: no dictionary"
  try: s.loadDictionary(path)
  except CatchableError as e: return result & "SKK: " & path & ": " & e.msg
  result.add "SKK: " & $s.dictionary.len & " entries loaded (" &
    $(getMonoTime() - started).inMilliseconds & " ms)"

proc lookup*(s: Skk, reading: string, okuriPrefix = ""): seq[string] =
  ## User entries first, then the main dictionary; key = reading & okuriPrefix.
  let key = reading & okuriPrefix
  result = s.user.getOrDefault(key)
  for candidate in s.dictionary.getOrDefault(key):
    if candidate notin result: result.add candidate

# Engine state

proc newSkk*(dictionary = initTable[string, seq[string]]()): Skk =
  Skk(dictionary: dictionary)

proc reset(s: Skk) =
  s.stage = Direct
  s.reading = ""
  s.okuri = ""
  s.pending = ""
  s.okuriActive = false
  s.okuriPrefix = ""
  s.candidates = @[]
  s.index = 0

proc tag*(s: Skk): string =
  if s.enabled: tags[s.mode] else: ""

proc preedit*(s: Skk): string =
  if not s.enabled: return ""
  case s.stage
  of Direct: s.pending
  of Reading:
    "▽" & toKana(s.reading, s.mode) &
      (if s.okuriActive: "*" & toKana(s.okuri, s.mode) else: "") & s.pending
  of Choosing: "▼" & s.candidates[s.index] & toKana(s.okuri, s.mode)

proc page*(s: Skk): string =
  ## Candidate list for the echo area while past the 4th candidate.
  if s.stage != Choosing or s.index < 4: return ""
  for i in s.index ..< min(s.index + 7, s.candidates.len):
    if i > s.index: result.add ' '
    result.add "ASDFJKL"[i - s.index] & ":" & s.candidates[i]
  result.add "  [残り " & $max(0, s.candidates.len - s.index - 7) & "]"

proc finish(s: Skk, res: var SkkResult) =
  res.preedit = s.preedit
  if res.echo.len == 0: res.echo = s.page
  res.tag = s.tag

proc okuriKey(s: Skk): string =
  if s.okuriActive and s.okuri.len > 0: s.okuriPrefix else: ""

proc continues(s: Skk, c: char): bool =
  s.pending.len > 0 and (startsRule(s.pending & c) or doubled(s.pending, c))

proc convert(s: Skk, res: var SkkResult) =
  s.candidates = s.lookup(s.reading, s.okuriKey)
  if s.candidates.len > 0:
    s.stage = Choosing
    s.index = 0
  elif s.dictionary.len == 0 and s.user.len == 0: res.echo = "No dictionary"
  else: res.echo = "No candidates for " & s.reading & s.okuriKey
  # ponytail: no dictionary registration; the reading stays in ▽.

proc typeKana(s: Skk, c: char, res: var SkkResult) =
  ## Romaji into the buffer (Direct) or into the ▽ reading / okurigana.
  if s.okuriActive and s.okuri.len == 0 and s.pending.len == 0: s.okuriPrefix = $c
  let kana = step(s.pending, c)
  if s.stage == Direct:
    res.text.add toKana(kana, s.mode)
  elif s.okuriActive:
    s.okuri.add kana
    if s.okuri.len > 0 and s.pending.len == 0 and s.okuri != "っ": s.convert(res)
  else:
    s.reading.add kana

proc commitReading(s: Skk, mode: KanaMode): string =
  ## ▽ kakutei as typed (no learning).
  let tail = flush(s.pending)
  if s.okuriActive: s.okuri.add tail else: s.reading.add tail
  result = toKana(s.reading & s.okuri, mode)
  s.reset()

proc commitCandidate(s: Skk, res: var SkkResult) =
  ## ▼ kakutei: insert, move the choice to the front of the user entry, save.
  let chosen = s.candidates[s.index]
  let key = s.reading & s.okuriKey
  res.text.add chosen & toKana(s.okuri, s.mode)
  var entries = @[chosen]
  for candidate in s.user.getOrDefault(key):
    if candidate != chosen: entries.add candidate
  s.user[key] = entries
  s.reset()
  try: s.saveUserDictionary()
  except CatchableError as e: res.echo = "SKK: cannot save user dictionary: " & e.msg

proc direct(s: Skk, c: char, next: Rune, res: var SkkResult) =
  ## A key in Direct stage with nothing pending.
  case c
  of 'q': s.mode = if s.mode == Hiragana: Katakana else: Hiragana
  of 'l': s.mode = Latin
  of '(':
    res.text.add "（）"
    res.move = -1
  of ')':
    if next == Rune(0xFF09): res.move = 1 else: res.text.add "）"
  of ';': s.stage = Reading
  of 'L': discard  # ponytail: no zenkaku-latin mode
  of 'A'..'K', 'M'..'Z':
    s.stage = Reading
    s.typeKana(c.toLowerAscii, res)
  elif startsRule($c): s.typeKana(c, res)
  else: res.consumed = false  # digits, ".", ",", non-ASCII: plain insert

proc feedRune(s: Skk, r: Rune, next: Rune, res: var SkkResult) =
  res.consumed = true
  let c = if r.int < 0x80: char(r.int) else: '\0'
  let lower = c.toLowerAscii
  case s.stage
  of Direct:
    if s.continues(c): s.typeKana(c, res)
    else:
      res.text.add toKana(flush(s.pending), s.mode)
      if c == '\0': res.consumed = false
      else: s.direct(c, next, res)
  of Reading:
    if (c in {'A'..'Z'} or c == ';') and not s.okuriActive and
        (s.reading.len > 0 or s.pending == "n"):
      s.reading.add flush(s.pending)
      s.okuriActive = true  # ";" leaves the okuri prefix to the next letter
      if c != ';': s.typeKana(lower, res)
    elif c == ';': discard
    elif s.continues(lower) or (lower != 'l' and startsRule($lower)):
      s.typeKana(lower, res)
    elif lower == 'q':
      res.text.add s.commitReading(if s.mode == Katakana: Hiragana else: Katakana)
    elif lower == 'l':
      res.text.add s.commitReading(s.mode)
      s.mode = Latin
    else:  # digits, punctuation, non-ASCII: kakutei, then handle in Direct
      res.text.add s.commitReading(s.mode)
      s.feedRune(r, next, res)
  of Choosing:
    if c == 'x':
      if s.index == 0: s.stage = Reading
      elif s.index <= 4: dec s.index
      else: s.index -= 7
    elif s.index >= 4:
      let pick = "asdfjkl".find(c)
      if c != '\0' and pick >= 0 and s.index + pick < s.candidates.len:
        s.index += pick
        s.commitCandidate(res)
      # ponytail: other keys are ignored while the candidate page is shown.
    else:
      s.commitCandidate(res)
      s.feedRune(r, next, res)

proc feedKey(s: Skk, key: SkkKey, res: var SkkResult) =
  res.consumed = true
  case s.stage
  of Direct:
    case key
    of skBackspace:
      if s.pending.len > 0: s.pending.setLen(s.pending.len - 1)
      else: res.consumed = false
    of skCtrlG:
      if s.pending.len > 0: s.pending = "" else: res.consumed = false
    of skCtrlJ: res.text = toKana(flush(s.pending), s.mode)
    of skSpace, skEnter, skTab:
      res.text = toKana(flush(s.pending), s.mode)
      res.consumed = false
  of Reading:
    case key
    of skSpace:
      let tail = flush(s.pending)
      if s.okuriActive: s.okuri.add tail else: s.reading.add tail
      if s.reading.len == 0:
        s.reset()
        res.consumed = false
      else: s.convert(res)
    of skEnter, skCtrlJ: res.text = s.commitReading(s.mode)  # egg-like: no newline
    of skBackspace:
      if s.pending.len > 0: s.pending.setLen(s.pending.len - 1)
      elif s.okuri.len > 0: s.okuri.setLen(s.okuri.len - s.okuri.lastRune(s.okuri.high)[1])
      elif s.okuriActive: s.okuriActive = false
      elif s.reading.len > 0:
        s.reading.setLen(s.reading.len - s.reading.lastRune(s.reading.high)[1])
      else: s.reset()
    of skCtrlG: s.reset()
    of skTab: discard  # ponytail: no completion
  of Choosing:
    case key
    of skSpace:
      let next = if s.index < 4: s.index + 1 else: s.index + 7
      if next < s.candidates.len: s.index = next
      else: res.echo = "No more candidates"
    of skEnter, skCtrlJ: s.commitCandidate(res)
    of skBackspace, skCtrlG: s.stage = Reading  # keeps the reading
    of skTab: discard

proc feed*(s: Skk, r: Rune, next = Rune(0)): SkkResult =
  ## A printable key; `next` is the character after the cursor (for ")").
  if s.enabled and s.mode != Latin: s.feedRune(r, next, result)
  s.finish(result)

proc feed*(s: Skk, key: SkkKey): SkkResult =
  if s.enabled and s.mode == Latin:
    if key == skCtrlJ:
      s.mode = Hiragana
      result.consumed = true
  elif s.enabled: s.feedKey(key, result)
  s.finish(result)

proc toggle*(s: Skk): SkkResult =
  ## C-x C-j. Turning off commits whatever is in progress.
  case s.stage
  of Direct: result.text = toKana(flush(s.pending), s.mode)
  of Reading: result.text = s.commitReading(s.mode)
  of Choosing: s.commitCandidate(result)
  s.enabled = not s.enabled
  s.mode = Hiragana
  result.consumed = true
  s.finish(result)
