## Open buffers: creation order for C-x left/right, MRU order for C-x b, and
## Emacs-style unique display names.
import std/[os, strutils, math, sequtils]
import buffer, syntax

type
  Slot* = object
    buf*: Buffer
    top*, left*: int
    lang*: Lang         # Lang() = not detected yet
    langPath*: string   # the path lang was detected for
    name*: string       # a path-less buffer's name typed at C-x b
  Registry* = object
    slots*: seq[Slot]   # creation order
    mru: seq[Buffer]    # most recently used first

proc find(reg: Registry, buf: Buffer): int =
  for i, s in reg.slots:
    if s.buf == buf: return i
  -1

proc len*(reg: Registry): int = reg.slots.len

proc contains*(reg: Registry, buf: Buffer): bool = reg.find(buf) >= 0

proc slot*(reg: var Registry, buf: Buffer): var Slot = reg.slots[reg.find(buf)]

proc add*(reg: var Registry, buf: Buffer, name = "") =
  ## Appends buf as the least recently used buffer; touch it to make it current.
  if buf in reg: return
  reg.slots.add Slot(buf: buf, name: name)
  reg.mru.add buf

proc remove*(reg: var Registry, buf: Buffer) =
  let i = reg.find(buf)
  if i < 0: return
  reg.slots.delete(i)
  reg.mru.delete(reg.mru.find(buf))

proc touch*(reg: var Registry, buf: Buffer) =
  let i = reg.mru.find(buf)
  if i < 0: return
  reg.mru.delete(i)
  reg.mru.insert(buf, 0)

proc current*(reg: Registry): Buffer = (if reg.mru.len > 0: reg.mru[0] else: nil)

proc other*(reg: Registry): Buffer =
  ## The most recently used buffer after the current one, nil if none.
  if reg.mru.len > 1: reg.mru[1] else: nil

proc cycle*(reg: Registry, buf: Buffer, delta: int): Buffer =
  ## The buffer delta steps from buf in creation order, wrapping.
  if reg.slots.len == 0: return nil
  let i = max(0, reg.find(buf))
  reg.slots[floorMod(i + delta, reg.slots.len)].buf

proc base(s: Slot): string =
  if s.buf.path.len > 0: extractFilename(s.buf.path)
  elif s.name.len > 0: s.name
  else: "*scratch*"

proc dirSuffix(path: string, depth: int): string =
  ## The last depth directories above path's file, "/"-joined.
  var parts: seq[string]
  var dir = parentDir(path)
  while parts.len < depth and dir.len > 0:
    let tail = extractFilename(dir)
    if tail.len == 0: break  # the root
    parts.insert(tail, 0)
    dir = parentDir(dir)
  parts.join("/")

proc labels(reg: Registry): seq[string] =
  ## Display names in slot order: files sharing a name get "<dir>" (deepening until they
  ## differ, like uniquify's post-forward-angle-brackets); what is still equal gets "<N>".
  for s in reg.slots: result.add s.base
  var done: seq[string]
  for i in 0..reg.slots.high:
    let name = reg.slots[i].base
    if reg.slots[i].buf.path.len == 0 or name in done: continue
    done.add name
    var group: seq[int]
    for j in 0..reg.slots.high:
      if reg.slots[j].buf.path.len > 0 and reg.slots[j].base == name: group.add j
    if group.len < 2: continue
    var depth = 1
    while group.len > 0:
      var rest: seq[int]
      for j in group:
        let suffix = dirSuffix(reg.slots[j].buf.path, depth)
        let clash = group.anyIt(it != j and dirSuffix(reg.slots[it].buf.path, depth) == suffix)
        if clash and dirSuffix(reg.slots[j].buf.path, depth + 1) != suffix: rest.add j
        elif suffix.len > 0: result[j] = name & "<" & suffix & ">"
      group = rest
      inc depth
  for i in 1..reg.slots.high:
    let raw = result[i]
    var n = 1
    while result[i] in result[0..<i]:
      inc n
      result[i] = raw & "<" & $n & ">"

proc displayName*(reg: Registry, buf: Buffer): string =
  let i = reg.find(buf)
  if i >= 0: reg.labels[i]
  elif buf.path.len > 0: extractFilename(buf.path)
  else: "*scratch*"

proc buffers*(reg: Registry): seq[Buffer] =
  ## Most recently used first.
  reg.mru

proc names*(reg: Registry): seq[string] =
  ## Display names, most recently used first.
  let all = reg.labels
  for buf in reg.mru: result.add all[reg.find(buf)]

proc byName*(reg: Registry, name: string): Buffer =
  let all = reg.labels
  for i, label in all:
    if label == name: return reg.slots[i].buf

proc byPath*(reg: Registry, path: string): Buffer =
  let want = normalizedPath(absolutePath(path))
  for s in reg.slots:
    if s.buf.path.len > 0 and cmpPaths(normalizedPath(s.buf.path), want) == 0: return s.buf
