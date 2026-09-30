## Table-driven syntax highlighting: one pass over the buffer, one Face per rune.
import std/[unicode, sets, strutils, os]

type
  Face* = enum
    fPlain, fComment, fString, fKeyword, fFnname, fVariable, fType, fConstant, fBuiltin
  StringRule = object
    open, close: string
    multiline: bool
    isChar: bool  # only 'x' or '\…': Rust lifetimes and stray quotes stay plain
    escape: char  # '\0': none
  Special = enum spText, spCode, spMarkdown, spOrg
  Lang* = object
    name*: string
    lineComment: string
    blockComments: seq[(string, string)]
    nested: bool           # block comments nest (Nim, Rust)
    strings: seq[StringRule]
    keywords, builtins, types, constants: HashSet[string]
    identExtra: set[char]  # besides letters, digits and '_'
    lisp: bool             # extras may start a symbol; the head of a list is a call
    capitalTypes: bool
    preproc: bool          # C '#include' lines
    macroBang: bool        # Rust 'name!'
    spacedComment: bool    # the line comment needs whitespace before it (shell, YAML)
    sections: bool         # TOML '[table]' lines
    keys: set[char]        # a string, or a line's first word, before one of these is a key
    sigils: set[char]      # '$x', '${x}', '@x' are variables
    symbolPrefix: char     # ':sym' is a constant
    heredoc: bool          # shell '<<EOF' bodies
    special: Special

const
  fnDefiners = ["def", "proc", "func", "fn", "defun", "defmacro", "defsubst", "function",
    "method", "iterator", "template", "macro", "converter"]
  typeDefiners = ["class", "type", "struct", "enum", "trait", "interface", "module", "union",
    "concept", "class_name"]
  varDefiners = ["var", "let", "const", "mut", "local", "defvar", "defcustom", "defconst",
    "defparameter"]
  wordChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc words(s: string): HashSet[string] = strutils.splitWhitespace(s).toHashSet

proc rule(open: string, close = "", multiline = false, escape = '\\', isChar = false): StringRule =
  StringRule(open: open, close: (if close.len > 0: close else: open), multiline: multiline,
    escape: escape, isChar: isChar)

proc confLang(name: string): Lang =
  Lang(name: name, special: spCode, lineComment: "#", spacedComment: true,
    strings: @[rule("\"\"\"", multiline = true), rule("'''", multiline = true, escape = '\0'),
      rule("\""), rule("'", escape = '\0')],
    constants: words"true false null yes no on off",
    identExtra: {'-', '.'}, keys: {':', '='}, sections: true)

