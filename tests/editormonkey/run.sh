#!/bin/sh
# run.sh FROM TO N: one darger per seed with a generated init file; reports crashes.
S=$(dirname "$0"); crashes=0
for seed in $(seq $1 $2); do
  home=$S/home_$seed; rm -rf "$home"; mkdir -p "$home/journal"  # a throwaway HOME: never the real one
  printf '* A\nbody\n** B\n- [ ] x\n' > "$home/a.org"; printf 'proc x() =\n  echo 1\n' > "$home/b.nim"; printf 'plain\n' > "$home/c.txt"; printf '# md\n' > "$home/d.md"
  python3 "$S/gen.py" $seed $3 "$home"
  HOME=$home $(dirname "$0")/../../darger 2> "$home/err.txt" & pid=$!
  sleep 2.5
  if kill -0 $pid 2>/dev/null; then kill $pid; wait $pid 2>/dev/null; status=alive; else wait $pid; status="exit $?"; fi
  if grep -q 'Error:\|Traceback\|SIGSEGV\|Illegal' "$home/err.txt" || [ "$status" != alive ]; then
    crashes=$((crashes+1)); echo "seed $seed: $status"; grep -v '^$' "$home/err.txt" | tail -4
  fi
done
echo "done: $crashes crashing seeds"
