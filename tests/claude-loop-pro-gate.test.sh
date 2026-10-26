#!/usr/bin/env bash
# Hermetic tests for the wrapper side of dotfiles#985: claude-loop.sh runs the
# pro-gate loop (scripts/pro-gate-loop.sh, stubbed here) after the
# child has pushed, and only then. Same stub scaffolding as the cut-short
# suite: PATH-stubbed curl and claude, a bare-repo origin, deterministic
# cost/live-sessions seams, plus a gh stub for the PR lookup and a gate stub
# that records its argv and exits with a scripted code.
#
# Planted negatives (each false-passing against a wrapper that gated
# unconditionally):
#   W2  the switch off: the loop is never invoked
#   W3  a dirty tree: never invoked (a reviewer must not be charged for work
#       that is not on the PR)
#   W4  an empty branch: never invoked
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
echo "stub claude ran"
exit 0
STUB
chmod +x "$TMP/bin/claude"

# The wrapper looks the PR up by branch; the stub answers from an env fixture
# so "no open PR" is one export away.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:?}"
case "$*" in
  "pr list"*)
    [ "${GH_STUB_PR_FAIL:-0}" = 0 ] || { echo "fixture PR lookup failed" >&2; exit 1; }
    # Honor the requested projection, including the real jq expression, so
    # the fixture catches a broken number/URL pair instead of preformatting it.
    fields="" query="" prev=""
    for arg in "$@"; do
      [ "$prev" != --json ] || fields="$arg"
      [ "$prev" != --jq ] || query="$arg"
      prev="$arg"
    done
    jq -nr --arg number "${GH_STUB_PR_NUMBER:-}" \
      --arg url "https://github.com/Org/repo/pull/${GH_STUB_PR_NUMBER:-}" --arg fields "$fields" '
      if $number == "" then [] else
        [{number:($number | tonumber),url:$url} | with_entries(select(.key as $key | $fields | split(",") | index($key)))]
      end' | jq -r "$query"
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"

