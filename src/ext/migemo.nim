## Migemo for isearch and the completion prompts: a romaji query also finds the
## Japanese it spells (kana, and the SKK dictionary's words read that way). On by
## default as the user's Emacs has it; M-x migemo-mode toggles it. The dictionary is
## the SKK one, loaded on first use.
import std/[tables]
import ../[core, lisp, skk, migemo, complete]

var
  index: MigemoIndex
  indexed = false

proc ready(): bool =
  if interp.env.values["migemo-mode"].kind == vNil: return false
  if not indexed:
    if not inputMethod.loaded:
      let msg = inputMethod.loadDefaults()
      if inputMethod.dictionary.len == 0:
        echoLine = msg
    index = buildIndex(inputMethod.dictionary)
    indexed = true
  true

proc alternatives(query: string): seq[string] =
  ## Everything but the query itself, which the caller already has.
  if not isRomaji(query) or not ready(): return
  expand(query, index)[1..^1]

searchExpanders.add alternatives
expander = proc(term: string): seq[string] = alternatives(term)

interp.defPrimitive("migemo-mode", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let on = interp.env.values["migemo-mode"].kind == vNil
  interp.env.values["migemo-mode"] = if on: Value(kind: vSymbol, str: "t") else: nilValue()
  echoLine = if on: "Migemo on: romaji finds Japanese" else: "Migemo off"
  nilValue())

defaults.add """
(setq migemo-mode t)
"""
