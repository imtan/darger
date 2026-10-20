## Ask the agent where something is and get the answer as places to jump to, like
## consult-ripgrep: `agent-locate` sends a question about the project and lists the
## `path:line: note` places the agent names, with a preview; `agent-references`
## lists the places the current buffer (an agent transcript) refers to.
import std/[os, strutils, sequtils, tables]
import ../[core, buffer, lisp, chat, grep, lsp]
import agent

var locateRoot: string

proc showPlaces(hits: seq[Hit], what: string) =
  if hits.len == 0:
    echoLine = "No places found for " & what
    return
  targets = @[]
  refRows = @[]
  for h in hits:
    targets.add Location(path: h.path, line: h.line, col: h.col)
    refRows.add hitRow(h, locateRoot)
  beginMini("agent-places", "Place: ")

proc locate(question: string) =
  let command = interp.env.values["agent-command"].asString
  if strutils.strip(command).len == 0: raise newException(ValueError, "agent-command is empty")
  locateRoot = currentRoot()
  onAgentResult = proc(text: string) =
    showPlaces(parsePlaces(text, locateRoot), question)
  launchAgent(command,
    "You are helping someone find their way around the project at " & locateRoot & ". " &
    "Answer the question by listing the places in the project files that matter for it. " &
    "Output ONLY lines of the form `path:line: short note` (path relative to the project root, " &
    "line 1-based), most relevant first, at most 30 lines. No other text, no code fences.\n" &
    "Question: " & question & "\n", locateRoot)
  echoLine = "Agent: locating..."

definePrompt(Prompt(kind: "agent-locate", text: true, onAccept: proc(value: string): bool =
  if strutils.strip(value).len == 0: return false
  try: locate(value)
  except CatchableError as e: echoLine = e.msg
  true))
definePrompt(Prompt(kind: "agent-places", text: true, consult: true, candidates: refRowsNow, onAccept: acceptReference))

interp.defPrimitive("agent-locate", proc(args: seq[Value]): Value =
  ## C-c l: a question for the agent; its answer opens as places with a preview.
  args.arity(0, 1)
  if args.len == 1: locate(args[0].asString)
  else: beginMini("agent-locate", "Ask where (" & extractFilename(currentRoot()) & "): ")
  nilValue())
interp.defPrimitive("agent-references", proc(args: seq[Value]): Value =
  ## The `path:line` places the current buffer mentions (an agent transcript), as a list.
  args.arity(0, 0)
  locateRoot = currentRoot()
  showPlaces(findReferences(b.text, locateRoot), "this buffer")
  nilValue())

defaults.add """
(global-set-key "C-c l" 'agent-locate)
"""
