#!/usr/bin/env bash
# Hermetic tests for issue #583: a run cut short by Claude Code's
# background-task ceiling must not report success, and a run that delivers no
# commits must say so on every surface — the empty-delivery backstop that
# catches the NEXT unknown kill path without enumerating it.
#
# The incident (run issue-279-1787912111, better-ccflare#279, 2026-08-28):
# the SDK terminated the run with "Background tasks still running after 600s;
# terminating", claude exited 0, zero commits existed on the branch, and the
# wrapper printed "done. Review the work" over an empty PR with a clean
# `ended` ledger row. Nothing anywhere said the run was cut off. There is no
# structured signal for this kill the wrapper can reach (neither observed
# kill left ANY transcript record), so the tee'd log string is the seam.
#
# Stub layout mirrors claude-loop-budget-stop.test.sh: PATH-stubbed curl
# (health probe + Discord posts) and claude; stubbed cost/live-sessions
# seams; dispatcher-ledger.sh is REAL, hermetic purely via
# DISPATCHER_LEDGER_FILE, so stopped:"background-tasks" and empty:true land
# through the actual append path, never a hand-rolled guess at it.
#
# Planted negatives (contract-required, issue #583 — both false-pass against
# the pre-#583 wrapper; run issue-279-1787912111 did exactly this):
#   C1 — a stubbed run whose output contains the ceiling line and which makes
#        no commits must NOT print "done. Review the work" and must NOT exit 0.
#   C2 — a stubbed CLEAN run that simply commits nothing must trip the
#        empty-delivery check ("no commits produced" on every surface,
#        empty:true on the ledger row) while still exiting 0.
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
# Record the ceiling env the wrapper handed us (issue #583 scope item 5): the
# raised default must actually reach claude's environment.
if [ -n "${CEILING_CHECK_FILE:-}" ]; then
  printf '%s' "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-UNSET}" > "$CEILING_CHECK_FILE"
fi
# Simulate delivered work: a committing run moves HEAD past the start commit
# (cwd is the worktree — claude-loop cd's there before launching claude).
if [ "${CLAUDE_STUB_COMMIT:-0}" = 1 ]; then
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "stub work"
fi
if [ "${CLAUDE_STUB_DIRTY:-0}" -gt 0 ] 2>/dev/null; then
  i=1
  while [ "$i" -le "$CLAUDE_STUB_DIRTY" ]; do
    printf 'stranded work %s\n' "$i" > "stranded-$i.txt"
    i=$((i+1))
  done
fi
# A run that merely TALKS ABOUT the ceiling message mid-line (a run working
# on the wrapper itself, say) must not read as killed — the wrapper's grep
# is anchored to line start.
if [ "${CLAUDE_STUB_MENTION:-0}" = 1 ]; then
  echo "investigating the 'Background tasks still running after' kill path"
  echo "Background tasks still running after a hook stop is a different beast"
fi
echo "stub claude ran"
# Simulate the SDK's background-task ceiling termination: the message is the
# CLI's own line on the merged output stream, and the process then exits 0
# (verified on run issue-279-1787912111 — that exit 0 is the entire trap
# this suite exists to guard against).
if [ "${CLAUDE_STUB_BG_KILL:-0}" = 1 ]; then
  echo "Background tasks still running after 600s; terminating. Set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 to wait indefinitely."
fi
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

echo "== C1 (PLANTED NEGATIVE): bg-ceiling kill + no commits must NOT look like success on ANY surface =="
export DISPATCHER_LEDGER_FILE="$TMP/c1.jsonl"
read -r R1 _BARE1 <<<"$(mk_repo_with_origin cs-c1)"
WT1=$(mk_worktree "$R1" cut-c1)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
OUTPUT=$(CLAUDE_STUB_BG_KILL=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R1" "test prompt" --use-worktree "$WT1" --run-id run-c1 2>&1); RC=$?
[ "$RC" != 0 ] && ok || bad "C1 bg-ceiling-killed run exited 0 (the issue-279 lie)"
[ "$RC" = 96 ] && ok || bad "C1 exit $RC (want the distinct cut-short code 96)"
case "$OUTPUT" in
  *"done. Review the work"*) bad "C1 PLANTED NEGATIVE: bg-ceiling-killed run printed the clean-run done text:
$OUTPUT" ;;
  *) ok ;;
