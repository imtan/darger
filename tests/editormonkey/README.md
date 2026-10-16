# Editor monkey

`run.sh FROM TO N` starts one darger per seed with a generated `~/.darger.el` of N
random commands (buffer edits, windows, Org, buffers, files, themes, journal, agenda,
dired, help), each wrapped in `(ignore-errors ...)`, in a temporary HOME under this
directory, waits 2.5 s and reports seeds whose process died or wrote a trace to
stderr. It opens real windows, so run it when the screen is free; it never touches
the real HOME. `gen.py SEED N HOME` writes the init file alone.
