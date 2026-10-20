## Ask the agent where something is and get the answer as places to jump to, like
## consult-ripgrep: `agent-locate` sends a question about the project and lists the
## `path:line: note` places the agent names, with a preview; `agent-references`
## lists the places the current buffer (an agent transcript) refers to.
import std/[os, strutils, sequtils, tables]
import ../[core, buffer, lisp, chat, grep, lsp]
import agent, places

var locateRoot: string

proc showPlaces(hits: seq[Hit], what: string) =
  ## The agent's answer as a *places* list (grep-mode style): a cookie naming the
  ## root, the question, then the places with their notes.
  if hits.len == 0:
    echoLine = "No places found for " & what
    return
  var text = "-*- mode: grep; default-directory: \"" & locateRoot & "/\" -*-\n" & what & "\n\n"
  for h in hits: text.add hitRow(h, locateRoot) & "\n"
  openPlacesText(text, locateRoot, what)

proc showAnswer(answer, what: string) =
  ## The whole answer kept (headings and notes between the places), as a *places* list.
  let hits = parsePlaces(answer, locateRoot)
  if hits.len == 0:
    echoLine = "No places found for " & what
    return
  openPlacesText("-*- mode: grep; default-directory: \"" & locateRoot & "/\" -*-\n" & what & "\n\n" & answer, locateRoot, what)

proc locate(question: string) =
  let command = interp.env.values["agent-command"].asString
  if strutils.strip(command).len == 0: raise newException(ValueError, "agent-command is empty")
  locateRoot = currentRoot()
  onAgentResult = proc(text: string) = showAnswer(text, question)
  launchAgent(command,
    "You are helping someone find their way around the project at " & locateRoot & ". " &
    "Answer the question as a trail through the project files, like an Emacs grep buffer: " &
    "lines of the form `path:line: short note` (path relative to the project root, line 1-based), " &
    "in reading order, grouped under headings written as `== 1. Heading` when that helps, at most 40 places. " &
    "No other prose, no code fences.\n" &
    "Question: " & question & "\n", locateRoot)
  echoLine = "Agent: locating..."

definePrompt(Prompt(kind: "agent-locate", text: true, onAccept: proc(value: string): bool =
  if strutils.strip(value).len == 0: return false
  try: locate(value)
  except CatchableError as e: echoLine = e.msg
  true))

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