cat >"$TMP/bin/gate-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GATE_CALLS:?}"
echo "gate stub ran in $(pwd)"
if [ -n "${GATE_STUB_PROOF:-}" ] && [ -n "${3:-}" ]; then
  head=$(git -C "$1" rev-parse HEAD)
  origin=$(git -C "$1" remote get-url origin); origin=${origin%.git}
  repo=${origin##*/}; owner=${origin%/*}; owner=${owner##*/}
  mkdir -p "$3/q1"
  jq -n --arg head "$head" --argjson pr "$2" --arg owner "$owner" --arg repo "$repo" '
    {contract:{contract_id:"review-decision/v1",contract_version:1},
     action:"stop-without-new-review",reason:"rounds-not-converging",
     facts:{target:{head_oid:$head,pr:$pr,owner:$owner,repo:$repo},
       completed_results:[{canonical_identity:"fixture-result",charged_spend_epoch:1,
         verdict:"SHIP",applicable:true,legacy:false,binding_valid:true,
         provenance_valid:true,bindable:true,collected:true,
         marker:"pg-run-fixture",artifact_digest:("a" * 64),evidence_mode:"full-pr"}]}}
  ' > "$3/q1/decision.json"
  case "$GATE_STUB_PROOF" in
    full) filter='.facts.completed_results[0] += {marker:"pg-run-fixture",artifact_digest:("a" * 64),evidence_mode:"full-pr"}' ;;
    invalid-*) field=${GATE_STUB_PROOF#invalid-}; filter=".facts.completed_results[0].$field = false" ;;
    omit-*) filter="del(.facts.completed_results[0].${GATE_STUB_PROOF#omit-})" ;;
    legacy) filter='.facts.completed_results[0].legacy = true' ;;
    wrong-pr) filter='.facts.target.pr = 999' ;;
    wrong-owner) filter='.facts.target.owner = "wrong"' ;;
    wrong-repo) filter='.facts.target.repo = "wrong"' ;;
    no-identity) filter='del(.facts.completed_results[0].canonical_identity)' ;;
    no-epoch) filter='del(.facts.completed_results[0].charged_spend_epoch)' ;;
    bad-epoch) filter='.facts.completed_results[0].charged_spend_epoch = "later"' ;;
    bad-applicable) filter='.facts.completed_results[0].applicable = "true"' ;;
    bad-marker) filter='.facts.completed_results[0].marker = "bad marker"' ;;
    bad-digest) filter='.facts.completed_results[0].artifact_digest = "bad"' ;;
    latest-critical) filter='.facts.completed_results += [(.facts.completed_results[0] | .charged_spend_epoch = 2 | .canonical_identity = "newer" | .verdict = "FIX-FIRST")]' ;;
    latest-incomplete) filter='.facts.completed_results += [(.facts.completed_results[0] | .charged_spend_epoch = 2 | .canonical_identity = "newer" | .collected = false)]' ;;
    same-epoch) filter='.facts.completed_results += [(.facts.completed_results[0] | .canonical_identity = "aaa" | .verdict = "FIX-FIRST")]' ;;
    malformed-sibling) filter='.facts.completed_results += [{}]' ;;
    stale) jq '.facts.target.head_oid = "0000000000000000000000000000000000000000"' "$3/q1/decision.json" > "$3/q1/tmp"; mv "$3/q1/tmp" "$3/q1/decision.json" ;;
    critical) jq '.facts.completed_results[0].verdict = "FIX-FIRST"' "$3/q1/decision.json" > "$3/q1/tmp"; mv "$3/q1/tmp" "$3/q1/decision.json"
      mkdir -p "$HOME/.pro-review-daemon/rounds"; printf '1\t0\t0\n' > "$HOME/.pro-review-daemon/rounds/$owner-$repo-$2.last" ;;
    missing) mkdir -p "$3/q2" ;;
    malformed) printf '{' > "$3/q1/decision.json" ;;
  esac
  if [ -n "${filter:-}" ]; then
    jq "$filter" "$3/q1/decision.json" > "$3/q1/tmp"
    mv "$3/q1/tmp" "$3/q1/decision.json"
  fi
fi
case "${GATE_STUB_WORK:-}" in
  dirty) printf 'unfinished fix\n' > "$1/unfinished-fix.txt" ;;
  unpublished) git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'unpublished gate fix' ;;
  status-error|remote-error) printf '%s\n' "$GATE_STUB_WORK" > "${GIT_FAIL_MARKER:?}" ;;
esac
exit "${GATE_STUB_RC:-0}"
STUB
chmod +x "$TMP/bin/gate-stub.sh"

export REAL_GIT
REAL_GIT=$(command -v git)
export GIT_FAIL_MARKER="$TMP/git-fail"
cat >"$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ -f "$GIT_FAIL_MARKER" ]; then
  fault=$(<"$GIT_FAIL_MARKER")
  case "$fault:$*" in
    status-error:*'status --porcelain'*|remote-error:*'ls-remote'*) echo 'fixture git query failed' >&2; exit 1 ;;
  esac
fi
exec "$REAL_GIT" "$@"
STUB
chmod +x "$TMP/bin/git"

cat >"$TMP/bin/cost-stub.py" <<'STUB'
print('{"window_cost_usd": 1.25, "tokens": 10}')
STUB
cat >"$TMP/bin/live-sessions-stub.js" <<'STUB'
console.log("[]");
STUB

export PATH="$TMP/bin:$PATH"
export CURL_CALLS="$TMP/curl-calls.log" CURL_PAYLOAD="$TMP/payload.json"
export CLAUDE_CALLS="$TMP/claude-calls.log" GH_CALLS="$TMP/gh-calls.log" GATE_CALLS="$TMP/gate-calls.log"
export DISPATCHER_COST_BIN="$TMP/bin/cost-stub.py"
export LIVE_SESSIONS_BIN="$TMP/bin/live-sessions-stub.js"
export DISPATCHER_LEDGER_BIN="$LEDGER"
export PRO_GATE_LOOP_BIN="$TMP/bin/gate-stub.sh"
export ANTHROPIC_BASE_URL="https://ccflare.invalid"