let
  text = Lang(name: "Text")
  nimLang = Lang(name: "Nim", special: spCode, lineComment: "#", nested: true,
    blockComments: @[("##[", "]##"), ("#[", "]#")],
    strings: @[rule("r\"\"\"", "\"\"\"", multiline = true, escape = '\0'),
      rule("\"\"\"", multiline = true, escape = '\0'), rule("r\"", "\"", escape = '\0'),
      rule("\""), rule("'", isChar = true)],
    keywords: words"""addr and as asm bind block break case cast concept const continue
      converter defer discard distinct div do elif else end enum except export finally for
      from func if import in include interface is isnot iterator let macro method mixin mod
      not notin object of or out proc ptr raise ref return shl shr static template try tuple
      type using var when while xor yield""",
    constants: words"true false nil",
    builtins: words"""echo len high low inc dec add del assert doAssert newSeq newString quit
      ord chr sizeof typeof defined declared new items pairs min max abs swap contains setLen
      result""",
    types: words"""int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float float32
      float64 bool char string cstring pointer seq array set openArray varargs void auto
      untyped typed byte range""",
    capitalTypes: true)
  python = Lang(name: "Python", special: spCode, lineComment: "#",
    strings: @[rule("\"\"\"", multiline = true), rule("'''", multiline = true), rule("\""),
      rule("'")],
    keywords: words"""and as assert async await break class continue def del elif else except
      finally for from global if import in is lambda nonlocal not or pass raise return try
      while with yield match case""",
    constants: words"True False None",
    builtins: words"""print len range open str int float list dict set tuple type isinstance
      super enumerate zip map filter sorted min max sum abs any all repr input iter next
      hasattr getattr setattr object bool bytes""",
    capitalTypes: true)
  ruby = Lang(name: "Ruby", special: spCode, lineComment: "#",
    blockComments: @[("=begin", "=end")],
    strings: @[rule("\""), rule("'"), rule("`", multiline = true)],
    keywords: words"""alias and begin break case class def defined do else elsif end ensure
      for if in module next not or redo rescue retry return self super then undef unless
      until when while yield""",
    constants: words"true false nil",
    builtins: words"""require require_relative include extend attr_accessor attr_reader
      attr_writer puts print p raise lambda proc private protected public""",
    sigils: {'@', '$'}, symbolPrefix: ':', capitalTypes: true)
  gdscript = Lang(name: "GDScript", special: spCode, lineComment: "#",
    strings: @[rule("\"\"\"", multiline = true), rule("\""), rule("'")],
    keywords: words"""if elif else for while match break continue pass return class
      class_name extends is in as self signal func static const enum var await breakpoint
      and or not""",
    constants: words"true false null PI TAU INF NAN",
    builtins: words"print preload load len range str push_error push_warning",
    types: words"int float bool void",
    capitalTypes: true)
  js = Lang(name: "JS/TS", special: spCode, lineComment: "//", blockComments: @[("/*", "*/")],
    strings: @[rule("\""), rule("'"), rule("`", multiline = true)],
    keywords: words"""break case catch class const continue debugger default delete do else
      export extends finally for function if import in instanceof let new return super
      switch this throw try typeof var void while with yield async await of static get set
      from as interface type enum implements private public protected readonly declare
      namespace abstract keyof""",
    constants: words"true false null undefined NaN Infinity",
    builtins: words"""console window document require module exports Math JSON parseInt
      parseFloat setTimeout setInterval""",
    types: words"string number boolean any unknown never object bigint symbol",
    capitalTypes: true)
  c = Lang(name: "C/C++", special: spCode, lineComment: "//", blockComments: @[("/*", "*/")],
    strings: @[rule("\""), rule("'", isChar = true)],
    keywords: words"""break case const continue default do else enum extern for goto if inline
      register restrict return sizeof static struct switch typedef union volatile while class
      namespace template typename public private protected virtual override new delete this
      throw try catch using operator friend constexpr noexcept static_cast dynamic_cast
      reinterpret_cast const_cast explicit mutable decltype final""",
    constants: words"true false NULL nullptr EOF",
    builtins: words"""printf fprintf sprintf snprintf malloc calloc realloc free memcpy memset
      strlen std""",
    types: words"""void char short int long float double signed unsigned bool auto size_t
      ssize_t wchar_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t""",
    preproc: true)
  rust = Lang(name: "Rust", special: spCode, lineComment: "//", blockComments: @[("/*", "*/")],
    nested: true, strings: @[rule("\"", multiline = true), rule("'", isChar = true)],
    keywords: words"""as async await break const continue crate dyn else enum extern fn for if
      impl in let loop match mod move mut pub ref return self Self static struct super trait
      type unsafe use where while""",
    constants: words"true false",
    types: words"""i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str""",
    macroBang: true, capitalTypes: true)
  go = Lang(name: "Go", special: spCode, lineComment: "//", blockComments: @[("/*", "*/")],
    strings: @[rule("\""), rule("`", multiline = true, escape = '\0'), rule("'", isChar = true)],
    keywords: words"""break case chan const continue default defer else fallthrough for func go
      goto if import interface map package range return select struct switch type var""",
    constants: words"true false nil iota",
    builtins: words"""append cap close complex copy delete imag len make new panic print println
      real recover""",
    types: words"""bool byte complex64 complex128 error float32 float64 int int8 int16 int32
      int64 uint uint8 uint16 uint32 uint64 uintptr rune string any""",
    capitalTypes: true)
  shell = Lang(name: "Shell", special: spCode, lineComment: "#", spacedComment: true,
    strings: @[rule("\"", multiline = true), rule("$'", "'", multiline = true),
      rule("'", multiline = true, escape = '\0'), rule("`", multiline = true)],
    keywords: words"""if then else elif fi case esac for while until do done in function select
      return break continue local export readonly declare unset shift source alias exit eval
      exec trap""",
    builtins: words"echo printf cd pwd read test set true false",
    sigils: {'$'}, heredoc: true)
  lisp = Lang(name: "Lisp", special: spCode, lineComment: ";", blockComments: @[("#|", "|#")],
    strings: @[rule("\"", multiline = true)],
    keywords: words"""defun defvar defcustom defconst defmacro defsubst defgroup defface
      defparameter setq setq-local let let* if when unless cond lambda progn prog1 while
      dolist dotimes and or not require provide use-package global-set-key define-key
      add-hook with-eval-after-load interactive condition-case unwind-protect catch throw
      save-excursion quote function""",
    constants: words"t nil",
    builtins: words"message format concat car cdr cons list apply funcall mapcar load-theme",
    identExtra: {'-', '*', '?', '!', '<', '>', '=', '/', '+'}, lisp: true, symbolPrefix: ':')
  json = Lang(name: "JSON", special: spCode, lineComment: "//", strings: @[rule("\"")],
    constants: words"true false null", keys: {':'})
  toml = confLang("TOML")
  yaml = confLang("YAML")
  markdown = Lang(name: "Markdown", special: spMarkdown)
  org = Lang(name: "Org", special: spOrg)

