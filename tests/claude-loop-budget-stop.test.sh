#!/usr/bin/env bash
# Hermetic tests for issue #562: a budget-killed claude-loop run must not
# report success. The loop-guard hard-stop (continue:false) makes `claude -p`
# exit 0, so the wrapper's ONLY view of the kill is the marker file the guard
# writes at $CLAUDE_LOOP_STOP_MARKER. This suite pins the wrapper's side of
# that seam — it exports the per-run path, the (stubbed) run writes it there,
# and the wrapper must read it back — plus every surface the issue's AC names:
# distinct nonzero exit, `stopped:"budget"` on the ledger's ended row, a
# stopped-not-done Discord message naming the worktree and its uncommitted
# state, and a wrapper log line naming uncommitted work. The hook's side
# (hardStop writes the marker; a soft deny does not) is pinned in
# hooks/tests/loop-guard.test.js.
#
# Stub layout mirrors discord-notify.test.sh: PATH-stubbed curl (health probe
# + Discord posts) and claude; stubbed cost/live-sessions seams for
# determinism; dispatcher-ledger.sh is REAL, hermetic purely via
# DISPATCHER_LEDGER_FILE, so the --stopped row lands through the actual
# append path, never a hand-rolled guess at it.
#
# Planted negative (contract-required, issue #562): B1 — a stubbed run that
# simulates the budget hard-stop with a dirty tree must NOT print the clean
# wrapper's exact "done. Review the work" text and must NOT exit 0. A wrong
# implementation that trusts claude's exit code false-passes both, because the
# stub — like a real hard-stopped claude — exits 0.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)  # repo root
LOOP="$HERE/bin/claude-loop.sh"
LEDGER="$HERE/scripts/dispatcher-ledger.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

pass=0 fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*" >&2; }

bash -n "$LOOP" || { echo "FAIL: $LOOP does not parse" >&2; exit 1; }
bash -n "$LEDGER" || { echo "FAIL: $LEDGER does not parse" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_CALLS:?}"
prev=""
for a in "$@"; do
  [ "$prev" = "-d" ] && printf '%s' "$a" > "${CURL_PAYLOAD:?}"
  prev="$a"
done
exit 0
STUB
chmod +x "$TMP/bin/curl"

cat >"$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CLAUDE_CALLS:?}"
# The loop-guard fences reach the hook through the child's environment, not
# its argv; record them so the wrapper's exported defaults can be pinned.
printf 'env:CLAUDE_LOOP_MAX=%s env:CLAUDE_LOOP_MAX_MS=%s\n' "${CLAUDE_LOOP_MAX:-unset}" "${CLAUDE_LOOP_MAX_MS:-unset}" >> "${CLAUDE_CALLS:?}"
# Simulate the agent editing files: cwd is the worktree (claude-loop cd's
# there before launching claude), so these land as uncommitted work.
if [ "${CLAUDE_STUB_DIRTY:-0}" -gt 0 ] 2>/dev/null; then
  i=1
  while [ "$i" -le "$CLAUDE_STUB_DIRTY" ]; do
    printf 'stranded work %s\n' "$i" > "stranded-$i.txt"
    i=$((i+1))
  done
fi
# Simulate delivered work (issue #583): a committing run moves HEAD past the
# start commit -- exactly what the wrapper's empty-delivery check reads. The
# byte-identical "clean run" control (B2) must commit, or it would now trip
# the empty-delivery surface by design.
if [ "${CLAUDE_STUB_COMMIT:-0}" = 1 ]; then
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "stub work"
fi
# Simulate the loop-guard hard-stop: the REAL guard writes a JSON marker at
# $CLAUDE_LOOP_STOP_MARKER (which the wrapper must have exported — the :?
# below is itself an assertion of that seam) and claude then exits 0. A
# continue:false hook stop is a CLEAN exit from the runtime's perspective;
# that exit-0 is the entire trap this suite exists to guard against.
if [ "${CLAUDE_STUB_BUDGET_STOP:-0}" = 1 ]; then
  printf '{"stopped":"budget","reason":"stub: 301 tool calls exceeds CLAUDE_LOOP_MAX=300"}\n' \
    > "${CLAUDE_LOOP_STOP_MARKER:?wrapper did not export CLAUDE_LOOP_STOP_MARKER}"