git_q() { git -c user.email=t@t -c user.name=t -C "$1" "${@:2}"; }
mk_repo_with_origin() { # name -> prints "repo_path bare_path"
  local r=$TMP/$1 bare=$TMP/fixture-owner/$1.git
  mkdir -p "$TMP/fixture-owner"
  git init -q --bare "$bare"
  mkdir -p "$r"; git -C "$r" init -q -b main
  printf 'x\n' >"$r/f"; git_q "$r" add f; git_q "$r" commit -qm seed
  git_q "$r" remote add origin "$bare"
  git_q "$r" push -q origin main
  printf '%s %s\n' "$r" "$bare"
}
mk_worktree() { # repo branch -> prints worktree_path
  local wt="$TMP/wt-$2"
  git -C "$1" worktree add -q -b "$2" "$wt"
  echo "$wt"
}
reset_logs() { : >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"; : >"$GH_CALLS"; : >"$GATE_CALLS"; }

echo "== W1: a clean, delivered, pushed run with PRO_GATE_LOOP=1 runs the loop on the branch's PR =="
export DISPATCHER_LEDGER_FILE="$TMP/w1.jsonl"
read -r R1 _B1 <<<"$(mk_repo_with_origin pg-w1)"
WT1=$(mk_worktree "$R1" gate-w1)
reset_logs
OUTPUT=$(PRO_GATE_LOOP=1 GH_STUB_PR_NUMBER=7 CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R1" "test prompt" --use-worktree "$WT1" --run-id run-w1 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "W1 exit $RC: $OUTPUT"
grep -q -F -- "$WT1 7" "$GATE_CALLS" && ok || bad "W1 the loop was not invoked with (worktree, pr): $(cat "$GATE_CALLS")"
grep -q -F -- "pr list --head gate-w1" "$GH_CALLS" && ok || bad "W1 the PR was not looked up by branch: $(cat "$GH_CALLS")"
case "$OUTPUT" in *"pro-gate loop: allow at PR #7"*) ok ;; *) bad "W1 output lacks the allow line: $OUTPUT" ;; esac
case "$OUTPUT" in *"done. Review the work"*) ok ;; *) bad "W1 an allow must still end at review-then-merge, never a merge: $OUTPUT" ;; esac
CONTENT=$(jq -r .content "$CURL_PAYLOAD" 2>/dev/null)
[ ! -s "$CURL_PAYLOAD" ] && ok || bad "W1 successful review must remain silent: $CONTENT"
LOG1=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
{ [ -n "$LOG1" ] && grep -q -F "pro-gate loop: allow at PR #7" "$LOG1" 2>/dev/null; } && ok || bad "W1 run log lacks the gate result: log=$LOG1"

echo "== W2 (PLANTED NEGATIVE): with the switch off the loop is never invoked =="
export DISPATCHER_LEDGER_FILE="$TMP/w2.jsonl"
read -r R2 _B2 <<<"$(mk_repo_with_origin pg-w2)"
WT2=$(mk_worktree "$R2" gate-w2)
reset_logs
OUTPUT=$(GH_STUB_PR_NUMBER=7 CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R2" "test prompt" --use-worktree "$WT2" --run-id run-w2 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "W2 exit $RC: $OUTPUT"
[ ! -s "$GATE_CALLS" ] && ok || bad "W2 PLANTED NEGATIVE: the loop ran with the switch off: $(cat "$GATE_CALLS")"
[ ! -s "$GH_CALLS" ] && ok || bad "W2 the wrapper looked the PR up with the switch off: $(cat "$GH_CALLS")"
case "$OUTPUT" in *"pro-gate"*) bad "W2 output mentions the gate with the switch off: $OUTPUT" ;; *) ok ;; esac