proc detect*(path: string, firstLine: string): Lang =
  case splitFile(path).ext.toLowerAscii
  of ".nim", ".nims", ".nimble": nimLang
  of ".py", ".pyi": python
  of ".rb", ".rake": ruby
  of ".gd": gdscript
  of ".js", ".mjs", ".ts", ".tsx", ".jsx": js
  of ".c", ".h", ".cpp", ".hpp", ".cc": c
  of ".rs": rust
  of ".go": go
  of ".sh", ".bash", ".zsh": shell
  of ".el", ".lisp", ".scm", ".clj": lisp
  of ".json": json
  of ".toml": toml
  of ".yaml", ".yml": yaml
  of ".md", ".markdown": markdown
  of ".org": org
  else:
    case extractFilename(path)
    of "Gemfile", "Rakefile": return ruby
    of ".emacs": return lisp
    else: discard
    if firstLine.startsWith("#!"):
      let args = strutils.splitWhitespace(firstLine[2..^1])
      var program = if args.len > 0: args[0].extractFilename else: ""
      if program == "env" and args.len > 1: program = args[^1].extractFilename
      if program.startsWith("python"): return python
      if program.startsWith("ruby"): return ruby
      if program in ["sh", "bash", "zsh", "dash", "ksh"]: return shell
    text

proc ascii(r: Rune): char = (if int(r) < 128: chr(int(r)) else: '\x80')

proc isSpace(r: Rune): bool =
  if int(r) < 128: ascii(r) in Whitespace else: r.isWhiteSpace

proc isLetter(r: Rune): bool =
  if int(r) < 128: ascii(r) in Letters else: r.isAlpha

proc isWord(r: Rune): bool = r.isLetter or ascii(r) in wordChars

proc matchAt(line: seq[Rune], i: int, s: string, nocase = false): bool =
  if i < 0 or i + s.len > line.len: return false
  for k, ch in s:
    if (if nocase: ascii(line[i+k]).toLowerAscii != ch else: int(line[i+k]) != ord(ch)):
      return false
  true

proc paint(faces: var seq[Face], a, z: int, f: Face) =
  for k in max(0, a)..<min(z, faces.len): faces[k] = f

proc scanString(line: seq[Rune], i: int, rl: StringRule): (int, bool) =
  ## From inside a string at i: the end (past the closer) and whether it closed.
  var j = i
  while j < line.len:
    if rl.escape != '\0' and ascii(line[j]) == rl.escape: j += 2
    elif matchAt(line, j, rl.close): return (j + rl.close.len, true)
    else: inc j
  (line.len, false)

