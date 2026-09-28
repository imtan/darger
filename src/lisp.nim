import std/[tables, strutils, unicode, math]

type
  ValueKind* = enum
    vNil, vTrue, vNumber, vString, vSymbol, vList, vLambda, vPrimitive
  Value* = ref object
    line*: int
    source: string
    case kind*: ValueKind
    of vNumber: number*: float
    of vString, vSymbol: str*: string
    of vList: items*: seq[Value]
    of vLambda:
      params: seq[string]
      body: seq[Value]
      env: Env
    of vPrimitive: primitive: proc(args: seq[Value]): Value {.closure.}
    else: discard
  Env* = ref object
    values*: Table[string, Value]
    parent*: Env
  Interp* = ref object
    env*: Env
  LispError* = object of CatchableError
    line*: int

proc fail(msg: string, line = 0) {.noreturn.} =
  let e = newException(LispError, msg)
  e.line = line
  raise e

proc nilValue*(): Value = Value(kind: vNil)
proc boolean(b: bool): Value = Value(kind: (if b: vTrue else: vNil))
proc num(n: float): Value = Value(kind: vNumber, number: n)
proc stringValue*(s: string): Value = Value(kind: vString, str: s)
proc symbol*(s: string): Value = Value(kind: vSymbol, str: s)
proc list(xs: seq[Value]): Value =
  if xs.len == 0: nilValue() else: Value(kind: vList, items: xs)
proc truth(v: Value): bool = v.kind != vNil

proc `$`*(v: Value): string =
  case v.kind
  of vNil: "nil"
  of vTrue: "t"
  of vNumber:
    let s = $v.number
    if s.endsWith(".0"): s[0..^3] else: s
  of vString: "\"" & v.str.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") & "\""
  of vSymbol: v.str
  of vList:
    var parts: seq[string]
    for x in v.items: parts.add $x
    "(" & parts.join(" ") & ")"
  of vLambda: "(lambda (" & v.params.join(" ") & ") ...)"
  of vPrimitive: "#<primitive>"

proc arity*(args: seq[Value], minimum: int, maximum = -1) =
  if args.len < minimum: fail("Not enough arguments")
  if maximum >= 0 and args.len > maximum: fail("Too many arguments")
proc asString*(v: Value): string =
  if v.kind != vString: fail("Expected string")
  v.str
proc asNumber(v: Value): float =
  if v.kind != vNumber: fail("Expected number")
  v.number
proc asList(v: Value): seq[Value] =
  if v.kind == vNil: return @[]
  if v.kind != vList: fail("Expected list")
  v.items
proc asSymbol(v: Value): string =
  if v.kind != vSymbol: fail("Expected symbol")
  v.str

type Reader = object
  src, source: string
  pos, line: int

proc skip(r: var Reader) =
  while r.pos < r.src.len:
    case r.src[r.pos]
    of ' ', '\t', '\r': inc r.pos
    of '\n': inc r.line; inc r.pos
    of ';':
      while r.pos < r.src.len and r.src[r.pos] != '\n': inc r.pos
    else: break

proc read(r: var Reader): Value =
  r.skip()
  let line = r.line
  if r.pos == r.src.len: fail("Unexpected end of input", line)
  let c = r.src[r.pos]
  inc r.pos
  case c
  of '(':
    var xs: seq[Value]
    r.skip()
    while r.pos < r.src.len and r.src[r.pos] != ')':
      xs.add r.read()
      r.skip()
    if r.pos == r.src.len: fail("Unclosed list", line)
    inc r.pos
    result = list(xs)
  of ')': fail("Unexpected )", line)
  of '\'': result = list(@[symbol("quote"), r.read()])
  of '"':
    var s = ""
    while r.pos < r.src.len and r.src[r.pos] != '"':
      var ch = r.src[r.pos]
      inc r.pos
      if ch == '\n': inc r.line
      if ch == '\\':
        if r.pos == r.src.len: fail("Unclosed string", line)
        ch = r.src[r.pos]
        inc r.pos
        case ch
        of 'n': ch = '\n'
        of '"', '\\': discard
        else: fail("Unknown string escape", r.line)
      s.add ch
    if r.pos == r.src.len: fail("Unclosed string", line)
    inc r.pos
    result = stringValue(s)
  else:
    let start = r.pos - 1
    while r.pos < r.src.len and r.src[r.pos] notin {' ', '\t', '\r', '\n', '(', ')', '\'', '"', ';'}: inc r.pos
    let token = r.src[start..<r.pos]
    case token
    of "nil": result = nilValue()
    of "t": result = boolean(true)
    else:
      try: result = num(parseFloat(token))
      except ValueError: result = symbol(token)
  result.line = line
  result.source = r.source

