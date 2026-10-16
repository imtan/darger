## Migemo: a romaji query also matches the Japanese it spells, in isearch and the
## completion prompts. Without cmigemo, the SKK romaji rules give the kana and the
## SKK dictionary (already there for input) gives the words read that way, as
## migemo's dictionary would.
import std/[algorithm, strutils, tables]
import skk

type MigemoIndex* = object
  keys: seq[string]        ## the dictionary's okuri-nasi readings, sorted
  dict: Dictionary

const maxWords* = 200

proc buildIndex*(dict: Dictionary): MigemoIndex =
  result.dict = dict
  for key in dict.keys:
    var plain = true
    for c in key:
      if c.ord < 0x80: plain = false  # okuri-ari keys end in a letter; abbrev keys are ASCII
    if plain: result.keys.add key
  result.keys.sort()

proc wordsFor*(index: MigemoIndex, reading: string): seq[string] =
  ## Dictionary words whose reading starts with `reading`, in key order, at most maxWords.
  if reading.len == 0: return
  var i = index.keys.lowerBound(reading)
  while i < index.keys.len and index.keys[i].startsWith(reading) and result.len < maxWords:
    for c in index.dict[index.keys[i]]:
      let w = candidateText(c)
      if w.len > 0 and w notin result: result.add w
    inc i

proc isRomaji*(query: string): bool =
  query.len > 0 and query.allCharsInSet({'a'..'z', '-'})

proc expand*(query: string, index: MigemoIndex): seq[string] =
  ## The query and what it may mean in Japanese: the hiragana and katakana it spells
  ## (with any trailing consonant dropped, so "kens" still matches けん), and the
  ## dictionary words read that way. A query that is not romaji is left alone.
  result = @[query]
  if not isRomaji(query): return
  let (kana, _) = romajiToHiragana(query)
  if kana.len == 0: return
  result.add kana
  result.add toKatakana(kana)
  for w in wordsFor(index, kana):
    if w notin result: result.add w