proc charEnd(line: seq[Rune], i: int, rl: StringRule): int =
  let j = i + rl.open.len
  if j + 1 >= line.len: return -1
  if rl.escape != '\0' and ascii(line[j]) == rl.escape:
    for k in j + 2 .. min(j + 11, line.len - 1):  # longest escape: Rust '\u{10FFFF}'
      if matchAt(line, k, rl.close): return k + rl.close.len
    return -1
  if matchAt(line, j + 1, rl.close) and not matchAt(line, j, rl.close): return j + 1 + rl.close.len
  -1

proc scanComment(lang: Lang, line: seq[Rune], i, index: int, depth: var int): int =
  let (open, close) = lang.blockComments[index]
  var j = i
  while j < line.len:
    if matchAt(line, j, close):
      j += close.len
      dec depth
      if depth == 0: return j
    elif lang.nested and matchAt(line, j, open):
      j += open.len
      inc depth
    else: inc j
  line.len

proc keyAt(line: seq[Rune], i: int, keys: set[char]): bool =
  var j = i
  while j < line.len and line[j].isSpace: inc j
  j < line.len and ascii(line[j]) in keys

proc indent(line: seq[Rune]): int =
  while result < line.len and line[result] in [Rune(' '), Rune('\t')]: inc result

proc runAt(line: seq[Rune], i: int, ch: Rune): int =
  var j = i
  while j < line.len and line[j] == ch: inc j
  j - i