echo "== W3 (PLANTED NEGATIVE): a dirty tree is never gated =="
export DISPATCHER_LEDGER_FILE="$TMP/w3.jsonl"
read -r R3 _B3 <<<"$(mk_repo_with_origin pg-w3)"
WT3=$(mk_worktree "$R3" gate-w3)
reset_logs
OUTPUT=$(PRO_GATE_LOOP=1 GH_STUB_PR_NUMBER=7 CLAUDE_STUB_COMMIT=1 CLAUDE_STUB_DIRTY=2 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R3" "test prompt" --use-worktree "$WT3" --run-id run-w3 2>&1); RC=$?
[ ! -s "$GH_CALLS" ] && ok || bad "W3 dirty tree called gh"
[ ! -s "$GATE_CALLS" ] && ok || bad "W3 PLANTED NEGATIVE: the loop ran over uncommitted work: $(cat "$GATE_CALLS")"
case "$OUTPUT" in *"2 files modified but uncommitted"*) ok ;; *) bad "W3 the dirty-tree surface went missing: $OUTPUT" ;; esac

echo "== W4 (PLANTED NEGATIVE): an empty branch is never gated =="
export DISPATCHER_LEDGER_FILE="$TMP/w4.jsonl"
read -r R4 _B4 <<<"$(mk_repo_with_origin pg-w4)"
WT4=$(mk_worktree "$R4" gate-w4)
reset_logs
OUTPUT=$(PRO_GATE_LOOP=1 GH_STUB_PR_NUMBER=7 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R4" "test prompt" --use-worktree "$WT4" --run-id run-w4 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "W4 exit $RC: $OUTPUT"
[ ! -s "$GH_CALLS" ] && ok || bad "W4 empty delivery called gh"
[ ! -s "$GATE_CALLS" ] && ok || bad "W4 PLANTED NEGATIVE: the loop ran over an empty branch: $(cat "$GATE_CALLS")"
case "$OUTPUT" in *"no commits produced"*) ok ;; *) bad "W4 the empty-delivery surface went missing: $OUTPUT" ;; esac

echo "== W5: a bounded loop (exit 4) is reported and the run's own exit stays the child's =="
export DISPATCHER_LEDGER_FILE="$TMP/w5.jsonl"
read -r R5 _B5 <<<"$(mk_repo_with_origin pg-w5)"
WT5=$(mk_worktree "$R5" gate-w5)
reset_logs
OUTPUT=$(PRO_GATE_LOOP=1 GH_STUB_PR_NUMBER=9 GATE_STUB_RC=4 CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R5" "test prompt" --use-worktree "$WT5" --run-id run-w5 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "W5 exit $RC (the gate's code must not become the run's): $OUTPUT"
case "$OUTPUT" in *"pro-gate loop: bounded at PR #9"*) ok ;; *) bad "W5 output lacks the bounded line: $OUTPUT" ;; esac
CONTENT=$(jq -r .content "$CURL_PAYLOAD" 2>/dev/null)
[ "$(grep -c 'stub.invalid' "$CURL_CALLS")" -eq 1 ] && ok || bad "W5 unknown remaining severity must page once: $CONTENT"
LOG5=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
grep -q "bounded at PR #9" "$LOG5" && ok || bad "A1728 handled stop must remain logged"

echo "== W6: no open PR for the branch is reported as skipped, not as a gate result =="
export DISPATCHER_LEDGER_FILE="$TMP/w6.jsonl"
read -r R6 _B6 <<<"$(mk_repo_with_origin pg-w6)"
WT6=$(mk_worktree "$R6" gate-w6)
reset_logs
OUTPUT=$(PRO_GATE_LOOP=1 GH_STUB_PR_NUMBER="" CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R6" "test prompt" --use-worktree "$WT6" --run-id run-w6 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "W6 exit $RC: $OUTPUT"
[ ! -s "$GATE_CALLS" ] && ok || bad "W6 the loop ran without a PR: $(cat "$GATE_CALLS")"
case "$OUTPUT" in *"pro-gate loop skipped: no open PR for gate-w6"*) ok ;; *) bad "W6 output lacks the skipped line: $OUTPUT" ;; esac

