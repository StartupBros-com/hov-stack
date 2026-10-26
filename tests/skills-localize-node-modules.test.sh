#!/usr/bin/env bash
# skills-localize-node-modules.test.sh — sync_fork() must leave a deployed skill's
# node_modules alone.
#
# WHY THIS EXISTS
#   plugins/hov-stack/skills/<name>/ is deployed with `rsync -a --delete`. A skill that carries a
#   package.json (sign-pdf, 2026-09-11) needs `pnpm install` run once in the deployed
#   copy; node_modules is gitignored, so it is absent from the source and --delete
#   would erase it on every dotup refresh while `check` flagged it as DRIFT. The fix
#   excludes node_modules from the sync in both directions. This test runs the real
#   function against temp trees, so a regression shows up in CI without a live jsm tree.
set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT=$(cd -P "$(dirname "$SELF")/.." && pwd)/scripts/skills-localize.sh
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find skills-localize.sh at $SCRIPT"; exit 1; }
command -v rsync >/dev/null || { echo "SKIP: rsync not installed"; exit 0; }

fn=$(sed -n '/^sync_fork() {/,/^}/p' "$SCRIPT")
[ -n "$fn" ] || { echo "FAIL: sync_fork() not found in $SCRIPT"; exit 1; }
eval "$fn"
valid_skill_name() { return 0; }
reject_name() { :; }
notes=""
note() { notes="$notes"$'\n'"$*"; }
drift=0; errors=0

T=$(mktemp -d /tmp/skills-localize-nm.XXXXXX)
SRC="$T/src/demo"; DST="$T/skills"
mkdir -p "$SRC/scripts" "$DST"
echo "---" > "$SRC/SKILL.md"; echo "x" > "$SRC/scripts/x.mjs"

pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

MODE=apply; DRY=0
sync_fork "$SRC/" "$DST" demo claude
check "initial deploy copies the skill" "[ -f $DST/demo/SKILL.md ] && [ -f $DST/demo/scripts/x.mjs ]"

# a locally installed dependency tree in the deployed copy
mkdir -p "$DST/demo/node_modules/pdf-lib"; echo "{}" > "$DST/demo/node_modules/pdf-lib/package.json"
MODE=check; drift=0; notes=""
sync_fork "$SRC/" "$DST" demo claude
check "check mode does not report node_modules as drift" "[ $drift -eq 0 ]"
MODE=apply
sync_fork "$SRC/" "$DST" demo claude
check "apply preserves the deployed node_modules" "[ -f $DST/demo/node_modules/pdf-lib/package.json ]"

# control: --delete still removes a stray file that is not node_modules
echo "stray" > "$DST/demo/stray.txt"
MODE=check; drift=0
sync_fork "$SRC/" "$DST" demo claude
check "check mode still reports a stray file as drift" "[ $drift -eq 1 ]"
MODE=apply
sync_fork "$SRC/" "$DST" demo claude
check "apply still deletes the stray file" "[ ! -e $DST/demo/stray.txt ]"
check "and still keeps node_modules" "[ -d $DST/demo/node_modules ]"

# control: a node_modules in the SOURCE is not copied either (keeps deploys small)
mkdir -p "$SRC/node_modules/junk"; echo "j" > "$SRC/node_modules/junk/index.js"
sync_fork "$SRC/" "$DST" demo claude
check "source node_modules is not deployed" "[ ! -e $DST/demo/node_modules/junk ]"

rm -rf "$T"
echo "---- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