proc code(lang: Lang, lines: seq[seq[Rune]], faces: var seq[seq[Face]]) =
  var
    comment = -1  # block comment left open by an earlier line
    depth = 0
    open = -1     # multi-line string left open
    prev = ""     # previous keyword, for 'proc name' and 'class Name'
    call = false  # Lisp: the next symbol heads a list
    args = false  # Lisp: the next list is an argument list
    term = ""     # shell heredoc terminator
  proc identStart(r: Rune): bool =
    r.isLetter or r == Rune('_') or (lang.lisp and ascii(r) in lang.identExtra)
  proc identPart(r: Rune): bool =
    r.isWord or ascii(r) in lang.identExtra
  for n, line in lines:
    var i = 0
    var first = true  # no token yet on this line
    template reset() =
      first = false
      prev = ""
      call = false
      args = false
    if term.len > 0:
      faces[n].paint(0, line.len, fString)
      if strutils.strip($line) == term: term = ""
      continue
    if comment >= 0:
      i = scanComment(lang, line, 0, comment, depth)
      faces[n].paint(0, i, fComment)
      if depth == 0: comment = -1
    elif open >= 0:
      let (e, closed) = scanString(line, 0, lang.strings[open])
      faces[n].paint(0, e, fString)
      i = e
      if closed: open = -1
    else:
      let ind = indent(line)
      if lang.preproc and ind < line.len and line[ind] == Rune('#'):
        i = ind + 1
        while i < line.len and line[i].isLetter: inc i
        faces[n].paint(ind, i, fBuiltin)
        var j = i
        while j < line.len and line[j].isSpace: inc j
        if $line[ind..<i] == "#include" and j < line.len and line[j] == Rune('<'):
          while j < line.len and line[j] != Rune('>'): inc j
          faces[n].paint(i, j + 1, fString)
          i = j + 1
      elif lang.sections and ind < line.len and line[ind] == Rune('[') and
          ($line).strip.endsWith("]"):
        faces[n].paint(ind, line.len, fKeyword)
        continue
    while i < line.len:
      let r = line[i]
      let ch = ascii(r)
      if r.isSpace:
        inc i
        continue
      var hit = false
      if lang.lisp and ch in {'?', '\\'} and i + 1 < line.len:
        # Elisp ?x, ?\x and \-escaped runes never open a string or comment.
        let e = min(line.len, i + (if ch == '?' and line[i+1] == Rune('\\'): 3 else: 2))
        if ch == '?': faces[n].paint(i, e, fConstant)
        i = e
        hit = true
      if not hit:
        for k, (o, _) in lang.blockComments:
          # Ruby '=begin' only opens a comment at column 0.
          if matchAt(line, i, o) and (o[0] != '=' or i == 0):
            depth = 1
            let e = scanComment(lang, line, i + o.len, k, depth)
            faces[n].paint(i, e, fComment)
            if depth > 0: comment = k
            i = e
            hit = true
            break
      if not hit and lang.lineComment.len > 0 and matchAt(line, i, lang.lineComment) and
          (not lang.spacedComment or i == 0 or line[i-1].isSpace):
        faces[n].paint(i, line.len, fComment)
        break
      if not hit:
        for k, rl in lang.strings:
          if not matchAt(line, i, rl.open): continue
          if lang.sections and i > 0 and identPart(line[i-1]): continue  # YAML: Don't panic
          var e: int
          if rl.isChar:
            e = charEnd(line, i, rl)
            if e < 0: continue
          else:
            let (z, closed) = scanString(line, i + rl.open.len, rl)
            e = z
            if not closed and rl.multiline: open = k
          faces[n].paint(i, e,
            if lang.keys != {} and open < 0 and keyAt(line, e, lang.keys): fVariable else: fString)
          i = e
          hit = true
          break
      if not hit and ch in lang.sigils and i + 1 < line.len:
        var e = i + 1
        while ch == '@' and e < line.len and line[e] == r: inc e
        if e < line.len and line[e] == Rune('{'):
          while e < line.len and line[e] != Rune('}'): inc e
          e = min(e + 1, line.len)
        elif e < line.len and identPart(line[e]):
          while e < line.len and identPart(line[e]): inc e
        elif e < line.len and ascii(line[e]) in {'?', '@', '#', '*', '!', '$', '-'}: inc e
        if e > i + 1:
          faces[n].paint(i, e, fVariable)
          i = e
          hit = true
      if not hit and lang.symbolPrefix != '\0' and ch == lang.symbolPrefix and
          i + 1 < line.len and identStart(line[i+1]) and
          (i == 0 or line[i-1] != r):
        var e = i + 1
        while e < line.len and identPart(line[e]): inc e
        faces[n].paint(i, e, fConstant)
        i = e
        hit = true
      if not hit and lang.heredoc and matchAt(line, i, "<<") and not matchAt(line, i, "<<<"):
        var a = i + 2
        if a < line.len and line[a] == Rune('-'): inc a
        while a < line.len and line[a].isSpace: inc a
        let q = a < line.len and ascii(line[a]) in {'\'', '"'}
        var z = a + ord(q)
        if z < line.len and (line[z].isLetter or line[z] == Rune('_')):
          while z < line.len and line[z].isWord: inc z
          term = $line[a + ord(q) ..< z]
          if q and z < line.len and line[z] == line[a]: inc z
          faces[n].paint(a, z, fString)
          i = z
          hit = true
      if hit:
        reset()
        continue
      if ch in {'0'..'9'}:
        let hex = ch == '0' and i + 1 < line.len and ascii(line[i+1]) in {'x', 'X'}
        var e = i + 1
        while e < line.len:
          let d = ascii(line[e])
          let next = if e + 1 < line.len: ascii(line[e+1]) else: '\0'
          # '.' only before a digit keeps '1..9' apart; the quote allows Nim 1'u8 and C++ 1'000.
          if d in wordChars or (d == '.' and next in {'0'..'9'}) or (d == '\'' and next in wordChars) or
              (d in {'+', '-'} and not hex and ascii(line[e-1]) in {'e', 'E'} and next in {'0'..'9'}):
            inc e
          else: break
        faces[n].paint(i, e, fConstant)
        i = e
        reset()
        continue
      if identStart(r):
        var e = i + 1
        while e < line.len and identPart(line[e]): inc e
        var word = newStringOfCap(e - i)
        for k in i..<e: word.add line[k]
        var face =
          if lang.keys != {} and first and keyAt(line, e, lang.keys): fVariable
          elif word in lang.keywords: fKeyword
          elif word in lang.constants: fConstant
          elif word in lang.builtins: fBuiltin
          elif word in lang.types: fType
          elif prev in typeDefiners: fType
          elif prev in fnDefiners: fFnname
          elif prev in varDefiners: fVariable
          elif call: fFnname
          elif not lang.lisp and e < line.len and line[e] == Rune('('): fFnname
          elif lang.capitalTypes and r.isUpper: fType
          else: fPlain
        if face == fPlain and lang.macroBang and e < line.len and line[e] == Rune('!'):
          face = fBuiltin
          inc e
        faces[n].paint(i, e, face)
        args = lang.lisp and prev in fnDefiners
        prev = if face == fKeyword: word else: ""
        call = false
        first = false
        i = e
        continue
      if lang.lisp and ch == '(':
        call = not args
        args = false
      else: call = false
      if not (ch == '-' and lang.keys != {}): first = false  # YAML '- key: value'
      prev = ""
      inc i