proc owner(env: Env, name: string): Env =
  var e = env
  while e != nil:
    if name in e.values: return e
    e = e.parent
proc lookup(env: Env, name: string, function = false): Value =
  let e = env.owner(name)
  if e == nil: fail((if function: "Undefined function: " else: "Undefined symbol: ") & name)
  e.values[name]

proc eval(i: Interp, v: Value, env: Env): Value
proc sequence(i: Interp, body: seq[Value], env: Env): Value =
  result = nilValue()
  for v in body: result = i.eval(v, env)

proc invoke(interp: Interp, fn: Value, args: seq[Value]): Value =
  let f = if fn.kind == vSymbol: interp.env.lookup(fn.str, true) else: fn
  case f.kind
  of vPrimitive: f.primitive(args)
  of vLambda:
    args.arity(f.params.len, f.params.len)
    let local = Env(parent: f.env)
    for n, name in f.params: local.values[name] = args[n]
    interp.sequence(f.body, local)
  else: fail("Not a function: " & $f)

proc call*(interp: Interp, fn: Value, args: seq[Value]): Value =
  try: result = interp.invoke(fn, args)
  except LispError as e:
    if e.line == 0:
      e.line = max(1, fn.line)
      e.msg = (if fn.source.len > 0: fn.source else: "<call>") & ":" & $e.line & ": " & e.msg
    raise

proc makeLambda(args: seq[Value], env: Env): Value =
  args.arity(1)
  var params: seq[string]
  for p in args[0].asList:
    let name = p.asSymbol
    if name in params: fail("Duplicate parameter: " & name)
    params.add name
  Value(kind: vLambda, params: params, body: args[1..^1], env: env)

proc evaluate(i: Interp, v: Value, env: Env): Value =
  if v.kind == vSymbol: return env.lookup(v.str)
  if v.kind != vList: return v
  let head = v.items[0]
  let args = v.items[1..^1]
  if head.kind == vSymbol:
    case head.str
    of "quote":
      args.arity(1, 1)
      return args[0]
    of "if":
      args.arity(2)
      if i.eval(args[0], env).truth: return i.eval(args[1], env)
      return i.sequence(args[2..^1], env)
    of "progn": return i.sequence(args, env)
    of "let":
      args.arity(1)
      let local = Env(parent: env)
      for binding in args[0].asList:
        if binding.kind == vSymbol: local.values[binding.str] = nilValue()
        else:
          let pair = binding.asList
          pair.arity(1, 2)
          local.values[pair[0].asSymbol] = if pair.len == 2: i.eval(pair[1], env) else: nilValue()
      return i.sequence(args[1..^1], local)
    of "setq":
      if args.len mod 2 != 0: fail("setq requires name/value pairs")
      result = nilValue()
      for n in countup(0, args.len - 1, 2):
        let name = args[n].asSymbol
        result = i.eval(args[n+1], env)
        let target = env.owner(name)
        (if target == nil: i.env else: target).values[name] = result
      return
    of "lambda": return makeLambda(args, env)
    of "defun":
      args.arity(2)
      let name = args[0].asSymbol
      i.env.values[name] = makeLambda(args[1..^1], env)
      return args[0]
    of "while":
      args.arity(1)
      while i.eval(args[0], env).truth: discard i.sequence(args[1..^1], env)
      return nilValue()
    of "and", "or":
      result = boolean(head.str == "and")
      for arg in args:
        result = i.eval(arg, env)
        if result.truth == (head.str == "or"): return
      return
    of "cond":
      for arg in args:
        let clause = arg.asList
        clause.arity(1)
        let test = i.eval(clause[0], env)
        if test.truth:
          return if clause.len == 1: test else: i.sequence(clause[1..^1], env)
      return nilValue()
    else: discard
  let fn = if head.kind == vSymbol: env.lookup(head.str, true) else: i.eval(head, env)
  var values: seq[Value]
  for arg in args: values.add i.eval(arg, env)
  i.invoke(fn, values)

