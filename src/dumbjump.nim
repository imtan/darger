## Heuristic definitions, independent of editor state and filesystem searches.
## Tokens keep rune columns; syntax's lexer removes comments and strings first.
import std/[unicode, strutils, os, algorithm, tables]
import syntax, grep

type
  Pattern = object
    functions, types, variables: string
    assignment, typed: bool
  Token = object
    text: string
    line, col: int

const patterns = {
  "Nim": Pattern(functions: "proc func method iterator template macro converter",
    types: "type", variables: "var let const", typed: true),
  "Python": Pattern(functions: "def", types: "class", assignment: true, typed: true),
  "JS/TS": Pattern(functions: "function", types: "class type interface enum",
    variables: "const let var", typed: true),
  "C/C++": Pattern(types: "struct class enum union typedef using", typed: true),
  "Rust": Pattern(functions: "fn", types: "struct enum trait type mod",
    variables: "let const static", typed: true),
  "Go": Pattern(functions: "func", types: "type", variables: "var const"),
  "Shell": Pattern(functions: "function", variables: "local export readonly declare",
    assignment: true),
  "Lisp": Pattern(functions: "defun defmacro defsubst",
    variables: "defvar defconst defcustom defparameter setq setq-local"),
  "Ruby": Pattern(functions: "def", types: "class module", assignment: true)
}.toTable
const generic = Pattern(functions: "proc func def fn function method",
  types: "class type struct enum interface", variables: "var let const", assignment: true)

proc has(words, word: string): bool = word.len > 0 and word in strutils.splitWhitespace(words)

proc symbolRune(r: Rune, language: string): bool =
  r.isAlpha or int(r) >= 128 or int(r) in ord('0')..ord('9') or r == Rune('_') or
    (language == "Lisp" and $r in ["-", "+", "*", "/", "?", "!", "<", ">", "="]) or
    (language == "JS/TS" and r == Rune('$')) or
    (language == "Ruby" and $r in ["@", "$", "?", "!"])

proc symbolAt*(line: seq[Rune], col: int, language: string): string =
  var start = clamp(col, 0, line.len)
  if start == line.len or not symbolRune(line[start], language):
    if start == 0 or not symbolRune(line[start - 1], language): return
    dec start
  var stop = start
  while start > 0 and symbolRune(line[start - 1], language): dec start
  while stop < line.len and symbolRune(line[stop], language): inc stop
  $line[start..<stop]

proc identifier(t: Token, language: string): bool =
  let r = t.text.toRunes
  r.len > 0 and symbolRune(r[0], language) and not (int(r[0]) in ord('0')..ord('9'))