esac
case "$OUTPUT" in *"CUT-SHORT (background-tasks)"*) ok ;; *) bad "C1 output lacks CUT-SHORT (background-tasks): $OUTPUT" ;; esac
case "$OUTPUT" in *"no commits produced"*) ok ;; *) bad "C1 output lacks no-commits-produced: $OUTPUT" ;; esac
LOG1=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
{ [ -n "$LOG1" ] && grep -q "CUT-SHORT (background-tasks)" "$LOG1" 2>/dev/null; } && ok \
  || bad "C1 run log lacks the CUT-SHORT line: log=$LOG1"
{ [ -n "$LOG1" ] && grep -q "no commits produced" "$LOG1" 2>/dev/null; } && ok \
  || bad "C1 run log lacks the no-commits line: log=$LOG1"
CONTENT=$(jq -r .content "$CURL_PAYLOAD" 2>/dev/null)
grep -qF "CUT-SHORT (background-tasks)" <<<"$CONTENT" && ok || bad "C1 Discord payload lacks CUT-SHORT (background-tasks): $CONTENT"
grep -q "NOT done" <<<"$CONTENT" && ok || bad "C1 Discord payload does not say stopped-not-done: $CONTENT"
grep -q "no commits produced" <<<"$CONTENT" && ok || bad "C1 Discord payload lacks no-commits-produced: $CONTENT"
grep -q "finished OK" <<<"$CONTENT" && bad "C1 Discord payload claims finished OK: $CONTENT" || ok
ROW=$(jq -R -c 'fromjson? | select(.event=="ended" and .run_id=="run-c1")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
printf '%s' "$ROW" | jq -e '.stopped == "background-tasks" and .empty == true and .exit == 96' >/dev/null 2>&1 && ok \
  || bad "C1 ended row lacks stopped:background-tasks / empty:true / exit 96: $ROW"

echo "== C2 (PLANTED NEGATIVE): a clean run that commits nothing trips the empty-delivery backstop; exit stays 0 =="
export DISPATCHER_LEDGER_FILE="$TMP/c2.jsonl"
read -r R2 _BARE2 <<<"$(mk_repo_with_origin cs-c2)"
WT2=$(mk_worktree "$R2" cut-c2)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
OUTPUT=$(DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R2" "test prompt" --use-worktree "$WT2" --run-id run-c2 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "C2 empty clean run exit $RC (want 0 — visibility, not failure)"
case "$OUTPUT" in
  *"==> done. Review the work, then merge or discard:"*) bad "C2 PLANTED NEGATIVE: empty run printed the clean done text:
$OUTPUT" ;;
  *) ok ;;
esac
case "$OUTPUT" in *"no commits produced"*) ok ;; *) bad "C2 output lacks no-commits-produced: $OUTPUT" ;; esac
case "$OUTPUT" in *"CUT-SHORT"*|*"BUDGET-STOPPED"*) bad "C2 empty-but-uncut run printed a cut-short surface: $OUTPUT" ;; *) ok ;; esac
LOG2=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
{ [ -n "$LOG2" ] && grep -q "no commits produced" "$LOG2" 2>/dev/null; } && ok \
  || bad "C2 run log lacks the no-commits line: log=$LOG2"
CONTENT=$(jq -r .content "$CURL_PAYLOAD" 2>/dev/null)
grep -q "finished OK" <<<"$CONTENT" && ok || bad "C2 Discord payload lacks finished OK (empty is visibility, not failure): $CONTENT"
grep -q "no commits produced" <<<"$CONTENT" && ok || bad "C2 Discord payload lacks no-commits-produced: $CONTENT"
ROW=$(jq -R -c 'fromjson? | select(.event=="ended" and .run_id=="run-c2")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
printf '%s' "$ROW" | jq -e '.empty == true and (has("stopped") | not) and .exit == 0' >/dev/null 2>&1 && ok \
  || bad "C2 ended row lacks empty:true (or grew stopped / nonzero exit): $ROW"

echo "== C3 (control): a committing clean run's surfaces stay byte-identical; the raised bg ceiling reaches claude's env =="
export DISPATCHER_LEDGER_FILE="$TMP/c3.jsonl"
read -r R3 _BARE3 <<<"$(mk_repo_with_origin cs-c3)"
WT3=$(mk_worktree "$R3" cut-c3)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
OUTPUT=$(CLAUDE_STUB_COMMIT=1 CEILING_CHECK_FILE="$TMP/ceiling-c3" DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R3" "test prompt" --use-worktree "$WT3" --run-id run-c3 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "C3 clean committing run exit $RC (want 0)"
case "$OUTPUT" in
  *"==> done. Review the work, then merge or discard:"*) ok ;;
  *) bad "C3 clean committing run lost its exact done line:
