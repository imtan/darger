## Per-buffer centred writing, with optional automatic activation by language.
import std/[sets, tables]
import ../[core, buffer, lisp, syntax, olivetti]

var enabled: HashSet[Buffer]

proc bodyWidth(): int =
  if "olivetti-body-width" notin interp.env.values: return 100
  max(1, interp.env.values["olivetti-body-width"].asNumber.int)

marginProviders.add proc(buf: Buffer, paneWidth: int): int =
  if buf in enabled: olivettiMargin(paneWidth, gutterFor(buf), bodyWidth()) else: 0

interp.defPrimitive("olivetti-mode", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if b in enabled:
    enabled.excl b
    echoLine = "Olivetti off"
  else:
    enabled.incl b
    echoLine = "Olivetti on (body " & $bodyWidth() & ")"
  nilValue())

visitHooks.add proc() =
  if "olivetti-languages" notin interp.env.values: return
  let languages = interp.env.values["olivetti-languages"]
  if languages.kind == vNil: return
  for language in languages.asList:
    if language.asString == langOf(b).name:
      enabled.incl b
      break

killHooks.add proc(buf: Buffer) = enabled.excl buf

defaults.add """
(setq olivetti-body-width 100)
(setq olivetti-languages nil)
"""
