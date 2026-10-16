import std/[tables, sequtils]
import ../src/[migemo, skk]

doAssert romajiToHiragana("kensaku") == ("けんさく", "") and romajiToHiragana("kens") == ("けん", "s")
doAssert romajiToHiragana("shinbun") == ("しんぶん", "") and romajiToHiragana("kitte") == ("きって", "")
doAssert toKatakana("けんさく") == "ケンサク"

var dict: Dictionary
dict["けんさく"] = @["検索", "研削;annotation"]
dict["けんさ"] = @["検査"]
dict["かな"] = @["仮名"]
dict["おくr"] = @["送"]       # okuri-ari: not a reading to match
dict["/abbr"] = @["略"]
let index = buildIndex(dict)
doAssert wordsFor(index, "けんさ") == @["検査", "検索", "研削"]   # prefix, annotations stripped
doAssert wordsFor(index, "けんさく") == @["検索", "研削"]
doAssert wordsFor(index, "ぬ") == @[] and wordsFor(index, "") == @[]
doAssert expand("kensa", index) == @["kensa", "けんさ", "ケンサ", "検査", "検索", "研削"]
doAssert expand("kens", index) == @["kens", "けん", "ケン", "検査", "検索", "研削"]  # pending s dropped, けん… words
doAssert expand("Kensa", index) == @["Kensa"] and expand("検索", index) == @["検索"]  # not romaji
doAssert expand("", index) == @[""]
doAssert not isRomaji("foo bar") and isRomaji("ka-do")
echo "migemo ok"