[ "$(grep -c 'stub.invalid' "$CURL_CALLS")" -eq 0 ] && ok || bad 'W6 successful empty lookup must not page'

echo '== W6b: failed PR lookup pages once without running review =='
reset_logs
OUTPUT=$(PRO_GATE_LOOP=1 GH_STUB_PR_FAIL=1 CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R6" "test prompt" --use-worktree "$WT6" --run-id run-w6b 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "W6b lookup failure changed child exit: $RC"
[ ! -s "$GATE_CALLS" ] && ok || bad 'W6b review must not run after lookup failure'
[ "$(grep -c 'stub.invalid' "$CURL_CALLS")" -eq 1 ] && ok || bad 'W6b failed lookup must page exactly once'
CONTENT=$(jq -r .content "$CURL_PAYLOAD" 2>/dev/null)
grep -q -F 'review/monitoring unavailable' <<<"$CONTENT" && ok || bad 'W6b missing unavailable review status'
grep -q -F 'Next:' <<<"$CONTENT" && grep -q -F 'Log:' <<<"$CONTENT" && ok || bad 'W6b missing action/log'
grep -q -F 'Service impact unknown' <<<"$CONTENT" && ok || bad 'W6b missing unknown service impact'
if grep -Eiq 'outage|down' <<<"$CONTENT"; then bad 'W6b must not claim service outage'; else ok; fi
LOG6B=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
grep -q -F 'fixture PR lookup failed' "$LOG6B" && ok || bad 'W6b missing lookup failure log evidence'

echo "== W7 (move 7): a --use-worktree run pushes and opens no PR; the gate's own gh pr list still finds an existing open PR =="
export DISPATCHER_LEDGER_FILE="$TMP/w7.jsonl"
read -r R7 _B7 <<<"$(mk_repo_with_origin pg-w7)"
WT7=$(mk_worktree "$R7" gate-w7)
reset_logs
OUTPUT=$(PRO_GATE_LOOP=1 GH_STUB_PR_NUMBER=55 CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R7" "test prompt" --use-worktree "$WT7" --run-id run-w7 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "W7 exit $RC: $OUTPUT"
LOG7=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
{ [ -n "$LOG7" ] && grep -q -F "==> pushed gate-w7; no PR opened (open one with: gh pr create --head gate-w7)" "$LOG7" 2>/dev/null; } && ok || bad "W7 run log must say the push opened no PR: log=$LOG7"
PR_OPENED_ROW=$(jq -R -c 'fromjson? | select(.run_id=="run-w7" and .event=="pr-opened")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
[ -z "$PR_OPENED_ROW" ] && ok || bad "W7 nothing opens a PR after a --use-worktree push, so no pr-opened row: $PR_OPENED_ROW"
if grep -q -F 'pr create' "$GH_CALLS"; then bad "W7 the wrapper must not create a PR: $(cat "$GH_CALLS")"; else ok; fi
[ "$(wc -l < "$GH_CALLS")" -eq 1 ] && ok || bad "W7 the gate's PR lookup should be the only gh call: $(cat "$GH_CALLS")"
grep -q -F -- "pr list --head gate-w7" "$GH_CALLS" && ok || bad "W7 the gate step's own PR lookup should still have run: $(cat "$GH_CALLS")"
grep -q -F -- "$WT7 55" "$GATE_CALLS" && ok || bad "W7 the gate should have found and gated the existing PR #55: $(cat "$GATE_CALLS")"
case "$OUTPUT" in *"pro-gate loop: allow at PR #55"*) ok ;; *) bad "W7 output lacks the allow line: $OUTPUT" ;; esac
[ "$(grep -c 'stub.invalid' "$CURL_CALLS")" -eq 0 ] && ok || bad 'W7 a clean gated run must not page'

echo "== W8 (issue #1523): a prose exemption is reported distinctly, not as Pro approval =="
export DISPATCHER_LEDGER_FILE="$TMP/w8.jsonl"
read -r R8 _B8 <<<"$(mk_repo_with_origin pg-w8)"
WT8=$(mk_worktree "$R8" gate-w8)
reset_logs
OUTPUT=$(PRO_GATE_LOOP=1 GH_STUB_PR_NUMBER=10 GATE_STUB_RC=5 CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R8" "test prompt" --use-worktree "$WT8" --run-id run-w8 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "W8 exemption must not change the child's exit: $RC: $OUTPUT"
case "$OUTPUT" in *"pro-gate loop: exempt (ordinary prose; no Pro review) at PR #10"*) ok ;; *) bad "W8 output lacks explicit exemption: $OUTPUT" ;; esac
case "$OUTPUT" in *"pro-gate loop: allow at PR #10"*) bad "W8 exemption was reported as review approval" ;; *) ok ;; esac
CONTENT=$(jq -r .content "$CURL_PAYLOAD")
[ ! -s "$CURL_PAYLOAD" ] && ok || bad "W8 ordinary prose exemption must remain silent: $CONTENT"
LOG8=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
{ [ -n "$LOG8" ] && grep -q -F "pro-gate loop: exempt (ordinary prose; no Pro review) at PR #10" "$LOG8"; } && ok || bad "W8 log lost the exemption: log=$LOG8"
case "$OUTPUT" in *"done. Review the work"*) ok ;; *) bad "W8 exemption must preserve caller-owned closeout: $OUTPUT" ;; esac

