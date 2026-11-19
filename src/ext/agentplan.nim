## Editable plans use the project's chat session; approval is an explicit command.
import std/[os, times, tables, strutils, unicode, sequtils]
import ../[core, buffer, buffers, lisp, agentplan]
import agent, reviewcomments

type Plan = ref object
  root, sessionId, title, path, anchorPath: string
  buf: Buffer
  origin: Buffer
  pending: bool

var plans: Table[Buffer, Plan]
var requestRoot: string
var requestOrigin: Buffer

proc persist(plan: Plan) =
  if plan.path.len == 0: return
  createDir(parentDir(plan.path))
  writeFile(plan.path, plan.buf.text)
  plan.buf.modified = false

proc startPlan*(request: string) =
  if strutils.strip(request).len == 0: return
  let root = requestRoot
  for plan in plans.values:
    if plan.root == root and plan.pending:
      raise newException(ValueError, "Approve or discard this project's existing plan first")
  let session = chats.getOrDefault(root)
  let resumed = session != nil and session.started
  let variable = if resumed: "agent-chat-resume-command" else: "agent-chat-command"
  let configured = interp.env.values.getOrDefault("agent-plan-command")
  let override = if configured != nil and configured.kind != vNil: configured.asString else: ""
  let command = planCommand(interp.env.values[variable].asString, override, resumed)
  if strutils.strip(command).len == 0: raise newException(ValueError, "Agent plan command is empty")
  let plan = Plan(root: root, title: planTitle(request), origin: requestOrigin, pending: true)
  let setting = interp.env.values.getOrDefault("agent-plan-directory")
  let stamp = now().format("yyyyMMdd-HHmmss-fff")
  plan.anchorPath = ".darger/plans/" & stamp & "-" & plan.title & ".md"
  if setting != nil and setting.kind != vNil:
    let directory = expandTilde(setting.asString)
    if directory.len > 0:
      plan.path = (if directory.isAbsolute: directory else: root / directory) / (stamp & "-" & plan.title & ".md")
      plan.anchorPath = relativePath(plan.path, root).replace('\\', '/')
  chatRoot = root
  sendChat(planningPrompt(request), command, proc(completed: ChatSession, text: string, ok: bool) =
    if not ok or strutils.strip(text).len == 0:
      echoLine = "Agent plan failed or cancelled; no plan to approve"
      return
    plan.sessionId = completed.id
    plan.buf = newBuffer(text)
    reg.add(plan.buf, "*agent-plan*")
    plans[plan.buf] = plan
    bindCommentKeys(plan.buf, send = false, delete = false)
    setLocalKey(plan.buf, "C-c C-c", symbol("agent-plan-approve"))
    setLocalKey(plan.buf, "C-c C-k", symbol("agent-plan-discard"))
    switchTo(plan.buf)
    persist(plan)
    echoLine = "Edit the plan; c comments, C-c C-c approves, C-c C-k discards")

definePrompt(Prompt(kind: "agent-plan", text: true, onAccept: proc(value: string): bool =
  startPlan(value)
  true))
interp.defPrimitive("agent-plan", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  if agentProcess != nil: raise newException(ValueError, "Agent already running")
  requestRoot = commentRoot()
  requestOrigin = b
  beginMini("agent-plan", "Plan: ")
  nilValue())

proc currentPlan(): Plan =
  result = plans.getOrDefault(b)
  if result == nil or not result.pending:
    raise newException(ValueError, "No pending plan in this buffer")

interp.defPrimitive("agent-plan-approve", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let plan = currentPlan()
  if agentProcess != nil: raise newException(ValueError, "Agent already running")
  let session = chats.getOrDefault(plan.root)
  if session == nil or session.id != plan.sessionId or not session.started:
    raise newException(ValueError, "Plan session changed; request a new plan")
  if strutils.strip(plan.buf.text).len == 0: raise newException(ValueError, "Plan is empty")
  loadComments()
  let sent = comments.filterIt(it.root == plan.root and it.anchor.path == plan.anchorPath)
  persist(plan)
  chatRoot = plan.root
  sendChat(approvalPrompt(plan.buf.text, commentPrompt(sent, plan.root, ending = false)),
    implementationCommand(interp.env.values["agent-chat-resume-command"].asString),
    proc(completed: ChatSession, text: string, ok: bool) =
      if ok: saveComments(comments.withoutSent(sent))
      elif plan.buf in plans: plan.pending = true)
  plan.pending = false
  nilValue())

interp.defPrimitive("agent-plan-discard", proc(args: seq[Value]): Value =
  args.arity(0, 0)
  let plan = currentPlan()
  loadComments()
  let discarded = comments.filterIt(it.root == plan.root and it.anchor.path == plan.anchorPath)
  saveComments(comments.withoutSent(discarded))
  plan.pending = false
  plan.buf.modified = false
  if plan.origin in reg: switchTo(plan.origin)
  echoLine = "Plan discarded (saved Markdown retained)"
  nilValue())

# A feedback batch must not accidentally implement a plan that is still awaiting approval.
commentSendChecks.add proc(root: string) =
  for plan in plans.values:
    if plan.root == root and plan.pending:
      raise newException(ValueError, "Approve or discard the pending plan before sending review comments")

commentProviders.add proc(buf: Buffer): CommentView =
  let plan = plans.getOrDefault(buf)
  if plan == nil: return
  result.root = plan.root
  for i, line in buf.lines:
    result.anchors.add CommentAnchor(path: plan.anchorPath, line: i + 1,
      content: $line, excerpt: $line)
langHints.add proc(buf: Buffer): string = (if buf in plans: "plan.md" else: "")
killHooks.add proc(buf: Buffer) = plans.del(buf)

defaults.add """
(setq agent-plan-command nil)
(setq agent-plan-directory ".darger/plans")
"""
