## Minibuffer completion: orderless-style matching and file-name candidates.
import std/[os, strutils, unicode, algorithm]

import remote

var remoteList*: proc(dir: string): seq[string]

proc lower(s: string): string = unicode.toLower(s)

type Expander* = proc(term: string): seq[string]
  ## Other strings a term may stand for (migemo: the Japanese a romaji term spells)

var expander*: Expander  ## nil: terms match as typed

proc matches*(query, candidate: string): bool =
  ## Every space-separated term of query occurs in candidate, in any order, ignoring
  ## case; a term also counts when one of the strings the expander gives for it does.
  let hay = lower(candidate)
  for term in strutils.splitWhitespace(query):
    if lower(term) in hay: continue
    var found = false
    if expander != nil:
      for alt in expander(term):
        if lower(alt) in hay:
          found = true
          break
    if not found: return false
  true

proc filter*(query: string, all: openArray[string]): seq[string] =
  ## Matching candidates in source order, those starting with the first term first;
  ## one equal to the whole query goes before them, so Enter picks "foo" over "foo.txt".
  let terms = strutils.splitWhitespace(query)
  let first = if terms.len > 0: lower(terms[0]) else: ""
  var rest: seq[string]
  for c in all:
    if not matches(query, c): continue
    if lower(c).startsWith(first): result.add c else: rest.add c
  result.add rest
  let whole = lower(strutils.strip(query))
  for i, c in result:
    if lower(c) == whole:
      result.delete(i)
      result.insert(c, 0)
      break

proc splitInput*(input: string): tuple[dir, tail: string] =
  ## dir: input up to its last separator with ~ expanded except on Windows, like
  ## confirmMini (the current dir when there is none); tail: the rest, completed against.
  var cut = input.rfind('/')
  when DirSep != '/': cut = max(cut, input.rfind(DirSep))
  if cut < 0: (getCurrentDir() & DirSep, input)
  elif defined(windows): (input[0..cut], input[cut+1..^1])
  else: (expandTilde(input[0..cut]), input[cut+1..^1])

proc listDir*(dir: string, hidden = false): seq[string] =
  ## Entry names of dir sorted case-insensitively, directories with a trailing "/";
  ## dot-files only when hidden. An unreadable dir has none.
  try:
    if isRemote(dir):
      if remoteList != nil:
        for name in remoteList(dir):
          if hidden or not name.startsWith("."): result.add name
    else:
      for kind, path in walkDir(dir, relative = true):
        if path.startsWith(".") and not hidden: continue
        result.add(if kind in {pcDir, pcLinkToDir}: path & "/" else: path)
  except OSError: return @[]
  result.sort(proc(a, b: string): int = cmp(lower(a), lower(b)))