proc emphasis(line: seq[Rune], faces: var seq[Face], i: int, face: Face,
    failed: var seq[(Rune, int)]): int =
  ## Markdown *x*, **x**, _x_ and Org *x*, =x=, ~x~ from i; the end, or -1 if none.
  ## An opener that found no closer means later ones of the same run fail too: that keeps
  ## a line O(n) instead of rescanning to its end per opener.
  let ch = line[i]
  let n = runAt(line, i, ch)
  if i + n >= line.len or line[i+n].isSpace or (i > 0 and isWord(line[i-1])) or
      (ch, n) in failed: return -1
  var j = i + n + 1
  while j + n <= line.len:
    if runAt(line, j, ch) == n and not line[j-1].isSpace and
        (j + n == line.len or not isWord(line[j+n])):
      faces.paint(i, j + n, face)
      return j + n
    inc j
  failed.add (ch, n)
  -1

proc markdownLines(lines: seq[seq[Rune]], faces: var seq[seq[Face]]) =
  var fence = ""
  for n, line in lines:
    let ind = indent(line)
    if fence.len > 0:
      if runAt(line, ind, fence[0].Rune) >= fence.len:
        fence = ""
        faces[n].paint(0, line.len, fComment)
      else: faces[n].paint(0, line.len, fString)
      continue
    # ponytail: any indent, so fences nested in list items count.
    if matchAt(line, ind, "```") or matchAt(line, ind, "~~~"):
      fence = repeat(ascii(line[ind]), runAt(line, ind, line[ind]))
      faces[n].paint(0, line.len, fComment)
      continue
    if ind <= 3 and ind < line.len and line[ind] == Rune('#'):
      let hashes = runAt(line, ind, Rune('#'))
      if hashes <= 6 and (ind + hashes == line.len or line[ind+hashes].isSpace):
        faces[n].paint(0, line.len, fKeyword)
        continue
    if ind < line.len and line[ind] == Rune('>'):
      faces[n].paint(0, line.len, fComment)
      continue
    var i = 0
    var failed: seq[(Rune, int)]
    var noLink = 0  # a '[' before this has no '](…)' either: it would reach the same ']'
    while i < line.len:
      let ch = ascii(line[i])
      if ch == '`':
        let run = runAt(line, i, line[i])
        var j = i + run
        while j < line.len and runAt(line, j, line[i]) != run: inc j
        if j < line.len:
          faces[n].paint(i, j + run, fString)
          i = j + run
        else: i += run
      elif ch == '[' and i >= noLink:
        var j = i + 1
        while j < line.len and line[j] != Rune(']'): inc j
        if j + 1 < line.len and line[j+1] == Rune('('):
          var k = j + 2
          while k < line.len and line[k] != Rune(')'): inc k
          if k < line.len:
            faces[n].paint(i, j + 1, fVariable)
            faces[n].paint(j + 1, k + 1, fComment)
            i = k + 1
            continue
        noLink = j
        inc i
      elif ch in {'*', '_'}:
        let e = emphasis(line, faces[n], i, fConstant, failed)
        i = if e > 0: e else: i + runAt(line, i, line[i])
      else: inc i