echo
echo '== A1728-human-only: product decisions and review failures stay visible; typed stops remain local =='
for gate_rc in 2 3 6; do
  read -r RH _BH <<<"$(mk_repo_with_origin "pg-human-$gate_rc")"
  WTH=$(mk_worktree "$RH" "gate-human-$gate_rc")
  reset_logs
  OUTPUT=$(PRO_GATE_LOOP=1 GH_STUB_PR_NUMBER=11 GATE_STUB_RC="$gate_rc" CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
    bash "$LOOP" "$RH" "test prompt" --use-worktree "$WTH" --run-id "run-human-$gate_rc" 2>&1); RC=$?
  [ "$RC" = 0 ] && ok || bad "A1728 human result must preserve worker exit: $gate_rc"
  if [ "$gate_rc" = 2 ]; then
    [ "$(grep -c 'stub.invalid' "$CURL_CALLS")" -eq 1 ] && ok || bad 'A1728 typed stop without noncritical proof must page once'
    LOGH=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
    grep -q 'stop-without-new-review' "$LOGH" && ok || bad 'A1728 handled typed stop must remain logged'
    continue
  fi
  [ "$(grep -c 'stub.invalid' "$CURL_CALLS")" -eq 1 ] && ok || bad "A1728 human/failure result must page once: $gate_rc"
  CONTENT=$(jq -r .content "$CURL_PAYLOAD" 2>/dev/null)
  grep -q 'Next:' <<<"$CONTENT" && grep -q 'Log:' <<<"$CONTENT" && ok || bad "A1728 human alert must include action and evidence: $gate_rc"
  if [ "$gate_rc" = 3 ]; then
    grep -q 'answer the product decision' <<<"$CONTENT" && ok || bad 'A1728 product choice action lost'
  fi
done

