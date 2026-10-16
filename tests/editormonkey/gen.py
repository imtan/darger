import random, sys, os
seed = int(sys.argv[1]); n = int(sys.argv[2]); home = sys.argv[3]
rng = random.Random(seed)
files = [f"{home}/a.org", f"{home}/b.nim", f"{home}/c.txt", f"{home}/d.md"]
cmds = ["forward","backward","next-line","previous-line","bol","eol","bob","eob","forward-word","backward-word",
        "newline","tab","open-line","delete","backspace","kill-line","kill-word","backward-kill-word","mark","exchange",
        "whole","kill-region","copy-region","yank","yank-pop","undo","transpose","upcase","downcase","capitalize","indent"]
texts = ['"hello"', '"* Head"', '"** TODO sub"', '"日本語"', '"\\n"', '"- [ ] item"', '"[[id:x][link]]"', '"<2026-10-16 Fri>"']
out = []
for i in range(n):
    r = rng.random()
    if r < 0.35: out.append(f'(command "{rng.choice(cmds)}")')
    elif r < 0.50: out.append(f'(insert {rng.choice(texts)})')
    elif r < 0.60: out.append(f'(find-file "{rng.choice(files)}")')
    elif r < 0.70: out.append(rng.choice(["(split-window-below)","(split-window-right)","(other-window)","(delete-window)",
                                        "(delete-other-windows)","(enlarge-window)","(shrink-window)","(enlarge-window-horizontally)",
                                        "(shrink-window-horizontally)","(balance-windows)"]))
    elif r < 0.80: out.append(rng.choice(["(org-cycle)","(org-shifttab)","(org-todo)","(org-meta-return)","(org-promote)","(org-demote)",
                                        "(org-move-subtree-up)","(org-move-subtree-down)","(org-toggle-checkbox)","(org-id-get-create)"]))
    elif r < 0.86: out.append(rng.choice(['(switch-to-buffer "*scratch*")','(switch-to-buffer "new one")','(kill-buffer "new one")',
                                        '(kill-buffer "c.txt")','(next-buffer)','(previous-buffer)']))
    elif r < 0.92: out.append(rng.choice(["(skk-mode)","(zoom-in)","(zoom-out)","(zoom-reset)",'(load-theme "catppuccin")','(load-theme "modus-vivendi")',
                                        "(dashboard)","(revert-buffer)","(save-buffer)","(org-journal-new-entry)"]))
    else: out.append(rng.choice(["(message \"x\")","(org-agenda)","(list-buffers)","(help)","(dired \"" + home + "\")"]))
# leave any overlay/prompt open at the end; the run only checks for crashes
open(f"{home}/.darger.el","w").write("\n".join([
  f'(setq org-journal-dir "{home}/journal")', f'(setq org-agenda-files "{home}/a.org")'] + [f"(ignore-errors {c})" for c in out]) + "\n")
