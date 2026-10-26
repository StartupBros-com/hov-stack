#!/usr/bin/env bash
# wt-sweep-alive.test.sh — liveness detection in wt-sweep.sh's alive().
#
# THE REGRESSION THIS GUARDS (2026-08-06)
#   alive() used to consult only /proc/*/cwd. A daemon that receives its target as
#   a --cwd FLAG while running detached (own cwd elsewhere, reparented to init) was
#   therefore invisible, so wt-sweep would remove the worktree out from under a live
#   writer. A codex app-server-broker survived exactly that, ran orphaned for 15
#   days, and wrote ~400 GiB into ~/.codex/logs_2.sqlite before anyone looked.
#
#   The asymmetry is deliberate: a false "alive" only defers a sweep by a week, while
#   a false "dead" silently burns SSD endurance. So this suite pins BOTH directions —
#   the flag-only daemon must read alive, and a genuinely unreferenced dir must not
#   (or the fix would degenerate into "everything is always alive").
#
#   Since issue #378 the signals live in scripts/lib/proc_liveness.py, shared
#   with reclaim-sweep.py; alive() is a thin fail-closed wrapper. This suite tests
#   the wrapper end-to-end (extraction unchanged in spirit: eval only alive(), never
#   source the whole script — sourcing it would sweep worktrees).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/wt-sweep.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find $SCRIPT"; exit 1; }

# Pull in ONLY the alive() definition via its markers.
eval "$(sed -n '/^# ALIVE_BEGIN/,/^# ALIVE_END/p' "$SCRIPT")"
declare -F alive >/dev/null || { echo "FAIL: could not extract alive() from $SCRIPT"; exit 1; }
LIB="$HERE/../scripts/lib"   # alive() resolves this from $0 in the real script
[ -f "$LIB/proc_liveness.py" ] || { echo "FAIL: cannot find $LIB/proc_liveness.py"; exit 1; }

pass=0; fail=0
check(){ # name want_rc path
  local name="$1" want="$2" path="$3" got
  if alive "$path"; then got=0; else got=1; fi
  if [ "$got" = "$want" ]; then echo "  ok: $name"; pass=$((pass+1))
  else echo "  FAIL: $name (alive=$got, want $want)"; fail=$((fail+1)); fi
}

TMP="$(mktemp -d)"; FAKE="$TMP/worktree-probe"; mkdir -p "$FAKE"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

check "unreferenced dir is not alive" 1 "$FAKE"

# The leak shape: cwd is /, the worktree path appears only in argv.
( cd / && exec python3 -c "import time; time.sleep(30)" --cwd "$FAKE" ) &
flagpid=$!
sleep 1
check "daemon holding worktree via --cwd flag only" 0 "$FAKE"
kill "$flagpid" 2>/dev/null; wait "$flagpid" 2>/dev/null

sleep 1
check "not alive once that daemon exits" 1 "$FAKE"

# Original behaviour must survive the fix.
( cd "$FAKE" && exec sleep 30 ) &
cwdpid=$!
sleep 1
check "process with cwd inside is alive (original path)" 0 "$FAKE"
kill "$cwdpid" 2>/dev/null; wait "$cwdpid" 2>/dev/null

# New with #378: an open fd inside the worktree, with cwd elsewhere and no argv
# mention, must also read alive (this was reclaim-sweep's only signal; now both
# sweepers see all four).
( cd / && exec sleep 30 ) 9>"$FAKE/held.log" &
fdpid=$!
sleep 1
check "process holding an open fd inside is alive" 0 "$FAKE"
kill "$fdpid" 2>/dev/null; wait "$fdpid" 2>/dev/null

# Also new with #378: the idle-background-job shape — the path lives ONLY in a
# process's environment (CLAUDE_JOB_DIR), no fd, cwd elsewhere, argv silent.
( cd / && PROBE_JOB_DIR="$FAKE" exec sleep 30 ) &
envpid=$!
sleep 1
check "process holding worktree via environment only" 0 "$FAKE"
kill "$envpid" 2>/dev/null; wait "$envpid" 2>/dev/null

