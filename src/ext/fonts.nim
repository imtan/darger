## Catalog font installation and deferred consent for missing novel fonts.
import std/[os, sets, strutils, tables]
import ../[core, lisp, render, fontcatalog, fontinstall]
import web

var
  running: FontInstall
  asked: HashSet[string]
  pending: seq[CatalogFont]
  question: CatalogFont
  checkedFallbacks, hintedIcons, cancelledQuestion: bool
  fontInstalledHooks*: seq[proc(font: CatalogFont)]

proc fontInstallDir*(): string =
  let v = interp.env.values.getOrDefault("font-install-dir")
  installDir((if v != nil and v.kind == vString: v.str else: ""), getHomeDir())

proc fontSearchDirs*(): seq[string] =
  @[fontInstallDir()] & fontDirs(getHomeDir(), getEnv("LOCALAPPDATA"))

proc ensureFallbackFonts*() =
  if renderer == nil: return
  for font in catalog:
    if font.fallback.len > 0:
      let path = fontInstallDir() / font.fallback
      if fileExists(path):
        try: renderer.addFallbackFont(path)
        except CatchableError as e: echoLine = "Font fallback: " & e.msg

proc iconFontHint*() =
  if hintedIcons: return
  hintedIcons = true
  echoLine = "Tree icons need a Nerd Font: M-x font-install RET nerd-symbols"

proc fontHint*(fileName: string): string =
  let font = catalogForFile(fileName)
  if font.name.len > 0: "; M-x font-install RET " & font.name & ", or see " & font.homepage else: ""

proc fontMissing*(fileName: string) =
  let font = catalogForFile(fileName)
  if font.name.len == 0 or font.name in asked: return
  asked.incl font.name
  let v = interp.env.values.getOrDefault("font-auto-install")
  if v != nil and v.kind == vNil: return
  pending.add font

proc install(name: string) =
  if running != nil:
    echoLine = "Already installing " & running.font.title
    return
  let font = lookup(name)
  if font.name.len == 0:
    echoLine = "Unknown font: " & name
    return
  try:
    running = startInstall(font, fontInstallDir(), fetchCommand())
    if running.done:
      echoLine = "Font install failed: " & running.error & "; nothing installed"
      running = nil
    else: echoLine = "Downloading " & font.title & " (" & font.size & ") from " & font.fontHost & "..."
  except CatchableError as e: echoLine = "Font install failed: " & e.msg & "; nothing installed"

proc later() = echoLine = "M-x font-install RET " & question.name & " to get it later"

interp.defPrimitive("font-install", proc(args: seq[Value]): Value =
  args.arity(0, 1)
  if running != nil: echoLine = "Already installing " & running.font.title
  elif args.len > 0: install(args[0].asString)
  else: beginMini("font-install", "Install font: ")
  nilValue())

proc fontRows(): seq[string] =
  let dirs = fontSearchDirs()
  for font in catalog:
    var installed = true
    for name in font.fontFiles:
      if findFont(name, dirs).len == 0: installed = false
    result.add font.candidateRow(installed)

definePrompt(Prompt(kind: "font-install", text: false, candidates: fontRows,
  onAccept: proc(value: string): bool =
    install(catalogName(value))
    true))
definePrompt(Prompt(kind: "font-install-yn", onCancel: proc() = (cancelledQuestion = true), onAccept: proc(value: string): bool =
  if value.toLowerAscii == "n": later()
  yesNo(value, proc() = install(question.name))))

tickHooks.add proc(): bool =
  if not checkedFallbacks:
    checkedFallbacks = true
    ensureFallbackFonts()
    result = true
  if running != nil and running.step():
    let i = running
    running = nil
    if i.error.len > 0: echoLine = "Font install failed: " & i.error & "; nothing installed"
    else:
      echoLine = "Installed " & i.font.title & " in " & i.dir & " (" & i.font.license & ")"
      if i.font.fallback.len > 0:
        try: renderer.addFallbackFont(i.dir / i.font.fallback)
        except CatchableError as e: echoLine = "Font fallback: " & e.msg
      for hook in fontInstalledHooks: hook(i.font)
    return true
  if pending.len > 0 and mode.len == 0 and running == nil:
    question = pending[0]
    pending.delete(0)
    let v = interp.env.values.getOrDefault("font-auto-install")
    if v != nil and v.kind == vTrue: install(question.name)
    elif v == nil or v.kind != vNil: beginMini("font-install-yn", question.consentQuestion)
    result = true

cancelHooks.add proc() =
  if cancelledQuestion:
    cancelledQuestion = false
    later()
  if running != nil:
    running.cancel()
    running = nil
    echoLine = "Font install cancelled; nothing installed"

busyHooks.add proc(): bool = running != nil
exitHooks.add proc() =
  if running != nil: running.cancel()
defaults.add """
(setq font-install-dir "~/.darger-fonts/")
(setq font-auto-install 'ask)
"""
