#!/usr/bin/env bash
# make-runs.sh <root> <map.tsv> <arm> <reps> <task>...
#
# Creates blinded run dirs under <root>/runs/<random id>/ for one arm and
# appends "id<TAB>arm<TAB>task<TAB>rep" to <map.tsv>, which must live outside
# <root> so an arm never sees which arm it is.
#
# Arm definitions live in arms/<arm>/ beside this script, or at any path:
#   CLAUDE.md   copied to config/CLAUDE.md (always-loaded user memory)
#   prefix.txt  prepended to the task prompt (a /slash command)
#   plugin.txt  a --plugin-dir path
# A missing file means the arm does not use that surface; the bare arm has none.
#
# MODEL=<alias> in the environment writes model.txt into each run (run_arm.sh
# passes it to --model; default sonnet) and records the arm as <arm>@<alias>
# in <map.tsv>.
#
# <root>/base must already hold the fixture repo (build-base.sh).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$1"; MAP="$2"; ARMDEF="$3"; REPS="$4"; shift 4
# <arm> is a name under arms/ or a path to an arm directory kept outside the
# repo (contender texts whose license does not allow committing them).
[ -d "$ARMDEF" ] || ARMDEF="$HERE/arms/$ARMDEF"
[ -d "$ARMDEF" ] || { echo "make-runs: no arm definition $ARMDEF" >&2; exit 1; }
ARM="$(basename "$ARMDEF")"
MODEL="${MODEL:-}"
[ -n "$MODEL" ] && ARM="$ARM@$MODEL"
[ -d "$ROOT/base/.git" ] || { echo "make-runs: build $ROOT/base first" >&2; exit 1; }
mkdir -p "$ROOT/runs"

for task in "$@"; do
  for rep in $(seq 1 "$REPS"); do
    id="$(python3 -I -c 'import secrets; print(secrets.token_hex(4))')"
    run="$ROOT/runs/$id"
    mkdir -p "$run/config"
    cp -a "$ROOT/base" "$run/repo"
    prefix=""
    [ -f "$ARMDEF/prefix.txt" ] && prefix="$(cat "$ARMDEF/prefix.txt") "
    printf '%s%s' "$prefix" "$(cat "$HERE/tasks/$task.txt")" > "$run/prompt.txt"
    [ -f "$ARMDEF/CLAUDE.md" ] && cp "$ARMDEF/CLAUDE.md" "$run/config/CLAUDE.md"
    [ -f "$ARMDEF/plugin.txt" ] && cp "$ARMDEF/plugin.txt" "$run/plugin-dir.txt"
    [ -n "$MODEL" ] && printf '%s\n' "$MODEL" > "$run/model.txt"
    printf '%s\n' "$task" > "$run/task.txt"
    printf '%s\t%s\t%s\t%s\n' "$id" "$ARM" "$task" "$rep" >> "$MAP"
  done
done
