## Append the current file's branch without replacing diagnostics or terminal state.
import std/times
import ../[core, buffer, vcline]

var branches: BranchCache
let previous = modeLineHook
modeLineHook = proc(): string =
  result = if previous != nil: previous() else: ""
  let branch = branches.branchFor(b.path, epochTime())
  if branch.len > 0: result.add " git:" & branch