fi
# Simulate the guard's primary write FAILING (EISDIR/ENOSPC class) with only
# the state-dir fallback landing — the real guard writes both best-effort
# (issue #562 follow-up); the guard's own side of that seam is pinned in
# loop-guard.test.js. Here the wrapper must detect the stop from the fallback
# alone.
if [ "${CLAUDE_STUB_BUDGET_STOP_FALLBACK_ONLY:-0}" = 1 ]; then
  fb_dir="$HOME/.claude/.loop-state/stop-markers"
  mkdir -p "$fb_dir"
  printf '{"stopped":"budget","reason":"stub: fallback-only (primary write failed)"}\n' \
    > "$fb_dir/$(basename "${CLAUDE_LOOP_STOP_MARKER:?wrapper did not export CLAUDE_LOOP_STOP_MARKER}")"
fi
echo "stub claude ran"
exit "${CLAUDE_STUB_RC:-0}"
STUB
chmod +x "$TMP/bin/claude"

# Deterministic cost + live-sessions seams (real ones would probe the runner's
# ccflare DB / process table — variance this suite does not want).
cat >"$TMP/bin/cost-stub.py" <<'STUB'
print('{"window_cost_usd": 1.25, "tokens": 10}')
STUB
cat >"$TMP/bin/live-sessions-stub.js" <<'STUB'
console.log("[]");
STUB

export PATH="$TMP/bin:$PATH"
export CURL_CALLS="$TMP/curl-calls.log" CURL_PAYLOAD="$TMP/payload.json"
export CLAUDE_CALLS="$TMP/claude-calls.log"
export DISPATCHER_COST_BIN="$TMP/bin/cost-stub.py"
export LIVE_SESSIONS_BIN="$TMP/bin/live-sessions-stub.js"
export DISPATCHER_LEDGER_BIN="$LEDGER"
# Health probe: the curl stub exits 0 for every call, so `curl -sf .../health`
# passes and the run proceeds. Host string deliberately not "stub.invalid" so
# webhook-call greps can never count the health probe.
export ANTHROPIC_BASE_URL="https://ccflare.invalid"

git_q() { git -c user.email=t@t -c user.name=t -C "$1" "${@:2}"; }
mk_repo_with_origin() { # name -> prints "repo_path bare_path"
  local r=$TMP/$1 bare=$TMP/$1.git
  git init -q --bare "$bare"
  mkdir -p "$r"; git -C "$r" init -q -b main
  printf 'x\n' >"$r/f"; git_q "$r" add f; git_q "$r" commit -qm seed
  git_q "$r" remote add origin "$bare"
  git_q "$r" push -q origin main
  printf '%s %s\n' "$r" "$bare"
}
mk_worktree() { # repo branch -> prints worktree_path
  local r="$1"
  local br="$2"
  local wt="$TMP/wt-$br"
  git -C "$r" worktree add -q -b "$br" "$wt"
  echo "$wt"
}

echo "== B1 (PLANTED NEGATIVE): budget hard-stop + dirty tree must NOT look like success on ANY surface =="
export DISPATCHER_LEDGER_FILE="$TMP/b1.jsonl"
read -r R1 _BARE1 <<<"$(mk_repo_with_origin bs-b1)"
WT1=$(mk_worktree "$R1" budget-b1)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
OUTPUT=$(CLAUDE_STUB_BUDGET_STOP=1 CLAUDE_STUB_DIRTY=2 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R1" "test prompt" --use-worktree "$WT1" --run-id run-b1 2>&1); RC=$?
# Exit: nonzero, and specifically the wrapper's distinct budget-stop code —
# claude itself exited 0, so a pass here proves the wrapper substituted it.
[ "$RC" != 0 ] && ok || bad "B1 budget-stopped run exited 0 (the #558 lie)"
[ "$RC" = 97 ] && ok || bad "B1 exit $RC (want the distinct budget-stop code 97)"
# The exact clean-run string the #558 incident printed must be absent.
case "$OUTPUT" in
  *"done. Review the work"*) bad "B1 PLANTED NEGATIVE: budget-stopped run printed the clean-run done text:
$OUTPUT" ;;
  *) ok ;;
esac
case "$OUTPUT" in *"BUDGET-STOPPED"*) ok ;; *) bad "B1 output lacks BUDGET-STOPPED: $OUTPUT" ;; esac
case "$OUTPUT" in *"2 files modified but uncommitted"*) ok ;; *) bad "B1 output does not name the uncommitted work: $OUTPUT" ;; esac
# Wrapper log line naming uncommitted work (AC): the stopped/uncommitted lines
# are tee'd into the per-run log, not just stdout.
LOG1=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
{ [ -n "$LOG1" ] && grep -q "files modified but uncommitted" "$LOG1" 2>/dev/null; } && ok \
  || bad "B1 run log lacks the uncommitted-work line: log=$LOG1"
{ [ -n "$LOG1" ] && grep -q "BUDGET-STOPPED" "$LOG1" 2>/dev/null; } && ok \
  || bad "B1 run log lacks the BUDGET-STOPPED line: log=$LOG1"