echo '== W9: post-review stranded/unknown work is never quiet or bare done =='
for work in dirty unpublished status-error remote-error; do
  rm -f "$GIT_FAIL_MARKER"
  read -r RP _BP <<<"$(mk_repo_with_origin "pg-final-$work")"
  WTP=$(mk_worktree "$RP" "gate-final-$work")
  reset_logs
  OUTPUT=$(PRO_GATE_LOOP=1 GH_STUB_PR_NUMBER=12 GATE_STUB_RC=4 GATE_STUB_WORK="$work" \
    GATE_STUB_PROOF=ship CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
    bash "$LOOP" "$RP" 'test prompt' --use-worktree "$WTP" --run-id "run-final-$work" 2>&1); RC=$?
  [ "$RC" = 0 ] && ok || bad "W9 preserve worker exit: $work: $RC"
  [ "$(grep -c 'stub.invalid' "$CURL_CALLS")" -eq 1 ] && ok || bad "W9 final $work must page once"
  case "$OUTPUT" in *'done. Review the work'*) bad "W9 final $work must not report bare done" ;; *) ok ;; esac
  CONTENT=$(jq -r .content "$CURL_PAYLOAD" 2>/dev/null)
  case "$work:$CONTENT" in
    dirty:*'modified but uncommitted'*|unpublished:*'push failed'*|status-error:*'worktree state unknown'*|remote-error:*'publication state unknown'*) ok ;;
    *) bad "W9 missing actual final state: $work: $CONTENT" ;;
  esac
  rm -f "$GIT_FAIL_MARKER"
done

echo '== W10: current invocation SHIP proof quiets bounded and typed stops =='
for proof in ship full stale malformed missing critical invalid-applicable invalid-binding_valid invalid-provenance_valid invalid-bindable invalid-collected legacy wrong-pr wrong-owner wrong-repo no-identity no-epoch bad-epoch bad-applicable bad-marker bad-digest latest-critical latest-incomplete same-epoch malformed-sibling omit-marker omit-artifact_digest omit-evidence_mode; do
  for gate_rc in 4 2; do
    read -r RT _BT <<<"$(mk_repo_with_origin "pg-proof-$proof-$gate_rc")"
    WTT=$(mk_worktree "$RT" "gate-proof-$proof-$gate_rc")
    export DISPATCHER_LEDGER_FILE="$TMP/proof-$proof-$gate_rc.jsonl"
    reset_logs
    OUTPUT=$(PRO_GATE_LOOP=1 GH_STUB_PR_NUMBER=13 GATE_STUB_RC="$gate_rc" GATE_STUB_PROOF="$proof" \
      CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
      bash "$LOOP" "$RT" 'test prompt' --use-worktree "$WTT" --run-id "run-proof-$proof-$gate_rc" 2>&1); RC=$?
    [ "$RC" = 0 ] && ok || bad "W10 $proof/$gate_rc worker exit: $RC: $OUTPUT"
    [ "$(wc -l < "$GATE_CALLS")" -eq 1 ] && ok || bad "W10 $proof/$gate_rc must invoke gate exactly once"
    case "$OUTPUT" in *'done. Review the work'*) ok ;; *) bad "W10 $proof/$gate_rc unrelated actionable state: $OUTPUT" ;; esac
    LOGT=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
    case "$gate_rc" in 4) label='bounded at PR #13' ;; 2) label='stop-without-new-review at PR #13' ;; esac
    grep -q -F "$label" "$LOGT" && ok || bad "W10 $proof/$gate_rc lost classified log"
    if [ "$proof" = ship ] || [ "$proof" = full ]; then
      # The wrapper also curls the isolated proxy health endpoint. Count only
      # notification transport, and require no message payload at all.
      [ "$(grep -c 'stub.invalid' "$CURL_CALLS")" -eq 0 ] && [ ! -s "$CURL_PAYLOAD" ] && ok || bad "W10 $proof/$gate_rc SHIP must suppress notification transport"
    else
      [ "$(grep -c 'stub.invalid' "$CURL_CALLS")" -eq 1 ] && ok || bad "W10 $proof/$gate_rc must page exactly once"
      CONTENT=$(jq -r .content "$CURL_PAYLOAD")
      grep -q -F 'Next:' <<<"$CONTENT" && grep -q -F 'Log:' <<<"$CONTENT" && ok || bad "W10 $proof/$gate_rc missing action/log"
      case "$CONTENT" in *'@here'*|*'@everyone'*) bad "W10 $proof/$gate_rc mentions everyone" ;; *) ok ;; esac
    fi
  done
done

echo "claude-loop-pro-gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
