import std/[strutils, os]
import ../src/lisp

let i = newInterp()
proc run(src: string): Value = i.evalString(src, "test.el")
proc check(src, expected: string) = doAssert $run(src) == expected, src
proc error(src, message: string, line: int) =
  try:
    discard run(src)
    doAssert false, src
  except LispError as e:
    doAssert e.line == line, e.msg
    doAssert e.msg.startsWith("test.el:" & $line & ": "), e.msg
    doAssert message in e.msg, e.msg

block reader:
  check("; comment\n'(a 1 -2.5 (t nil) ())", "(a 1 -2.5 (t nil) nil)")
  check("'\"a\\n\\\"\\\\b\"", "\"a\\n\\\"\\\\b\"")
  check("'x", "x")
  check(" ; empty", "nil")
  let tree = run("'\n(a\n (b))")
  doAssert tree.line == 2 and tree.items[1].line == 3
  error("\n(a", "Unclosed list", 2)
  error(")", "Unexpected )", 1)
  error("\n\"abc", "Unclosed string", 2)

block arithmetic:
  check("(+ 1 (* 2 3) (/ 8 4) (- 5 2))", "12")
  check("(- 3)", "-3")
  check("(/ 2)", "0.5")
  check("(list (+) (*) (= 2 2) (< 1 2 3) (> 3 2) (<= 2 2) (>= 3 2))", "(0 1 t t t t t)")
  check("(list (not nil) (not 0) (not \"\") (if '() 1 2))", "(t nil nil 2)")
  error("(/ 1 0)", "Division by zero", 1)

block functions:
  check("(defun fact (n) (if (<= n 1) 1 (* n (fact (- n 1))))) (fact 6)", "720")
  check("(setq x 10) (setq f (let ((x 2)) (lambda (n) (+ x n)))) (let ((x 100)) (f 3))", "5")
  check("(setq counter (let ((n 0)) (lambda () (setq n (+ n 1))))) (counter) (counter)", "2")
  check("(let ((x 3) (y x)) y)", "10")
  check("(let ((f (lambda (x) (+ x 1)))) (f 4))", "5")
  check("((lambda (x) (+ x 1)) 7)", "8")
  doAssert $i.call(symbol("fact"), @[run("5")]) == "120"
  doAssert $i.call(run("(lambda () 9)"), @[]) == "9"
  try:
    discard i.call(symbol("missing-command"), @[])
    doAssert false
  except LispError as e:
    doAssert e.line == 1 and e.msg.startsWith("<call>:1: Undefined function")

block control:
  check("(setq n 0 sum 0) (while (< n 5) (setq sum (+ sum n) n (+ n 1))) sum", "10")
  check("(progn (setq x 1) (setq x 2) x)", "2")
  check("(list (and) (or) (and 1 2) (or nil 3) (and nil missing) (or t missing))", "(t nil 2 3 nil t)")
  check("(cond ((= 1 2) missing) ((+ 1 2)) (t 4))", "3")
  check("(cond (nil 1) (t 2 3))", "3")
  check("(setq)", "nil")
  check("(let (x) x)", "nil")

block listsAndStrings:
  check("(list (car nil) (cdr nil) (cdr '(1)) (cons 1 '(2 3)) (nth 1 '(4 5)) (nth 9 nil))", "(nil nil nil (1 2 3) 5 nil)")
  check("(list (eq 'a 'a) (equal '(1 (2)) '(1 (2))) (eq '(1) '(1)))", "(t t nil)")
  check("(list (length '(1 2)) (length \"日本語\") (string= \"a\" \"a\"))", "(2 3 t)")
  check("(concat \"a\" (number-to-string 2))", "\"a2\"")
  check("(message \"a\" 2 'b)", "\"a2b\"")

block errors:
  error("(progn\n (+ 1 missing))", "Undefined symbol: missing", 2)
  error("\nmissing", "Undefined symbol: missing", 2)
  error("\n(no-such-function)", "Undefined function", 2)
  error("\n(car)", "Not enough arguments", 2)
  error("(fact)", "Not enough arguments", 1)
  error("(car 1)", "Expected list", 1)
  error("(setq x)", "name/value pairs", 1)
  error("(lambda (x x) x)", "Duplicate parameter", 1)
  discard i.evalString("(defun broken ()\n missing)", "init.el")
  try:
    discard run("(broken)")
    doAssert false
  except LispError as e:
    doAssert e.line == 2 and e.msg.startsWith("init.el:2: ")

block primitives:
  var received = ""
  i.defPrimitive("capture", proc(args: seq[Value]): Value =
    args.arity(1, 1)
    received = args[0].asString
    args[0])
  check("(capture \"hello\")", "\"hello\"")
  doAssert received == "hello"
  error("\n(capture)", "Not enough arguments", 2)
  let path = getCurrentDir() / "nimcache" / "tlisp-init.el"
  writeFile(path, "(setq loaded 42)\nloaded")
  doAssert $i.evalFile(path) == "42"

block names:
  let j = newInterp()
  j.defPrimitive("zap", proc(args: seq[Value]): Value = nilValue())
  discard j.evalString("(defun hello () 1) (defun twice (x) x) (setq n 3)", "names.el")
  doAssert j.names == @["hello", "zap"], $j.names

echo "lisp tests passed"