# Discord: stopped-not-done, naming worktree + uncommitted state, never
# "finished OK". CURL_PAYLOAD holds the LAST -d body = the run-end notify.
CONTENT=$(jq -r .content "$CURL_PAYLOAD" 2>/dev/null)
grep -q "BUDGET-STOPPED" <<<"$CONTENT" && ok || bad "B1 Discord payload lacks BUDGET-STOPPED: $CONTENT"
grep -q "NOT done" <<<"$CONTENT" && ok || bad "B1 Discord payload does not say stopped-not-done: $CONTENT"
grep -qF "$WT1" <<<"$CONTENT" && ok || bad "B1 Discord payload does not name the worktree: $CONTENT"
grep -q "2 files modified but uncommitted" <<<"$CONTENT" && ok || bad "B1 Discord payload lacks the uncommitted state: $CONTENT"
grep -q "finished OK" <<<"$CONTENT" && bad "B1 Discord payload claims finished OK: $CONTENT" || ok
# Ledger: the ended row carries the budget-stop marker and the substituted exit.
ROW=$(jq -R -c 'fromjson? | select(.event=="ended" and .run_id=="run-b1")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
printf '%s' "$ROW" | jq -e '.stopped == "budget" and .exit == 97' >/dev/null 2>&1 && ok \
  || bad "B1 ended row lacks stopped:budget / exit 97: $ROW"

echo "== B2 (control): a genuinely clean, committing run's surfaces are byte-identical to before =="
export DISPATCHER_LEDGER_FILE="$TMP/b2.jsonl"
read -r R2 _BARE2 <<<"$(mk_repo_with_origin bs-b2)"
WT2=$(mk_worktree "$R2" budget-b2)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
OUTPUT=$(CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  ANTHROPIC_BASE_URL=http://127.0.0.1:8788 ANTHROPIC_MODEL= ANTHROPIC_CUSTOM_HEADERS= \
  bash "$LOOP" "$R2" "test prompt" --use-worktree "$WT2" --run-id run-b2 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "B2 clean run exit $RC (want 0)"
# The exact pre-#562 done line, unchanged.
case "$OUTPUT" in
  *"==> done. Review the work, then merge or discard:"*) ok ;;
  *) bad "B2 clean run lost its exact done line:
$OUTPUT" ;;
esac
case "$OUTPUT" in *"BUDGET-STOPPED"*) bad "B2 clean run printed BUDGET-STOPPED" ;; *) ok ;; esac
case "$OUTPUT" in *"modified but uncommitted"*) bad "B2 clean run claimed uncommitted work" ;; *) ok ;; esac
CONTENT=$(jq -r .content "$CURL_PAYLOAD" 2>/dev/null)
[ ! -s "$CURL_PAYLOAD" ] && ok || bad "A1728-routine-start-finishedOK must be silent: $CONTENT"
LOG2=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
grep -q "finished OK" "$LOG2" && ok || bad "A1728 routine completion must remain logged"
# A clean ended row must NOT grow a stopped key (shape unchanged).
ROW=$(jq -R -c 'fromjson? | select(.event=="ended" and .run_id=="run-b2")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
printf '%s' "$ROW" | jq -e '(has("stopped") | not) and .exit == 0' >/dev/null 2>&1 && ok \
  || bad "B2 clean ended row wrong (stopped key present, or exit != 0): $ROW"
# Issue #583: a committing run's row and surfaces are untouched by the
# empty-delivery backstop.
printf '%s' "$ROW" | jq -e 'has("empty") | not' >/dev/null 2>&1 && ok \
  || bad "B2 clean committing ended row grew an empty key: $ROW"
case "$OUTPUT" in *"no commits produced"*) bad "B2 clean committing run claimed no commits produced: $OUTPUT" ;; *) ok ;; esac
# The wrapper passes its compiled-in $60 default to claude when no env is set.
grep -q -- "--max-budget-usd 60" "$CLAUDE_CALLS" && ok \
  || bad "B2 claude argv lacks the default --max-budget-usd 60 (issue #562 amendment): $(cat "$CLAUDE_CALLS")"