$OUTPUT" ;;
esac
case "$OUTPUT" in *"no commits produced"*|*"CUT-SHORT"*|*"BUDGET-STOPPED"*) bad "C3 clean committing run printed a warn surface: $OUTPUT" ;; *) ok ;; esac
CONTENT=$(jq -r .content "$CURL_PAYLOAD" 2>/dev/null)
[ ! -s "$CURL_PAYLOAD" ] && ok || bad "C3 routine completion must remain silent: $CONTENT"
LOG3=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
grep -q "finished OK" "$LOG3" && ok || bad "C3 routine completion must remain logged"
grep -q "no commits produced" <<<"$CONTENT" && bad "C3 Discord payload wrongly claims no commits: $CONTENT" || ok
ROW=$(jq -R -c 'fromjson? | select(.event=="ended" and .run_id=="run-c3")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
printf '%s' "$ROW" | jq -e '(has("stopped") | not) and (has("empty") | not) and .exit == 0' >/dev/null 2>&1 && ok \
  || bad "C3 clean committing ended row grew stopped/empty keys: $ROW"
# Scope item 5: with nothing pre-set, the wrapper aligns the SDK's bg-wait
# ceiling with the wall-clock fence default, not the stock 600s. The default
# is three hours since dotfiles#968 (was one hour); the pin follows the fence.
[ "$(cat "$TMP/ceiling-c3" 2>/dev/null)" = "10800000" ] && ok \
  || bad "C3 claude env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=$(cat "$TMP/ceiling-c3" 2>/dev/null) (want 10800000)"

echo "== C4: a bg-ceiling kill AFTER commits landed is cut-short (not empty), and the commits still reach the PR =="
export DISPATCHER_LEDGER_FILE="$TMP/c4.jsonl"
read -r R4 BARE4 <<<"$(mk_repo_with_origin cs-c4)"
WT4=$(mk_worktree "$R4" cut-c4)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
OUTPUT=$(CLAUDE_STUB_BG_KILL=1 CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R4" "test prompt" --use-worktree "$WT4" --run-id run-c4 2>&1); RC=$?
[ "$RC" = 96 ] && ok || bad "C4 exit $RC (want 96)"
case "$OUTPUT" in *"CUT-SHORT (background-tasks)"*) ok ;; *) bad "C4 output lacks CUT-SHORT: $OUTPUT" ;; esac
case "$OUTPUT" in *"no commits produced"*) bad "C4 committing run wrongly claimed no commits produced: $OUTPUT" ;; *) ok ;; esac
ROW=$(jq -R -c 'fromjson? | select(.event=="ended" and .run_id=="run-c4")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
printf '%s' "$ROW" | jq -e '.stopped == "background-tasks" and (has("empty") | not)' >/dev/null 2>&1 && ok \
  || bad "C4 ended row wrong (want stopped:background-tasks, no empty key): $ROW"
# The kill must not strand the delivered commits: the post-run push still ran.
WANT_SHA=$(git -C "$WT4" rev-parse HEAD)
GOT_SHA=$(git -C "$BARE4" rev-parse cut-c4 2>/dev/null)
{ [ -n "$WANT_SHA" ] && [ "$WANT_SHA" = "$GOT_SHA" ]; } && ok \
  || bad "C4 commits did not reach the origin branch (want $WANT_SHA got $GOT_SHA)"

echo "== C5: a pre-set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS wins over the aligned default =="
export DISPATCHER_LEDGER_FILE="$TMP/c5.jsonl"
read -r R5 _BARE5 <<<"$(mk_repo_with_origin cs-c5)"
WT5=$(mk_worktree "$R5" cut-c5)
: >"$CLAUDE_CALLS"
CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=1234 CLAUDE_STUB_COMMIT=1 CEILING_CHECK_FILE="$TMP/ceiling-c5" \
  DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R5" "test prompt" --use-worktree "$WT5" --run-id run-c5 >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "C5 exit $RC"
[ "$(cat "$TMP/ceiling-c5" 2>/dev/null)" = "1234" ] && ok \
  || bad "C5 pre-set ceiling did not win: $(cat "$TMP/ceiling-c5" 2>/dev/null)"

echo "== C5b (inward vet): a pre-set ceiling of 0 (wait forever) is overridden to the wall-clock value =="
export DISPATCHER_LEDGER_FILE="$TMP/c5b.jsonl"
read -r R5B _BARE5B <<<"$(mk_repo_with_origin cs-c5b)"
WT5B=$(mk_worktree "$R5B" cut-c5b)
: >"$CLAUDE_CALLS"
CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 CLAUDE_STUB_COMMIT=1 CEILING_CHECK_FILE="$TMP/ceiling-c5b" \
  DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R5B" "test prompt" --use-worktree "$WT5B" --run-id run-c5b >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "C5b exit $RC"
[ "$(cat "$TMP/ceiling-c5b" 2>/dev/null)" = "10800000" ] && ok \
  || bad "C5b ceiling=0 (unfenced idle wait) was not overridden: $(cat "$TMP/ceiling-c5b" 2>/dev/null) (want 10800000)"

echo "== C6: a run that merely mentions the ceiling string is NOT read as killed (mid-line AND bare column-0 prefix) =="
export DISPATCHER_LEDGER_FILE="$TMP/c6.jsonl"
read -r R6 _BARE6 <<<"$(mk_repo_with_origin cs-c6)"
WT6=$(mk_worktree "$R6" cut-c6)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
OUTPUT=$(CLAUDE_STUB_MENTION=1 CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R6" "test prompt" --use-worktree "$WT6" --run-id run-c6 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "C6 exit $RC (a mid-line mention must not read as a kill)"
case "$OUTPUT" in *"CUT-SHORT"*) bad "C6 mid-line mention tripped the cut-short detector: $OUTPUT" ;; *) ok ;; esac
ROW=$(jq -R -c 'fromjson? | select(.event=="ended" and .run_id=="run-c6")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
printf '%s' "$ROW" | jq -e 'has("stopped") | not' >/dev/null 2>&1 && ok || bad "C6 row grew a stopped key: $ROW"

echo "== C7 (move 7): an empty-delivery run still pushes (a bare ref move), the log says no PR was opened, and nothing is recorded as a PR =="
export DISPATCHER_LEDGER_FILE="$TMP/c7.jsonl"
read -r R7 _BARE7 <<<"$(mk_repo_with_origin cs-c7)"
WT7=$(mk_worktree "$R7" cut-c7)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
OUTPUT=$(DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R7" "test prompt" --use-worktree "$WT7" --run-id run-c7 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "C7 empty clean run exit $RC (want 0 -- visibility, not failure)"
case "$OUTPUT" in *"no commits produced"*) ok ;; *) bad "C7 output lacks no-commits-produced: $OUTPUT" ;; esac
ROW=$(jq -R -c 'fromjson? | select(.event=="ended" and .run_id=="run-c7")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
printf '%s' "$ROW" | jq -e '.empty == true and (has("stopped") | not) and .exit == 0' >/dev/null 2>&1 && ok \
  || bad "C7 ended row lacks empty:true (or grew stopped / nonzero exit): $ROW"
PR_OPENED_ROW=$(jq -R -c 'fromjson? | select(.run_id=="run-c7" and .event=="pr-opened")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
[ -z "$PR_OPENED_ROW" ] && ok || bad "C7 no pr-opened row should exist: nothing opens a PR after a --use-worktree push: $PR_OPENED_ROW"
LOG7=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
{ [ -n "$LOG7" ] && grep -q -F "==> pushed cut-c7; no PR opened (open one with: gh pr create --head cut-c7)" "$LOG7" 2>/dev/null; } && ok || bad "C7 run log must say the push opened no PR: log=$LOG7"
{ [ -n "$LOG7" ] && grep -q -F "tracking PR" "$LOG7" 2>/dev/null; } && bad "C7 run log claims a tracking PR over a no-content outcome: log=$LOG7" || ok

echo
echo '== A1728-unhandled-stop: committing worker terminated mid-task must still notify =='
read -r RA _BAREA <<<"$(mk_repo_with_origin cs-a1728)"
WTA=$(mk_worktree "$RA" cut-a1728)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"
OUTPUT=$(CLAUDE_STUB_COMMIT=1 CLAUDE_STUB_BG_KILL=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$RA" "test prompt" --use-worktree "$WTA" --run-id run-a1728 2>&1); RC=$?
[ "$RC" = 96 ] && ok || bad "A1728 unhandled stop exit $RC"
CONTENT=$(jq -r .content "$CURL_PAYLOAD" 2>/dev/null)
grep -q 'NOT done' <<<"$CONTENT" && ok || bad 'A1728 unhandled stop must remain visible even after commits'

echo "claude-loop-cut-short: $pass passed, $fail failed"
[ "$fail" = 0 ]