proc definitions*(lines: seq[seq[Rune]], language: Lang, name, path: string, all = false): seq[Hit] =
  if name.len == 0 and not all: return
  let pattern = patterns.getOrDefault(language.name, generic)
  # Unknown languages still get conventional comment/string exclusion.
  let lexer = if language.name in patterns: language else: detect("fallback.js", "")
  let faces = highlight(lexer, lines)
  var tokens: seq[Token]
  var starts = newSeq[int](lines.len + 1)
  for n, line in lines:
    starts[n] = tokens.len
    var col = 0
    while col < line.len:
      if faces[n][col] in {fComment, fString} or line[col].isWhiteSpace:
        inc col
        continue
      let start = col
      if symbolRune(line[col], language.name):
        inc col
        while col < line.len and faces[n][col] notin {fComment, fString} and
            symbolRune(line[col], language.name): inc col
      else: inc col
      tokens.add Token(text: $line[start..<col], line: n, col: start)
  starts[^1] = tokens.len
  var found: seq[int]
  proc word(i: int): string =
    if i >= 0 and i < tokens.len: tokens[i].text else: ""
  proc add(i: int) =
    if i >= 0 and i < tokens.len and ((all and tokens[i].identifier(language.name)) or
        word(i) == name) and i notin found: found.add i
  proc matching(open: int): int =
    var depth = 0
    for i in open..<tokens.len:
      if word(i) == "(": inc depth
      elif word(i) == ")":
        dec depth
        if depth == 0: return i
    -1
  proc bindings(first, stop: int) =
    # Names before the first type or initializer, including a, b: T / a, b = ... .
    var i = first
    while i < stop:
      if word(i) in ["mut", "ref", "*", "("]: inc i
      elif tokens[i].identifier(language.name):
        add(i)
        inc i
        if word(i) == "*": inc i # Nim export
        if word(i) != ",": break
        inc i
      else: break
  proc parameters(open: int) =
    let close = matching(open)
    if close < 0: return
    var first = open + 1
    var depth = 0
    for i in open + 1..close:
      let w = word(i)
      if depth == 0 and (i == close or w in [",", ";"]):
        if language.name == "C/C++":
          var last = -1
          for j in first..<i:
            if word(j) == "=": break
            if tokens[j].identifier(language.name): last = j
          if last > first: add(last)
        else:
          bindings(first, i)
        first = i + 1
      elif w in ["(", "[", "{"]: inc depth
      elif w in [")", "]", "}"]: dec depth

  var section = ""
  var sectionIndent = -1
  var objectIndent = -1
  for n in 0..<lines.len:
    let first = starts[n]
    let stop = starts[n + 1]
    if first == stop: continue
    let indent = tokens[first].col
    let head = word(first)
    if indent <= sectionIndent: section = ""
    if indent <= objectIndent: objectIndent = -1
    var lead = first
    while word(lead) in ["pub", "export", "default", "async", "static", "public",
        "private", "protected", "abstract", "declare", "readonly", "inline", "virtual"] and
        not pattern.variables.has(word(lead)):
      inc lead
      if word(lead) == "(" and language.name == "Rust":
        let close = matching(lead)
        if close < 0: break
        lead = close + 1
    if language.name == "Lisp" and head == "(": lead = first + 1
    if lead >= stop: continue
    let key = word(lead)
    if pattern.functions.has(key):
      var fn = lead + 1
      if word(fn) == "*": inc fn # JS generator
      if language.name == "Go" and word(fn) == "(":
        parameters(fn) # receiver
        let close = matching(fn)
        if close >= 0: fn = close + 1
      if language.name == "Ruby" and word(fn + 1) == ".": fn += 2
      add(fn)
      var p = fn + 1
      if word(p) == "*": inc p
      if word(p) == "[": # Nim generic parameters before the argument list
        while p < tokens.len and word(p) != "]": inc p
        inc p
      if word(p) == "(":
        if language.name == "Lisp":
          let close = matching(p)
          if close > p:
            for j in p + 1..<close: add(j)
        else: parameters(p)
    if pattern.types.has(key): add(lead + 1)
    if pattern.variables.has(key): bindings(lead + 1, stop)

    if language.name == "Nim":
      if head in ["var", "let", "const", "type"] and stop == first + 1:
        section = head
        sectionIndent = indent
      else:
        var declaration = false
        for i in first..<stop:
          if word(i) in [":", "="]: declaration = true
          if word(i) == "(": break
        if declaration and (section.len > 0 or objectIndent >= 0): bindings(first, stop)
      for i in first..<stop:
        if word(i) in ["object", "tuple"]: objectIndent = indent
    if head == "for" and language.name in ["Nim", "Python", "Rust", "Ruby", "Shell", "Go"]:
      bindings(first + 1, stop)

    # Assignments only count on the left; equality tests and attribute writes do not.
    if pattern.assignment and tokens[first].identifier(language.name) and
        word(first + 1) == "=" and word(first + 2) notin ["=", ">"]: add(first)
    if language.name == "Go":
      if head in ["var", "const", "type"] and word(first + 1) == "(":
        section = head
        sectionIndent = indent
      elif section.len > 0: bindings(first, stop)
      for i in first..<stop - 1:
        if word(i) == ":" and word(i + 1) == "=": bindings(first, i)

    if language.name == "JS/TS":
      for i in first..<stop:
        if word(i) == "function" and i != lead:
          var p = i + 1
          if word(p) == "*": inc p
          if word(p) != "(":
            add(p)
            inc p
          if word(p) == "(": parameters(p)
        elif word(i) == "(":
          let close = matching(i)
          if close >= 0 and word(close + 1) == "=" and word(close + 2) == ">": parameters(i)
        elif tokens[i].identifier(language.name) and word(i + 1) == "=" and word(i + 2) == ">":
          add(i)

    # Typed fields / annotations. Calls such as foo(name: value) do not qualify.
    if pattern.typed and language.name != "Nim" and tokens[lead].identifier(language.name):
      var after = lead + 1
      if word(after) in ["*", "?"]: inc after
      if word(after) == ":" and word(after + 1) notin ["=", ":"]: add(lead)
    if language.name in ["JS/TS", "Shell"] and tokens[lead].identifier(language.name) and
        key notin ["if", "while", "for", "switch", "catch", "with"] and word(lead + 1) == "(":
      let close = matching(lead + 1)
      if close >= 0 and word(close + 1) in ["{", ":"]:
        add(lead)
        parameters(lead + 1)
    if language.name == "C/C++" and key notin ["return", "throw", "delete", "new", "else"]:
      # A type followed by a declarator (possibly pointer/reference or qualified).
      var i = lead + 1
      while i < stop and (tokens[i].identifier(language.name) or word(i) in ["*", "&", ":", "<", ">"]):
        if tokens[i].identifier(language.name) and word(i + 1) in ["(", "=", ";", "[", ","]:
          add(i)
          if word(i + 1) == "(": parameters(i + 1)
        inc i
  for i in found:
    let t = tokens[i]
    result.add Hit(path: path, line: t.line, col: t.col, text: $lines[t.line])

proc rankDefinitions*(hits: seq[Hit], path: string, line, col: int, name: string): seq[Hit] =
  ## Same file first, nearest preceding declaration first; then directory and path.
  for h in hits:
    if h.path == path and h.line == line and col >= h.col and col <= h.col + name.runeLen: continue
    var duplicate = false
    for prev in result:
      if (prev.path, prev.line, prev.col) == (h.path, h.line, h.col): duplicate = true
    if not duplicate: result.add h
  proc priority(h: Hit): (int, int, int, string, int, int) =
    if h.path == path:
      let before = (h.line, h.col) < (line, col)
      (0, (if before: 0 else: 1), abs(h.line - line), h.path, h.line, h.col)
    else:
      ((if parentDir(h.path) == parentDir(path): 1 else: 2), 0, 0, h.path, h.line, h.col)
  result.sort(proc(a, b: Hit): int = cmp(priority(a), priority(b)))