# A dispatched child may mark its PR ready but never merge it (dotfiles#965):
# the merge tool is disallowed on the child's argv, alongside force-push.
grep -q -F -- "Bash(gh pr merge:*)" "$CLAUDE_CALLS" && ok \
  || bad "B2 claude argv lacks the child merge disallow Bash(gh pr merge:*) (dotfiles#965): $(cat "$CLAUDE_CALLS")"
grep -q -F -- "Bash(git push --force:*)" "$CLAUDE_CALLS" && ok \
  || bad "B2 claude argv lost the force-push disallow: $(cat "$CLAUDE_CALLS")"
# Thinking display stays visible in dispatched runs (dotfiles#1225): without
# an explicit display the upstream streams empty thinking deltas, the gateway
# sees no progress, and a step that thinks past ~450s is killed
# (better-ccflare#356). Only the CLI flag reaches the launch-time decision.
grep -q -F -- '--thinking-display summarized' "$CLAUDE_CALLS" && ok \
  || bad "B2 claude argv lacks --thinking-display summarized (dotfiles#1225): $(cat "$CLAUDE_CALLS")"
# Default dispatched roots enroll in gateway Auto, not the operator's picker pin.
grep -q -F -- '--model claude-bccf-quality-auto' "$CLAUDE_CALLS" && ok \
  || bad "B2 gateway-targeted headless root did not enroll in Auto: $(cat "$CLAUDE_CALLS")"
# Runaway fences (dotfiles#968): 1000 tool calls and three hours reach the
# child's environment when no per-run override is set. 300 calls refused the
# #481 run's own commit with its work verified on disk.
grep -q -F -- "env:CLAUDE_LOOP_MAX=1000 env:CLAUDE_LOOP_MAX_MS=10800000" "$CLAUDE_CALLS" && ok \
  || bad "B2 child env lacks the default loop-guard fences 1000 calls / 10800000 ms (dotfiles#968): $(grep 'env:CLAUDE_LOOP' "$CLAUDE_CALLS")"

echo "== B3: a clean-exit run with a dirty tree never reports a bare done =="
export DISPATCHER_LEDGER_FILE="$TMP/b3.jsonl"
read -r R3 _BARE3 <<<"$(mk_repo_with_origin bs-b3)"
WT3=$(mk_worktree "$R3" budget-b3)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
OUTPUT=$(CLAUDE_STUB_DIRTY=2 CLAUDE_LOOP_MAX_USD=33.5 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R3" "test prompt" --use-worktree "$WT3" --run-id run-b3 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "B3 exit $RC (dirty-but-clean run is still exit 0 — visibility, not failure)"
case "$OUTPUT" in
  *"done — but 2 files modified but uncommitted"*) ok ;;
  *) bad "B3 dirty done message missing:
$OUTPUT" ;;
esac
case "$OUTPUT" in *"Review the work, then merge or discard:"*) ok ;; *) bad "B3 review/merge instructions vanished: $OUTPUT" ;; esac
case "$OUTPUT" in *"BUDGET-STOPPED"*) bad "B3 dirty-but-clean run printed BUDGET-STOPPED" ;; *) ok ;; esac
CONTENT=$(jq -r .content "$CURL_PAYLOAD" 2>/dev/null)
grep -q "finished OK" <<<"$CONTENT" && ok || bad "B3 Discord payload lacks finished OK: $CONTENT"
grep -q "2 files modified but uncommitted" <<<"$CONTENT" && ok \
  || bad "B3 Discord payload does not warn about the uncommitted work: $CONTENT"
ROW=$(jq -R -c 'fromjson? | select(.event=="ended" and .run_id=="run-b3")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
printf '%s' "$ROW" | jq -e 'has("stopped") | not' >/dev/null 2>&1 && ok \
  || bad "B3 dirty-but-clean ended row must not carry a stopped key: $ROW"
# The per-run env override still reaches claude's argv (decimals allowed).
grep -q -- "--max-budget-usd 33.5" "$CLAUDE_CALLS" && ok \
  || bad "B3 claude argv lacks the CLAUDE_LOOP_MAX_USD=33.5 override: $(cat "$CLAUDE_CALLS")"

echo "== B4 (issue #562 follow-up): a failed PRIMARY marker write must not resurrect the false success =="
# The refute-lens EISDIR probe: hard stop fired, primary marker never landed,
# wrapper printed the clean done text with exit 0. The guard now also writes a
# state-dir fallback; the wrapper must detect the stop from that path alone.
export DISPATCHER_LEDGER_FILE="$TMP/b4.jsonl"
read -r R4 _BARE4 <<<"$(mk_repo_with_origin bs-b4)"
WT4=$(mk_worktree "$R4" budget-b4)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
OUTPUT=$(CLAUDE_STUB_BUDGET_STOP_FALLBACK_ONLY=1 CLAUDE_STUB_DIRTY=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R4" "test prompt" --use-worktree "$WT4" --run-id run-b4 2>&1); RC=$?
[ "$RC" = 97 ] && ok || bad "B4 fallback-only stop exited $RC (want 97 — primary-write failure must not read as success)"
case "$OUTPUT" in
  *"done. Review the work"*) bad "B4 fallback-only stop printed the clean done text (the EISDIR false-success)" ;;
  *) ok ;;