proc eval(i: Interp, v: Value, env: Env): Value =
  try: result = i.evaluate(v, env)
  except LispError as e:
    if e.line == 0:
      e.line = max(1, v.line)
      e.msg = v.source & ":" & $e.line & ": " & e.msg
    raise

proc evalString*(interp: Interp, src, sourceName: string): Value =
  var reader = Reader(src: src, source: sourceName, line: 1)
  result = nilValue()
  reader.skip()
  while reader.pos < src.len:
    var form: Value
    try: form = reader.read()
    except LispError as e:
      e.msg = sourceName & ":" & $e.line & ": " & e.msg
      raise
    result = interp.eval(form, interp.env)
    reader.skip()

proc evalFile*(interp: Interp, path: string): Value =
  interp.evalString(readFile(path), path)

proc defPrimitive*(interp: Interp, name: string, fn: proc(args: seq[Value]): Value {.closure.}) =
  interp.env.values[name] = Value(kind: vPrimitive, primitive: fn)

proc same(a, b: Value, deep: bool): bool =
  if a.kind != b.kind: return false
  case a.kind
  of vNil, vTrue: true
  of vNumber: a.number == b.number
  of vSymbol: a.str == b.str
  of vString: (if deep: a.str == b.str else: a == b)
  of vList:
    if not deep: return a == b
    if a.items.len != b.items.len: return false
    for n in 0..<a.items.len:
      if not same(a.items[n], b.items[n], true): return false
    true
  else: a == b

proc builtin(name: string, args: seq[Value]): Value =
  case name
  of "+", "-", "*", "/":
    args.arity(if name in ["-", "/"]: 1 else: 0)
    var n = if name == "*": 1.0 else: 0.0
    for idx, arg in args:
      let x = arg.asNumber
      case name
      of "+": n += x
      of "*": n *= x
      of "-": n = if idx == 0 and args.len > 1: x else: n - x
      else:
        if idx == 0 and args.len > 1: n = x
        else:
          if x == 0: fail("Division by zero")
          n = (if args.len == 1: 1.0 else: n) / x
    num(n)
  of "=", "<", ">", "<=", ">=":
    args.arity(2)
    var ok = true
    var a = args[0].asNumber
    for arg in args[1..^1]:
      let b = arg.asNumber
      ok = ok and (case name
        of "=": a == b
        of "<": a < b
        of ">": a > b
        of "<=": a <= b
        else: a >= b)
      a = b
    boolean(ok)
  of "not":
    args.arity(1, 1)
    boolean(not args[0].truth)
  of "eq", "equal":
    args.arity(2, 2)
    boolean(same(args[0], args[1], name == "equal"))
  of "list": list(args)
  of "car", "cdr":
    args.arity(1, 1)
    let xs = args[0].asList
    if xs.len == 0: nilValue()
    elif name == "car": xs[0]
    else: list(xs[1..^1])
  of "cons":
    args.arity(2, 2)
    list(@[args[0]] & args[1].asList)
  of "length":
    args.arity(1, 1)
    num(float(if args[0].kind == vString: args[0].str.runeLen else: args[0].asList.len))
  of "nth":
    args.arity(2, 2)
    let n = args[0].asNumber
    let xs = args[1].asList
    if n < 0 or n != floor(n): fail("Expected nonnegative integer index")
    if n >= float(xs.len): nilValue() else: xs[int(n)]
  of "concat", "message":
    var s = ""
    for arg in args:
      s.add(if name == "concat": arg.asString elif arg.kind == vString: arg.str else: $arg)
    stringValue(s)
  of "string=":
    args.arity(2, 2)
    boolean(args[0].asString == args[1].asString)
  of "number-to-string":
    args.arity(1, 1)
    discard args[0].asNumber
    stringValue($args[0])
  else: fail("Unknown primitive: " & name)

proc newInterp*(): Interp =
  result = Interp(env: Env())
  proc register(i: Interp, name: string) =
    i.defPrimitive(name, proc(args: seq[Value]): Value = builtin(name, args))
  for name in ["+", "-", "*", "/", "=", "<", ">", "<=", ">=", "not", "eq", "equal",
      "list", "car", "cdr", "cons", "length", "nth", "concat", "string=", "number-to-string", "message"]:
    register(result, name)