# Fail-closed: a checker that cannot run must read ALIVE, never dead — a gate
# that cannot compare must fail. (LIB pointed somewhere empty; rc>=2 path.)
if LIB="$TMP/no-such-lib" alive "$FAKE" 2>/dev/null; then
  echo "  ok: missing checker fails closed (reads alive)"; pass=$((pass+1))
else
  echo "  FAIL: missing checker read as dead — sweep would proceed blind"; fail=$((fail+1))
fi

# U5 fixture: clean, pushed, idle worktree with no process holding it.
# Git and route resolver are stubs; removal only deletes this disposable fixture.
mkdir -p "$TMP/sweep/repo/.git" "$TMP/sweep/worktree" "$TMP/bin" "$TMP/home"
cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
r=$2; shift 2
case "$*" in
  'rev-parse --git-dir') echo "$FAKE_SWEEP_ROOT/repo/.git" ;;
  'rev-parse --git-common-dir') echo "$FAKE_SWEEP_ROOT/repo/.git" ;;
  'worktree list --porcelain') printf 'worktree %s/repo\n\nworktree %s/worktree\n' "$FAKE_SWEEP_ROOT" "$FAKE_SWEEP_ROOT" ;;
  'worktree prune'|'for-each-ref '*) : ;;
  'symbolic-ref --short refs/remotes/origin/HEAD') echo origin/main ;;
  'symbolic-ref --short HEAD') echo fixture-branch ;;
  remote) echo origin ;;
  'rev-parse --verify -q origin/main'|'rev-parse -q --verify HEAD') echo fixture-head ;;
  'status --porcelain') : ;;
  'rev-list --count '*) echo 0 ;;
  'log -1 --format=%ct') echo 1000000000 ;;
  'worktree remove --force '*) rm -rf -- "$r/../worktree" ;;
  *) echo "unexpected git fixture: $*" >&2; exit 91 ;;
esac
STUB
cat > "$TMP/route.py" <<'STUB'
#!/usr/bin/env python3
print('{"schema":"repo-route-scan.v1","verified":true,"routes":[]}')
STUB
chmod +x "$TMP/bin/git" "$TMP/route.py"
# State writes, including fixture records, use the shared writer.
# shellcheck source=../scripts/lib/pr-owner-state.sh
source "$LIB/pr-owner-state.sh"
owner_dir="$TMP/home/.claude/.loop-state/pr-owner/fixture--repo--42"
pr_owner_write "$owner_dir" "$(jq -nc --arg tree "$TMP/sweep/worktree" '{state:"owned",worktree:$tree}')"
sweep_fixture() {
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" FAKE_SWEEP_ROOT="$TMP/sweep" ROOT="$TMP/sweep" \
    REPO_ROUTE_RESOLVER="$TMP/route.py" WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 DRY_RUN=0 bash "$SCRIPT"
}
out=$(sweep_fixture 2>&1)
if [ -d "$TMP/sweep/worktree" ] && [[ "$out" == *'skip (PR owner)'* ]]; then
  echo '  ok: idle owned worktree survives sweep'; pass=$((pass+1))
else echo "  FAIL: owned worktree swept: $out"; fail=$((fail+1)); fi
pr_owner_write "$owner_dir" "$(jq -nc --arg tree "$TMP/sweep/worktree" '{state:"merged",worktree:$tree}')"
out=$(sweep_fixture 2>&1)
if [ ! -d "$TMP/sweep/worktree" ] && [[ "$out" == *'removed:1'* ]]; then
  echo '  ok: same worktree swept after merged'; pass=$((pass+1))
else echo "  FAIL: merged worktree retained: $out"; fail=$((fail+1)); fi

echo
if [ "$fail" -eq 0 ]; then echo "$pass passed"; exit 0
else echo "$fail failed, $pass passed"; exit 1; fi
