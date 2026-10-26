#!/usr/bin/env bash
# Hermetic regression contract for harness-weekly.sh's dream-pass patch-set prune
# (dotfiles#1320 / PR #1330 review, testing finding 2 of 3).
#
# THE BLOCK: harness-weekly runs unattended every Monday and deletes per-pass
# patch-set directories older than 90 days under two roots: the memory-dream@hov
# plugin's logs/memory-dream/passes and the retired pre-plugin logs/dream-pass.
# The plugin's doctor only REPORTS retention, so this loop is the only thing that
# ever deletes a patch set. A path typo, a quoting slip, or a widened find would
# either stop pruning silently or reach into sibling directories, and nothing
# else in CI would notice before it ran against the operator's real ~/.claude/logs.
#
# EXTRACTION APPROACH: the same one harness-weekly-pipeline-mix.test.sh uses.
# Running the whole script would invoke harness-doctor, gh, pnpm and the real
# notify.sh. This sed-extracts the REAL prune loop out of the shipped script and
# runs it against a scratch LOGDIR, so it exercises shipped code rather than a
# hand-copied twin. The sanity checks below fail loudly if the extraction ever
# comes back empty or loses either root, so restructuring harness-weekly.sh
# cannot silently turn this suite into a test of nothing.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=$REPO/scripts/harness-weekly.sh
TMP=$(mktemp -d /tmp/hw-dream-prune-test.XXXXXX)
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
present() { if [ -e "$1" ]; then ok; else bad "$2: expected $1 to survive"; fi; }
absent()  { if [ -e "$1" ]; then bad "$2: expected $1 to be pruned"; else ok; fi; }

# -- extract the prune loop from the REAL shipped script -----------------------
anchors=$(grep -c '^for _pass_dir in ' "$SRC")
if [ "$anchors" = 1 ]; then ok; else
  echo "FAIL: expected exactly one 'for _pass_dir in' loop in harness-weekly.sh, found $anchors -- the extraction anchor is ambiguous" >&2
  exit 1
fi
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo 'LOGDIR=$1'
  sed -n '/^for _pass_dir in /,/^done$/p' "$SRC"
} > "$TMP/prune.sh"
chmod +x "$TMP/prune.sh"

if [ -s "$TMP/prune.sh" ]; then ok; else
  echo "FAIL: sed extraction produced an empty prune.sh -- the 'for _pass_dir in' anchor in harness-weekly.sh may have changed" >&2
  exit 1
fi
bash -n "$TMP/prune.sh" || { echo "FAIL: extracted prune.sh has a syntax error" >&2; exit 1; }
for needle in 'memory-dream/passes' 'dream-pass' '-mtime +90' '-type d' '-mindepth 1 -maxdepth 1'; do
  if grep -qF -- "$needle" "$TMP/prune.sh"; then ok; else
    bad "extraction sanity: '$needle' is missing from the extracted prune loop"
  fi
done

# -- scratch LOGDIR builder ------------------------------------------------------
# Children are created BEFORE the parent's mtime is aged, because creating a child
# bumps the parent directory's mtime and find -mtime +90 reads the directory's own.
build_tree() {
  local root=$1
  mkdir -p "$root/memory-dream/passes/20260601-old/proposed" \
           "$root/memory-dream/passes/20260920-fresh" \
           "$root/dream-pass/20260501-old" \
           "$root/dream-pass/20260921-fresh" \
           "$root/memory-dream/eval/20260501-old-sibling"
  echo '{}' > "$root/memory-dream/passes/20260601-old/manifest.json"
  echo 'x' > "$root/memory-dream/passes/aged-file.txt"
  touch -d '100 days ago' \
    "$root/memory-dream/passes/20260601-old" \
    "$root/dream-pass/20260501-old" \
    "$root/memory-dream/eval/20260501-old-sibling" \
    "$root/memory-dream/passes/aged-file.txt"
}

# -- scenario A: both roots present ---------------------------------------------
LOG="$TMP/a"; build_tree "$LOG"
out=$(bash "$TMP/prune.sh" "$LOG" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok; else bad "A: prune exited $rc: $out"; fi
if [ -z "$out" ]; then ok; else bad "A: prune printed unexpectedly: $out"; fi
absent  "$LOG/memory-dream/passes/20260601-old"        "A: aged plugin pass"
present "$LOG/memory-dream/passes/20260920-fresh"      "A: fresh plugin pass"
absent  "$LOG/dream-pass/20260501-old"                 "A: aged legacy pass"
present "$LOG/dream-pass/20260921-fresh"               "A: fresh legacy pass"
present "$LOG/memory-dream/eval/20260501-old-sibling"  "A: aged sibling outside both roots (no widening)"
present "$LOG/memory-dream/passes/aged-file.txt"       "A: aged regular file (-type d only)"
present "$LOG/memory-dream/passes"                     "A: the passes root itself (-mindepth 1)"

# -- scenario B: neither root exists --------------------------------------------
LOG="$TMP/b"; mkdir -p "$LOG"
out=$(bash "$TMP/prune.sh" "$LOG" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok; else bad "B: prune exited $rc with no roots present: $out"; fi
if [ -z "$out" ]; then ok; else bad "B: prune printed with no roots present: $out"; fi
if [ ! -e "$LOG/memory-dream" ] && [ ! -e "$LOG/dream-pass" ]; then ok; else bad "B: prune created a root as a side effect"; fi

# -- scenario C: only the retired legacy root exists ----------------------------
LOG="$TMP/c"; mkdir -p "$LOG/dream-pass/20260501-old" "$LOG/dream-pass/20260921-fresh"
touch -d '100 days ago' "$LOG/dream-pass/20260501-old"
out=$(bash "$TMP/prune.sh" "$LOG" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok; else bad "C: prune exited $rc: $out"; fi
absent  "$LOG/dream-pass/20260501-old"   "C: aged legacy pass with plugin root absent"
present "$LOG/dream-pass/20260921-fresh" "C: fresh legacy pass"
if [ ! -e "$LOG/memory-dream" ]; then ok; else bad "C: prune created memory-dream/ as a side effect"; fi

# -- scenario D: LOGDIR containing a space (quoting) -----------------------------
LOG="$TMP/d dir"; build_tree "$LOG"
out=$(bash "$TMP/prune.sh" "$LOG" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok; else bad "D: prune exited $rc on a LOGDIR with a space: $out"; fi
absent  "$LOG/memory-dream/passes/20260601-old"   "D: aged plugin pass under a spaced LOGDIR"
present "$LOG/memory-dream/passes/20260920-fresh" "D: fresh plugin pass under a spaced LOGDIR"

echo "harness-weekly-dream-pass-prune: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
