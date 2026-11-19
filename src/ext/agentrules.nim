## M-x agent-rules and agent-remember: inspect the rule chain and review one appended memory.
import std/[os, unicode]
import ../[core, buffer, buffers, lisp, agentrules, remote]
import agent

var
  rulesBuf: Buffer
  rulesRoot, rememberRoot, rememberText: string
  rules: seq[RuleFile]
  destinations: seq[string]

proc rebuildRules() =
  rules = collectRules(rulesRoot, getHomeDir())
  var text = "Agent rules — " & rulePathLabel(rulesRoot) & "\n" &
    "user → ancestors → project; local overrides last in each directory\n" &
    "Discovery order; each client decides applicability (Cursor rules may be conditional).\n" &
    "Enter: open  M-,: return  g: refresh  q: close\n\n"
  for row in rules: text.add ruleLabel(row) & "\n"
  if rules.len == 0: text.add "No rule files found.\n"
  let line = rulesBuf.cursor.line
  rulesBuf.splice(0, rulesBuf.text.runeLen, text)
  rulesBuf.modified = false
  rulesBuf.cursor = (clamp(line, 0, rulesBuf.lines.high), 0)

proc openAgentRules*() =
  let root = if b == rulesBuf and rulesBuf != nil: rulesRoot else: currentChatRoot()
  if isRemote(root):
    echoLine = "agent-rules requires a local project"
    return
  rulesRoot = root
  if rulesBuf == nil or rulesBuf notin reg:
    rulesBuf = newBuffer()
    reg.add(rulesBuf, "*agent-rules*")
    setReadOnly(rulesBuf, true)
    for key in ["enter", "C-m", "C-j", "g", "q"]:
      setLocalKey(rulesBuf, key,
        interp.evalString("(lambda () (agent-rules-key \"" & key & "\"))", "<agent-rules>"))
  rebuildRules()
  switchTo(rulesBuf)

proc rulesKey(key: string) =
  if rulesBuf == nil or b != rulesBuf: return
  case key
  of "g": rebuildRules()
  of "q": discard interp.evalString("(previous-buffer)", "<agent-rules>")
  of "enter", "C-m", "C-j":
    let row = b.cursor.line - 5
    if row notin 0..<rules.len: return
    let point = b.cursor
    let top = renderer.top
    let left = renderer.left
    visit(rules[row].path)
    pushXref(rulesBuf, point, top, left)
  else: discard

proc reviewMemory*(path, text: string) =
  if reviewOpen(): raise newException(ValueError, "Finish the current review first")
  if isRemote(path): raise newException(ValueError, "agent-remember requires a local file")
  let targetPath = normalizedPath(absolutePath(expandTilde(path)))
  if not dirExists(parentDir(targetPath)):
    raise newException(ValueError, "Destination directory does not exist")
  let opened = reg.byPath(targetPath)
  if opened != nil and opened.isReadOnly:
    raise newException(ValueError, "Destination buffer is read-only")
  if dirExists(targetPath): raise newException(ValueError, "Destination is a directory")
  let existed = fileExists(targetPath)
  let originalBytes = if opened == nil and existed: readFile(targetPath) else: ""
  let target = if opened != nil: opened else: bufferFromBytes(originalBytes, targetPath)
  let original = target.text
  let addition = memoryAppend(original, text)
  let origin = b
  # Review only the addition, including a missing final newline. The destination
  # is untouched until accepted decisions are applied when this review closes.
  let draft = newBuffer()
  reg.add(draft, "*agent memory: " & extractFilename(targetPath) & "*")
  switchTo(draft)
  afterReview = proc() =
    let accepted = draft.text
    if draft in reg: killBuffer(draft)
    if origin in reg: switchTo(origin)
    if accepted.len == 0: return
    if opened != nil and (opened notin reg or opened.isReadOnly or opened.text != original):
      echoLine = "Memory not applied: destination buffer changed; run agent-remember again"
      return
    # A file opened during the review must receive the change as a buffer edit too.
    let nowOpen = reg.byPath(targetPath)
    if opened == nil:
      if fileExists(targetPath) != existed or (existed and readFile(targetPath) != originalBytes) or
          (nowOpen != nil and (nowOpen.isReadOnly or nowOpen.text != original)):
        echoLine = "Memory not applied: destination changed; run agent-remember again"
        return
    let dest = if nowOpen != nil: nowOpen else: target
    dest.snapshot()
    let ending = dest.text.runeLen
    dest.splice(ending, ending, accepted)
    dest.finish()
    if nowOpen == nil:
      try: dest.save()
      except CatchableError:
        switchTo(dest)  # keep the accepted text available if saving failed
        raise
    echoLine = "Memory appended to " & targetPath & (if nowOpen != nil: " (buffer; save when ready)" else: "")
  beginReview(addition, "Remember → " & targetPath)

definePrompt(Prompt(kind: "agent-memory-file", text: true,
  candidates: proc(): seq[string] = destinations,
  onAccept: proc(value: string): bool =
    let path = if value.len == 0: defaultMemoryPath(rememberRoot) else: expandTilde(value)
    reviewMemory(if path.isAbsolute: path else: rememberRoot / path, rememberText)
    true))
definePrompt(Prompt(kind: "agent-memory-text", text: true,
  onAccept: proc(value: string): bool =
    discard memoryAppend("", value)
    rememberText = value
    destinations = @[defaultMemoryPath(rememberRoot)]
    for row in collectRules(rememberRoot, getHomeDir()):
      if row.path notin destinations: destinations.add row.path
    beginMini("agent-memory-file", "Remember in: ", destinations[0])
    true))

interp.defPrimitive("agent-rules-key", proc(args: seq[Value]): Value =
  args.arity(1, 1)
  rulesKey(args[0].asString)
  nilValue())
interp.defPrimitive("agent-rules", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  openAgentRules()
  nilValue())
interp.defPrimitive("agent-remember", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if reviewOpen(): raise newException(ValueError, "Finish the current review first")
  rememberRoot = if b == rulesBuf and rulesBuf != nil: rulesRoot else: currentChatRoot()
  if isRemote(rememberRoot): raise newException(ValueError, "agent-remember requires a local project")
  beginMini("agent-memory-text", "Remember: ")
  nilValue())

modeNameProviders.add proc(buf: Buffer): string =
  if buf == rulesBuf and rulesBuf != nil: "Agent rules" else: ""
killHooks.add proc(buf: Buffer) =
  if buf == rulesBuf:
    rulesBuf = nil
    rules = @[]
