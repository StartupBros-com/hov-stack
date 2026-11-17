#!/usr/bin/env bash
# tests/launchpad-freshen-sync.test.sh: launchpad-freshen.sh hands the harness checkout (the
# repository whose hooks/ the config dir links to, with an executable ./setup) to
# `./setup --sync` instead of fast-forwarding it alone (#670, step 3).
#   - the harness checkout: DRY_RUN reports and runs nothing; a foreground run prints setup's
#     `sync:` line; --heal returns at once with the hand-off line while setup runs detached
#     (stdin closed, HOV_SYNC_LOCK_WAIT=0, output in sync.log) and nothing is left running
#   - planted negatives: a repo the config dir does not lead into, and a harness-shaped repo
#     whose ./setup is not executable, are never handed to setup
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FRESHEN="$REPO/scripts/launchpad-freshen.sh"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
cat > "$TMP/route-stub.py" <<'STUB'
import json
print(json.dumps({"classification": "unregistered", "mode": "observe", "route": "", "canonical_path": "", "canonical_missing": False}))
STUB
export REPO_ROUTE_RESOLVER="$TMP/route-stub.py"

# clone <name> [executable|plain]: a clone of a bare origin with hooks/ and a ./setup that logs.
clone() {
  local n=$1 mode=${2:-executable}
  git init -q --bare "$TMP/$n.git"
  git -C "$TMP/$n.git" symbolic-ref HEAD refs/heads/main
  git init -q "$TMP/$n.seed"
  git -C "$TMP/$n.seed" symbolic-ref HEAD refs/heads/main
  mkdir -p "$TMP/$n.seed/hooks"
  : > "$TMP/$n.seed/hooks/.keep"
  cat > "$TMP/$n.seed/setup" <<'EOF'
#!/usr/bin/env bash
{
  printf 'args=%s cfg=%s wait=%s fetch=%s\n' "$*" "${CLAUDE_CONFIG_DIR:-}" "${HOV_SYNC_LOCK_WAIT:-unset}" "${HOV_SYNC_FETCH_TIMEOUT:-unset}"
  [ -t 0 ] && echo stdin-is-a-tty || echo stdin-closed
} >> "$SETUP_LOG"
sleep "${SETUP_SLEEP:-0}"
echo "sync: current: fixture at abc1234; nothing to merge into settings.json"
echo "done" >> "$SETUP_LOG"
EOF
  [ "$mode" = executable ] && chmod +x "$TMP/$n.seed/setup"
  git -C "$TMP/$n.seed" add -A
  git -C "$TMP/$n.seed" commit -q -m seed
  git -C "$TMP/$n.seed" remote add origin "$TMP/$n.git"
  git -C "$TMP/$n.seed" push -q origin main
  git clone -q "$TMP/$n.git" "$TMP/$n"
  git -C "$TMP/$n" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
cfg() {  # cfg <name> <checkout the config dir's hooks lead into>
  mkdir -p "$TMP/$1-cfg"
  ln -sfn "$2/hooks" "$TMP/$1-cfg/hooks"
}
export SETUP_LOG=$TMP/setup.log
run() {  # run <cfg> <args...>; stdout in $OUT
  local c=$1; shift
  OUT=$(CLAUDE_HOME="$c" bash "$FRESHEN" "$@" 2>&1 < /dev/null)
}

clone harness; cfg harness "$TMP/harness"
clone other;   cfg other   "$TMP/harness"
clone nosetup plain; cfg nosetup "$TMP/nosetup"

# DRY_RUN.
: > "$SETUP_LOG"
DRY_RUN=1 run "$TMP/harness-cfg" --repo "$TMP/harness"
grep -q '^launchpad harness: would run ./setup --sync (DRY_RUN)$' <<<"$OUT" || fail "dry run said: $OUT"
[ ! -s "$SETUP_LOG" ] || fail "a dry run ran setup"
ok "DRY_RUN names ./setup --sync and runs nothing"

# Foreground.
: > "$SETUP_LOG"
run "$TMP/harness-cfg" --repo "$TMP/harness"
[ "$OUT" = "launchpad harness: sync: current: fixture at abc1234; nothing to merge into settings.json" ] || fail "foreground said: $OUT"
grep -q "^args=--sync cfg=$TMP/harness-cfg wait=60 fetch=60$" "$SETUP_LOG" || { cat "$SETUP_LOG"; fail "foreground call shape"; }
grep -q '^stdin-closed$' "$SETUP_LOG" || fail "setup got a terminal on stdin"
ok "foreground: setup --sync runs on the config dir and its sync: line is the output"

# --heal: returns before a slow setup finishes, runs it detached.
: > "$SETUP_LOG"
start=$(date +%s)
SETUP_SLEEP=3 run "$TMP/harness-cfg" --repo "$TMP/harness" --heal
elapsed=$(( $(date +%s) - start ))
[ "$OUT" = "launchpad harness: handed to ./setup --sync in the background; its result shows at the next session start" ] || fail "heal said: $OUT"
[ "$elapsed" -le 2 ] || fail "--heal waited $elapsed s for setup"
n=0; until grep -q '^done$' "$SETUP_LOG" 2>/dev/null || [ "$n" -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
grep -q '^done$' "$SETUP_LOG" || fail "the detached setup never finished"
grep -q "^args=--sync cfg=$TMP/harness-cfg wait=0 fetch=unset$" "$SETUP_LOG" || { cat "$SETUP_LOG"; fail "detached call shape"; }
grep -q '^stdin-closed$' "$SETUP_LOG" || fail "the detached setup got a terminal on stdin"
grep -q '^sync: current: fixture' "$TMP/harness-cfg/.hov-stack/sync.log" || fail "the detached output is not in sync.log"
n=0; while pgrep -f "$TMP/harness/setup" > /dev/null 2>&1 && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
if pgrep -f "$TMP/harness/setup" > /dev/null 2>&1; then fail "a detached setup is still running"; fi
ok "--heal: hands off in the background (lock wait 0, stdin closed, output in sync.log), nothing left running"

# --heal while a sync holds its lock: no second setup, and the running one's log is not truncated.
lock=$TMP/harness-cfg/.hov-stack/sync.lock
mkdir -p "$lock"
sleep 60 & holder=$!
echo "$holder" > "$lock/pid"
printf 'running sync output\n' > "$TMP/harness-cfg/.hov-stack/sync.log"
: > "$SETUP_LOG"
run "$TMP/harness-cfg" --repo "$TMP/harness" --heal
[ "$OUT" = "launchpad harness: handed to ./setup --sync in the background; its result shows at the next session start" ] || { kill "$holder"; fail "heal under a live lock said: $OUT"; }
sleep 0.5
[ ! -s "$SETUP_LOG" ] || { kill "$holder"; fail "--heal started a second setup while a sync held the lock"; }
[ "$(cat "$TMP/harness-cfg/.hov-stack/sync.log")" = "running sync output" ] || { kill "$holder"; fail "--heal truncated the running sync's log"; }
ok "--heal with a live sync lock: same hand-off line, no second setup, the running log kept"
# A lock whose owner is dead is a crashed run's leftover: heal starts the sync.
kill "$holder"; wait "$holder" 2>/dev/null || :
run "$TMP/harness-cfg" --repo "$TMP/harness" --heal
n=0; until grep -q '^done$' "$SETUP_LOG" 2>/dev/null || [ "$n" -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
grep -q '^done$' "$SETUP_LOG" || fail "a dead holder's lock stopped --heal"
ok "--heal with a dead holder's lock starts the sync"
rm -rf "$lock"

# Planted negatives.
: > "$SETUP_LOG"
run "$TMP/other-cfg" --repo "$TMP/other" --heal
if grep -q 'setup --sync' <<<"$OUT"; then fail "a repo the config dir does not lead into was handed to setup: $OUT"; fi
run "$TMP/nosetup-cfg" --repo "$TMP/nosetup" --heal
if grep -q 'setup --sync' <<<"$OUT"; then fail "a checkout with no executable ./setup was handed to setup: $OUT"; fi
sleep 0.5
[ ! -s "$SETUP_LOG" ] || fail "setup ran for a checkout that is not the harness's"
ok "a repo the config dir does not lead into, and one with no executable ./setup, are never handed to setup"
echo "# $pass cases passed"