proc orgLines(lines: seq[seq[Rune]], faces: var seq[seq[Face]]) =
  var ending = ""  # '#+end_src' or '#+end_example' closes the open block
  for n, line in lines:
    let ind = indent(line)
    if ending.len > 0:
      if matchAt(line, ind, ending, nocase = true):
        ending = ""
        faces[n].paint(0, line.len, fComment)
      else: faces[n].paint(0, line.len, fString)
      continue
    for kind in ["src", "example"]:
      if matchAt(line, ind, "#+begin_" & kind, nocase = true): ending = "#+end_" & kind
    if ending.len > 0:
      faces[n].paint(0, line.len, fComment)
      continue
    if matchAt(line, ind, "#+") or (matchAt(line, ind, "#") and
        (ind + 1 == line.len or line[ind+1].isSpace)):
      faces[n].paint(0, line.len, fComment)
      continue
    let stars = runAt(line, 0, Rune('*'))
    if stars > 0 and stars < line.len and line[stars] == Rune(' '):
      faces[n].paint(0, line.len, fKeyword)
      let a = stars + 1
      var z = a
      while z < line.len and isWord(line[z]): inc z
      if $line[a..<z] in ["TODO", "DONE"]: faces[n].paint(a, z, fConstant)
      continue
    var i = 0
    var failed: seq[(Rune, int)]
    var noLink = false  # no ']]' left on the line
    while i < line.len:
      let ch = ascii(line[i])
      if not noLink and matchAt(line, i, "[["):
        var j = i + 2
        while j < line.len and not matchAt(line, j, "]]"): inc j
        if j < line.len:
          faces[n].paint(i, j + 2, fVariable)
          i = j + 2
        else:
          noLink = true
          i += 2
      elif ch in {'=', '~', '*'}:
        let e = emphasis(line, faces[n], i, if ch == '*': fConstant else: fString, failed)
        i = if e > 0: e else: i + 1
      else: inc i

proc highlight*(lang: Lang, lines: seq[seq[Rune]]): seq[seq[Face]] =
  result = newSeq[seq[Face]](lines.len)
  for n, line in lines: result[n] = newSeq[Face](line.len)
  case lang.special
  of spText: discard
  of spCode: code(lang, lines, result)
  of spMarkdown: markdownLines(lines, result)
  of spOrg: orgLines(lines, result)

const brackets = "()[]{}（）「」『』【】".toRunes  # opening at even indexes, its closing next

proc matchParen*(lines: seq[seq[Rune]], faces: openArray[seq[Face]],
                 line, col: int): seq[tuple[line, col: int]] =
  ## Like show-paren-mode: the opening bracket at (line, col), else the closing one
  ## just before it, followed by its partner. Empty without a bracket or a partner.
  template quoted(l, c: int): bool =
    l < faces.len and c < faces[l].len and faces[l][c] in {fString, fComment}
  if line notin 0..lines.high: return
  var c = col
  var k = if c in 0..lines[line].high: brackets.find(lines[line][c]) else: -1
  if k < 0 or k mod 2 == 1:
    c = col - 1
    k = if c in 0..lines[line].high: brackets.find(lines[line][c]) else: -1
    if k < 0 or k mod 2 == 0: return
  let dir = if k mod 2 == 0: 1 else: -1
  let inQuote = quoted(line, c)
  var depth = 0
  var l = line
  var i = c
  # ponytail: counts one bracket kind like vim's %, so "( [ ) ]" still pairs, and rescans
  # up to 5000 lines per redraw; use a stack / cache on b.version if either one hurts
  while l in 0..lines.high and abs(l - line) <= 5000:
    while i in 0..lines[l].high:
      let r = lines[l][i]
      # brackets inside strings and comments only pair with each other
      if (r == brackets[k] or r == brackets[k + dir]) and quoted(l, i) == inQuote:
        depth += (if r == brackets[k]: 1 else: -1)
        if depth == 0:
          result.add (line, c)
          result.add (l, i)
          return
      i += dir
    l += dir
    if l in 0..lines.high: i = if dir > 0: 0 else: lines[l].high
