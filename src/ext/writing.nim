## Writing helpers share the one-shot agent and its hunk review.
import std/[strutils, tables]
import ../[core, buffer, buffers, lisp, writing]
import agent

proc writingReady(): bool =
  if agentProcess != nil:
    echoLine = "Agent already running"
  elif strutils.strip(interp.env.values["agent-command"].asString).len == 0:
    echoLine = "agent-command is empty"
  else: return true

proc showDraft(text: string) =
  let draft = newBuffer(text)
  reg.add(draft, "*agent draft*")
  let other = otherPaneFor()
  if other != nil and other != pane:
    other.buf = draft
    other.top = 0
    other.cursor = (0, 0)

proc startWriting(action: WritingAction, topic = "") =
  if not writingReady(): return
  let source = b
  let original = source.text
  let region = if source.regionActive and source.markSet: source.region else: (0, 0)
  let selection = writingSelection(original, source.regionActive, source.markSet,
    region, action == summarizeBuffer)
  let command = interp.env.values["agent-command"].asString
  let input = writingPrompt(action, selection.text, topic)
  let root = currentRoot()
  onAgentResult = proc(text: string) =
    if action in {draftNotes, draftInteractive}:
      showDraft(text)
    elif source.text != original:
      showDraft(text)
      echoLine = "Agent writing: source changed; result saved in *agent draft*"
    else:
      switchTo(source)
      beginReview(writingProposal(original, selection, text,
        action in {summarizeRegion, summarizeBuffer, extractKeywords, suggestTitle}), "Agent writing")
  try: launchAgent(command, input, root)
  except CatchableError as e:
    onAgentResult = nil
    echoLine = e.msg

definePrompt(Prompt(kind: "agent-draft-topic", text: true, onAccept: proc(value: string): bool =
  if strutils.strip(value).len == 0: return false
  startWriting(draftInteractive, value)
  true))

for (name, key, action) in [
    ("agent-translate-auto", "t t", translateAuto),
    ("agent-translate-to-japanese", "t j", translateJapanese),
    ("agent-translate-to-english", "t e", translateEnglish),
    ("agent-proofread", "p p", proofread),
    ("agent-proofread-en", "p e", proofreadEnglish),
    ("agent-rewrite-formal", "p f", rewriteFormal),
    ("agent-rewrite-casual", "p c", rewriteCasual),
    ("agent-summarize-region", "s r", summarizeRegion),
    ("agent-summarize-buffer", "s b", summarizeBuffer),
    ("agent-extract-keywords", "s k", extractKeywords),
    ("agent-suggest-title", "d t", suggestTitle),
    ("agent-draft-blog-from-notes", "d n", draftNotes),
    ("agent-draft-blog-interactive", "d d", draftInteractive)]:
  closureScope:
    let action = action
    interp.defPrimitive(name, proc(args: seq[Value]): Value =
      args.arity(0, 0)
      if action == draftInteractive:
        if writingReady(): beginMini("agent-draft-topic", "Blog topic: ")
      else: startWriting(action)
      nilValue())
  defaults.add "(global-set-key \"C-c G " & key & "\" '" & name & ")\n"

defaults.add """
(global-set-key "C-c G g" 'agent-chat)
"""