esac
case "$OUTPUT" in *"BUDGET-STOPPED"*) ok ;; *) bad "B4 output lacks BUDGET-STOPPED: $OUTPUT" ;; esac
ROW=$(jq -R -c 'fromjson? | select(.event=="ended" and .run_id=="run-b4")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
printf '%s' "$ROW" | jq -e '.stopped == "budget"' >/dev/null 2>&1 && ok \
  || bad "B4 ended row lacks stopped:budget: $ROW"
# Consumed on read: the fallback dir must not accumulate this run's marker.
FB4="$HOME/.claude/.loop-state/stop-markers"
if ls "$FB4" 2>/dev/null | grep -q "budget-b4"; then
  bad "B4 fallback marker not cleaned up after a positive read"
else
  ok
fi

echo "== B5 (issue #562 follow-up): same-second launches can no longer share a marker path =="
# The refute-lens collision probe: LOG was repo+branch+seconds, so run B's
# pre-clear erased run A's marker and A reported clean. LOG now embeds run id
# + pid; two same-second runs with identical repo basename AND branch name
# must produce distinct logs and BOTH report their stops.
export DISPATCHER_LEDGER_FILE="$TMP/b5.jsonl"
mkdir -p "$TMP/x" "$TMP/y"
git init -q --bare "$TMP/x/bs-b5.git"; git init -q --bare "$TMP/y/bs-b5.git"
mkdir -p "$TMP/x/bs-b5" "$TMP/y/bs-b5"
for d in "$TMP/x/bs-b5" "$TMP/y/bs-b5"; do
  git -C "$d" init -q -b main
  git -c user.email=t@t -c user.name=t -C "$d" commit -q --allow-empty -m init
  git -C "$d" remote add origin "$d.git"
  git -C "$d" push -q origin main
done
WT5A=$(cd "$TMP/x/bs-b5" && git worktree add -q -b budget-b5 "$TMP/x/wt-b5" >/dev/null 2>&1; echo "$TMP/x/wt-b5")
WT5B=$(cd "$TMP/y/bs-b5" && git worktree add -q -b budget-b5 "$TMP/y/wt-b5" >/dev/null 2>&1; echo "$TMP/y/wt-b5")
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
OUT_A_FILE="$TMP/b5-a.out"; OUT_B_FILE="$TMP/b5-b.out"
CLAUDE_STUB_BUDGET_STOP=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$TMP/x/bs-b5" "test prompt" --use-worktree "$WT5A" --run-id run-b5a >"$OUT_A_FILE" 2>&1 &
PID_A=$!
CLAUDE_STUB_BUDGET_STOP=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$TMP/y/bs-b5" "test prompt" --use-worktree "$WT5B" --run-id run-b5b >"$OUT_B_FILE" 2>&1 &
PID_B=$!
RC_A=0; RC_B=0
wait "$PID_A" || RC_A=$?
wait "$PID_B" || RC_B=$?
[ "$RC_A" = 97 ] && ok || bad "B5 run A exited $RC_A (want 97 — its stop marker was erased?)"
[ "$RC_B" = 97 ] && ok || bad "B5 run B exited $RC_B (want 97)"
LOG_A=$(sed -n 's/^==> log:[[:space:]]*//p' "$OUT_A_FILE"); LOG_B=$(sed -n 's/^==> log:[[:space:]]*//p' "$OUT_B_FILE")
{ [ -n "$LOG_A" ] && [ -n "$LOG_B" ] && [ "$LOG_A" != "$LOG_B" ]; } && ok \
  || bad "B5 log paths must be distinct for same-second same-name launches: A=$LOG_A B=$LOG_B"
ROWS=$(jq -R -c 'fromjson? | select(.event=="ended" and .stopped=="budget")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null | wc -l | tr -d '[:space:]')
[ "$ROWS" = 2 ] && ok || bad "B5 want 2 budget-stopped ended rows, got $ROWS"

echo
echo "claude-loop-budget-stop: $pass passed, $fail failed"
[ "$fail" = 0 ]
