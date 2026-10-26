#!/usr/bin/env bash
# Hermetic tests for discord-notify.sh and claude-loop.sh's notification
# wiring (issue #438). A PATH-stubbed curl captures argv + payload; a stubbed
# claude fakes the headless run; scratch HOME covers the ~/.secrets
# resolution case. No network, no real webhook, no real claude.
#
# Planted negatives:
#  - N2: quotes+newlines must round-trip through the payload — a raw-printf
#    JSON implementation produces invalid JSON (Discord 400s).
#  - N3: >2000-char content must arrive bounded AND naming the omission —
#    full-length sends 400, silent cuts acknowledged omitted content in
#    a members-app issue.
#  - N5: with no webhook resolvable the script must make ZERO network calls.
#  - N9: a failed claude run must still emit a FAILED notification — the
#    set -e abort path is exactly where a naive post-run notify never runs,
#    which is the silent overnight death this wiring exists to end.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)  # repo root
SCRIPT="$HERE/scripts/discord-notify.sh"
LOOP="$HERE/bin/claude-loop.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

pass=0 fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*" >&2; }

bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }
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
# U4c: let a planted negative fail just the health-probe call (argv contains
# CURL_FAIL_MATCH) without touching the Discord-post calls this same stub
# also serves -- both go through one PATH-stubbed curl.
if [ -n "${CURL_FAIL_MATCH:-}" ]; then
  case "$*" in
    *"$CURL_FAIL_MATCH"*) exit "${CURL_FAIL_RC:-22}" ;;
  esac
fi
exit "${CURL_RC:-0}"
STUB
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export CURL_CALLS="$TMP/curl-calls.log" CURL_PAYLOAD="$TMP/payload.json"
# F-Q: CURL_PAYLOAD is only (over)written by the curl stub when a `-d` arg
# fires, so it PERSISTS across tests. A payload-asserting test whose own
# notification silently regressed to send nothing would otherwise read the
# PREVIOUS test's payload and false-pass. Every reset site therefore truncates
# CURL_PAYLOAD alongside CURL_CALLS (`: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"`) so
# a missing notification leaves an empty file and the jq assertion fails loud.
# claude-loop's R8 spend pre-flight (issue #444) requires ANTHROPIC_BASE_URL
# on every path, including the legacy N8/N9 cases below -- a stub host that
# deliberately does NOT contain "stub.invalid" so it can never inflate the
# `grep -c "stub.invalid"` counts those cases assert on.
export ANTHROPIC_BASE_URL="https://ccflare.invalid"

echo "== N1: basic send — valid JSON payload, title prefix, UA header, timeout, exit 0 =="
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"
DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$SCRIPT" --title "t" -- "hello world"; RC=$?
[ "$RC" = 0 ] && ok || bad "N1 exit $RC"
jq -e . "$CURL_PAYLOAD" >/dev/null 2>&1 && ok || bad "N1 payload not valid JSON: $(cat "$CURL_PAYLOAD")"
[ "$(jq -r .content "$CURL_PAYLOAD")" = "**t** — hello world" ] && ok || bad "N1 content wrong: $(jq -r .content "$CURL_PAYLOAD")"
grep -q "User-Agent" "$CURL_CALLS" && ok || bad "N1 no User-Agent header"
grep -q -- "-m 15" "$CURL_CALLS" && ok || bad "N1 no curl timeout"

echo "== N2: quotes + newlines round-trip exactly (raw-printf JSON breaks here) =="
MSG=$'line "one"\nline \\two\\ with `ticks`'
DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$SCRIPT" -- "$MSG" >/dev/null
[ "$(jq -r .content "$CURL_PAYLOAD")" = "$MSG" ] && ok || bad "N2 content did not round-trip: $(jq -r .content "$CURL_PAYLOAD")"

echo "== N3: >2000 chars → bounded AND names the omission =="
BIG=$(printf 'x%.0s' $(seq 1 3000))
DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$SCRIPT" -- "$BIG" >/dev/null
LEN=$(jq -r '.content | length' "$CURL_PAYLOAD")
[ "$LEN" -le 2000 ] && ok || bad "N3 content length $LEN > 2000 (Discord would 400)"
jq -r .content "$CURL_PAYLOAD" | grep -q "truncated" && ok || bad "N3 omission not named (silent cut)"

echo "== N4: curl failure → exit 1 =="
CURL_RC=22 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$SCRIPT" -- "x" 2>/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "N4 exit $RC (want 1)"

echo "== N5: no webhook anywhere → exit 3, ZERO network calls =="
# env -u: the OPERATOR's interactive shell exports DISCORD_WEBHOOK_URL (from
# ~/.secrets), so a bare invocation inherits a real webhook and this case
# silently tests nothing — caught on first local run, stub curl absorbed it.
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"
env -u DISCORD_WEBHOOK_URL bash "$SCRIPT" -- "x" 2>/dev/null; RC=$?
[ "$RC" = 3 ] && ok || bad "N5 exit $RC (want 3)"
[ -s "$CURL_CALLS" ] && bad "N5 made a network call with no webhook" || ok

echo "== N6: webhook resolved by sourcing ~/.secrets =="
printf 'export DISCORD_WEBHOOK_URL="https://stub.invalid/from-secrets"\n' >"$HOME/.secrets"
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"
env -u DISCORD_WEBHOOK_URL bash "$SCRIPT" -- "via secrets" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "N6 exit $RC"
grep -q "from-secrets" "$CURL_CALLS" && ok || bad "N6 did not use the .secrets webhook"
rm -f "$HOME/.secrets"

echo "== N7: stdin mode =="
printf 'from stdin' | DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$SCRIPT" - >/dev/null
[ "$(jq -r .content "$CURL_PAYLOAD")" = "from stdin" ] && ok || bad "N7 stdin content wrong"

echo "== U1: usage errors exit 2 (missing flag values) =="
DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$SCRIPT" --title 2>/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "U1 --title with no value exited $RC (want 2)"
DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$SCRIPT" --webhook-env 2>/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "U1 --webhook-env with no value exited $RC (want 2)"

echo "== U2: invalid --webhook-env identifier exits 2 (not a crash colliding with send-failed) =="
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"
DISCORD_WEBHOOK_URL="" bash "$SCRIPT" --webhook-env "a b" -- hello 2>"$TMP/u2.err"; RC=$?
[ "$RC" = 2 ] && ok || bad "U2 invalid identifier exited $RC (want 2)"
grep -q "invalid variable name" "$TMP/u2.err" && bad "U2 leaked a raw bash error" || ok
[ -s "$CURL_CALLS" ] && bad "U2 made a network call on a usage error" || ok
DISCORD_WEBHOOK_URL="" bash "$SCRIPT" --webhook-env "1FOO" -- hello 2>/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "U2 leading-digit identifier exited $RC (want 2)"

echo "== M1: multibyte truncation counts CODEPOINTS even under a byte locale =="
# 700 CJK chars = 2100 UTF-8 bytes: byte-counting truncates it (wrongly);
# codepoint-counting leaves it whole. Invoked under LC_ALL=C to pin the
# script's own locale forcing (inward-vet finding).
CJK=$(printf '汉%.0s' $(seq 1 700))
LC_ALL=C DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$SCRIPT" -- "$CJK" >/dev/null
[ "$(jq -r '.content | length' "$CURL_PAYLOAD")" = 700 ] && ok \
  || bad "M1 700-codepoint CJK message mangled under LC_ALL=C: length=$(jq -r '.content | length' "$CURL_PAYLOAD")"
CJKBIG=$(printf '汉%.0s' $(seq 1 2500))
LC_ALL=C DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$SCRIPT" -- "$CJKBIG" >/dev/null
jq -e . "$CURL_PAYLOAD" >/dev/null 2>&1 && ok || bad "M1 truncated CJK payload is not valid JSON (mid-character slice)"
LEN=$(jq -r '.content | length' "$CURL_PAYLOAD")
[ "$LEN" -le 2000 ] && ok || bad "M1 truncated CJK length $LEN > 2000"

echo "== S1: hostile ~/.secrets cannot kill the notifier =="
# A .secrets that exits, or references an unset var under set -u, previously
# killed the script mid-flight with ZERO output and exit 1 (inward-vet
# blocker). It must land on the documented no-webhook path instead.
printf 'exit 1\n' >"$HOME/.secrets"
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"
env -u DISCORD_WEBHOOK_URL bash "$SCRIPT" -- "x" 2>"$TMP/s1.err"; RC=$?
[ "$RC" = 3 ] && ok || bad "S1 exit-calling .secrets: exited $RC (want 3)"
grep -q "no webhook" "$TMP/s1.err" && ok || bad "S1 exit-calling .secrets: documented error missing"
printf 'if [ 1\n' >"$HOME/.secrets"
env -u DISCORD_WEBHOOK_URL bash "$SCRIPT" -- "x" 2>/dev/null; RC=$?
[ "$RC" = 3 ] && ok || bad "S1 syntax-error .secrets: exited $RC (want 3)"
# Unset refs inside .secrets are TOLERATED by design (set +u in the subshell):
# junk elsewhere in a big secrets file must not cost the webhook. A URL line
# that itself references an unset var degrades to a junk URL and an honest
# send-failure — not a silent death.
printf 'export DISCORD_WEBHOOK_URL="https://x/${SOME_UNDEFINED_VAR_431}"\n' >"$HOME/.secrets"
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"
env -u DISCORD_WEBHOOK_URL bash "$SCRIPT" -- "x" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && grep -q "https://x/" "$CURL_CALLS" && ok \
  || bad "S1 unset-var URL line: want tolerant resolution to the degraded URL (stub rc=0), got exit $RC"
rm -f "$HOME/.secrets"

echo "== N8: routine loop start and successful completion remain local =="
cat >"$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[ -n "${CLAUDE_CALLS:-}" ] && printf '%s\n' "$*" >> "$CLAUDE_CALLS"
if [ -n "${CLAUDE_ENV_CHECK_FILE:-}" ]; then
  if [ -n "${ANTHROPIC_API_KEY+x}" ]; then printf 'SET\n' >"$CLAUDE_ENV_CHECK_FILE"; else printf 'UNSET\n' >"$CLAUDE_ENV_CHECK_FILE"; fi
fi
# U4e2: record one gateway request stamped now, which falls inside claude-loop's run window.
if [ -n "${CLAUDE_STUB_CCFLARE_DB:-}" ]; then
  python3 -c 'import sqlite3, sys, time; c = sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO requests (timestamp, cost_usd, total_tokens) VALUES (?, ?, ?)", (int(time.time() * 1000), 1.25, 4200)); c.commit()' "$CLAUDE_STUB_CCFLARE_DB"
fi
if [ "${CLAUDE_STUB_COMMIT:-0}" = 1 ]; then
  printf 'completed\n' > completed
  git add completed
  git -c user.email=t@t -c user.name=t commit -qm completed
fi
echo "stub claude ran"
# NOTE: this MUST NOT be named CLAUDE_RC. claude-loop.sh uses CLAUDE_RC as its
# OWN internal variable (F-K): it inherits any exported CLAUDE_RC, reassigns it
# to 0 before launching claude, and -- because a reassigned inherited var stays
# exported -- would push that 0 straight into this stub's env, forcing exit 0
# and silently defeating every failure-path test. CLAUDE_STUB_RC is a name
# claude-loop never touches, so it reaches the stub intact.
exit "${CLAUDE_STUB_RC:-0}"
STUB
chmod +x "$TMP/bin/claude"
export CLAUDE_CALLS="$TMP/claude-calls.log"; : >"$CLAUDE_CALLS"

# gh + dispatcher-ledger.sh stubs for the U4 (--use-worktree) cases below.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:?}"
# `gh pr create` must print the new PR's URL on stdout: claude-loop.sh captures
# it into PR_URL and skips its closing-keyword advisory when that is empty, so a
# silent stub would make the L cases below vacuous.
if [ "${1:-}" = pr ] && [ "${2:-}" = create ] && [ "${GH_RC:-0}" = 0 ]; then
  echo "${GH_STUB_PR_URL:-https://github.com/fake/fake/pull/1}"
fi
exit "${GH_RC:-0}"
STUB
chmod +x "$TMP/bin/gh"
export GH_CALLS="$TMP/gh-calls.log"; : >"$GH_CALLS"

cat >"$TMP/bin/dispatcher-ledger-stub.sh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  if [ -z "$a" ]; then printf '<EMPTY>\n'; else printf '%s\n' "$a"; fi
done >> "${LEDGER_CALLS:?}"
printf -- '---\n' >> "${LEDGER_CALLS:?}"
exit "${LEDGER_RC:-0}"
STUB
chmod +x "$TMP/bin/dispatcher-ledger-stub.sh"
export LEDGER_CALLS="$TMP/ledger-calls.log"; : >"$LEDGER_CALLS"
export DISPATCHER_LEDGER_BIN="$TMP/bin/dispatcher-ledger-stub.sh"

git_q() { git -c user.email=t@t -c user.name=t -C "$1" "${@:2}"; }
mk_repo() {
  local r=$TMP/$1; mkdir -p "$r"; git -C "$r" init -q -b main
  printf 'x\n' >"$r/f"; git_q "$r" add f; git_q "$r" commit -qm seed; echo "$r"
}
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
  # NOTE: `local a=$1 b=$2 c=$a-ish` expands ALL words before any assignment
  # takes effect under `set -u` -- referencing an earlier local in the same
  # `local` line's RHS reads as unbound. Split into separate statements.
  local r="$1"
  local br="$2"
  local wt="$TMP/wt-$br"
  git -C "$r" worktree add -q -b "$br" "$wt"
  echo "$wt"
}
R=$(mk_repo loop-ok)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"
CLAUDE_STUB_COMMIT=1 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$LOOP" "$R" "test prompt" loop-ok-branch --no-pr >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "N8 loop exit $RC"
CALLS=$(grep -c "stub.invalid" "$CURL_CALLS" || true)
[ "${CALLS:-0}" -eq 0 ] && ok || bad "N8 routine run must be silent, saw $CALLS curl calls"
rg -q "finished OK" "$HOME/.claude/loop-logs" && ok || bad "N8 routine completion must remain locally recorded"

echo "== N9: claude-loop FAILURE path (set -e abort) still notifies FAILED =="
R2=$(mk_repo loop-fail)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"
CLAUDE_STUB_RC=3 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$LOOP" "$R2" "test prompt" loop-fail-branch --no-pr >/dev/null 2>&1; RC=$?
[ "$RC" != 0 ] && ok || bad "N9 loop exited 0 despite failed claude"
jq -r .content "$CURL_PAYLOAD" | grep -q "FAILED (exit 3)" && ok || bad "N9 final payload lacks FAILED: $(cat "$CURL_PAYLOAD")"

echo "== U4a: --use-worktree happy path — dispatcher already claimed, script must not re-claim =="
# The dispatcher tick claims via wt-new.sh (worktree + empty start commit +
# push + draft PR) BEFORE calling claude-loop.sh; --use-worktree must skip
# all of that and just cd into what's already there, then push the run's
# commits onto the SAME branch so they land on the already-open PR.
read -r R4A BARE4A <<<"$(mk_repo_with_origin loop-u4a)"
WT4A=$(mk_worktree "$R4A" dispatch-u4a)
WTCOUNT_BEFORE=$(git -C "$R4A" worktree list | wc -l)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"; : >"$GH_CALLS"; : >"$LEDGER_CALLS"
DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$LOOP" "$R4A" "test prompt" --use-worktree "$WT4A" --run-id run-u4a >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "U4a loop exit $RC"
WTCOUNT_AFTER=$(git -C "$R4A" worktree list | wc -l)
[ "$WTCOUNT_AFTER" = "$WTCOUNT_BEFORE" ] && ok || bad "U4a worktree count changed ($WTCOUNT_BEFORE -> $WTCOUNT_AFTER); --use-worktree must not create a new one"
[ ! -s "$GH_CALLS" ] && ok || bad "U4a made a gh call (draft PR create) under --use-worktree: $(cat "$GH_CALLS")"
git -C "$BARE4A" rev-parse --verify dispatch-u4a >/dev/null 2>&1 && ok || bad "U4a final push did not land on the origin bare repo"
grep -A1 -- '^--run-id$' "$LEDGER_CALLS" | grep -q "^run-u4a$" && ok || bad "U4a ledger append missing --run-id run-u4a: $(cat "$LEDGER_CALLS")"
grep -A1 -- '^--event$' "$LEDGER_CALLS" | grep -q "^ended$" && ok || bad "U4a ledger append missing --event ended: $(cat "$LEDGER_CALLS")"
grep -A1 -- '^--exit$' "$LEDGER_CALLS" | grep -q "^0$" && ok || bad "U4a ledger append missing --exit 0: $(cat "$LEDGER_CALLS")"
grep -A1 -- '^--overlap$' "$LEDGER_CALLS" | grep -q "^false$" && ok || bad "U4a ledger append missing --overlap false: $(cat "$LEDGER_CALLS")"

echo "== U4b: --use-worktree FAILURE path — claude exit 3 still notifies FAILED and records exit 3 =="
read -r R4B BARE4B <<<"$(mk_repo_with_origin loop-u4b)"
WT4B=$(mk_worktree "$R4B" dispatch-u4b)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$LEDGER_CALLS"
CLAUDE_STUB_RC=3 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$LOOP" "$R4B" "test prompt" --use-worktree "$WT4B" --run-id run-u4b >/dev/null 2>&1; RC=$?
[ "$RC" = 3 ] && ok || bad "U4b loop exit $RC (want 3)"
jq -r .content "$CURL_PAYLOAD" | grep -q "FAILED (exit 3)" && ok || bad "U4b final payload lacks FAILED (exit 3): $(cat "$CURL_PAYLOAD")"
grep -A1 -- '^--run-id$' "$LEDGER_CALLS" | grep -q "^run-u4b$" && ok || bad "U4b ledger append missing --run-id run-u4b: $(cat "$LEDGER_CALLS")"
grep -A1 -- '^--exit$' "$LEDGER_CALLS" | grep -q "^3$" && ok || bad "U4b ledger append missing --exit 3: $(cat "$LEDGER_CALLS")"

echo "== U4c: R8 spend pre-flight negative — proxy unreachable blocks claude in BOTH modes =="
R4C=$(mk_repo loop-u4c)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
CURL_FAIL_MATCH="/health" DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$LOOP" "$R4C" "test prompt" loop-u4c-branch --no-pr >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "U4c (legacy) loop exit $RC (want 1)"
[ ! -s "$CLAUDE_CALLS" ] && ok || bad "U4c (legacy) claude was invoked despite unreachable proxy: $(cat "$CLAUDE_CALLS")"
grep -q "spend pre-flight" "$CURL_CALLS" && ok || bad "U4c (legacy) no spend-pre-flight notification observed: $(cat "$CURL_CALLS")"

read -r R4C2 BARE4C2 <<<"$(mk_repo_with_origin loop-u4c2)"
WT4C2=$(mk_worktree "$R4C2" dispatch-u4c)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$CLAUDE_CALLS"
CURL_FAIL_MATCH="/health" DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$LOOP" "$R4C2" "test prompt" --use-worktree "$WT4C2" --run-id run-u4c >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "U4c (--use-worktree) loop exit $RC (want 1)"
[ ! -s "$CLAUDE_CALLS" ] && ok || bad "U4c (--use-worktree) claude was invoked despite unreachable proxy: $(cat "$CLAUDE_CALLS")"
grep -q "spend pre-flight" "$CURL_CALLS" && ok || bad "U4c (--use-worktree) no spend-pre-flight notification observed: $(cat "$CURL_CALLS")"
[ "$(grep -c 'stub.invalid' "$CURL_CALLS")" -eq 1 ] && ok || bad 'A1728-preflight-exit-duplicate must send exactly one failure alert'
jq -r .content "$CURL_PAYLOAD" | grep -q 'Service impact unknown' && ok || bad 'A1728 preflight must not claim a service outage'
jq -r .content "$CURL_PAYLOAD" | grep -q 'Next:' && ok || bad 'A1728 failure must name next human action'
if grep -Eq '@here|@everyone' "$CURL_PAYLOAD"; then bad 'A1728 accidental mass mention'; else ok; fi

echo "== U4d: ANTHROPIC_API_KEY is scrubbed from claude's environment (proxy bypass must never flip billing) =="
R4D=$(mk_repo loop-u4d)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"
ANTHROPIC_API_KEY="sk-ant-fake-should-never-reach-claude" CLAUDE_ENV_CHECK_FILE="$TMP/env-check-u4d" \
  DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$LOOP" "$R4D" "test prompt" loop-u4d-branch --no-pr >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "U4d loop exit $RC"
[ "$(cat "$TMP/env-check-u4d" 2>/dev/null)" = "UNSET" ] && ok || bad "U4d ANTHROPIC_API_KEY reached claude's env: $(cat "$TMP/env-check-u4d" 2>/dev/null)"

echo "== U4e: dispatcher-cost reports null cost/tokens when the ccflare DB is missing (real script, scratch HOME) =="
read -r R4E BARE4E <<<"$(mk_repo_with_origin loop-u4e)"
WT4E=$(mk_worktree "$R4E" dispatch-u4e)
: >"$LEDGER_CALLS"
OUTPUT=$(DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$LOOP" "$R4E" "test prompt" --use-worktree "$WT4E" --run-id run-u4e 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "U4e loop exit $RC"
LOG4E=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
[ -n "$LOG4E" ] && [ -f "$LOG4E" ] && ok || bad "U4e could not locate the run log from stdout"
grep -q "WARN" "$LOG4E" 2>/dev/null && ok || bad "U4e missing ccflare DB should WARN into the log: $(cat "$LOG4E" 2>/dev/null)"
grep -A1 -- '^--cost$' "$LEDGER_CALLS" | grep -q "^<EMPTY>$" && ok || bad "U4e ledger --cost should be null/empty on a missing DB: $(cat "$LEDGER_CALLS")"

echo "== U4e2: dispatcher-cost success path: the real script's window_cost_usd reaches the ledger's --cost and --tokens (writer and reader agree on the key) =="
CCFLARE_DB="$HOME/.config/better-ccflare/better-ccflare.db"
mkdir -p "$HOME/.config/better-ccflare"
python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE requests (timestamp INTEGER, cost_usd REAL, total_tokens INTEGER)"); c.execute("INSERT INTO requests VALUES (1, 100.0, 999999)"); c.commit()' "$CCFLARE_DB"
read -r R4E2 _ <<<"$(mk_repo_with_origin loop-u4e2)"
WT4E2=$(mk_worktree "$R4E2" dispatch-u4e2)
: >"$LEDGER_CALLS"
CLAUDE_STUB_CCFLARE_DB="$CCFLARE_DB" DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R4E2" "test prompt" --use-worktree "$WT4E2" --run-id run-u4e2 >/dev/null 2>&1; RC=$?
OUT4E2=$(python3 "$HERE/scripts/dispatcher-cost.py" 0 9999999999999 2>/dev/null)
rm -f "$CCFLARE_DB"   # the later cases keep U4e's no-gateway-DB state
[ "$RC" = 0 ] && ok || bad "U4e2 loop exit $RC"
grep -A1 -- '^--cost$' "$LEDGER_CALLS" | grep -qx '1.25' && ok || bad "U4e2 ledger --cost should be the in-window row's 1.25, not the timestamp-1 row outside the window: $(cat "$LEDGER_CALLS")"
grep -A1 -- '^--tokens$' "$LEDGER_CALLS" | grep -qx '4200' && ok || bad "U4e2 ledger --tokens should be the in-window row's 4200: $(cat "$LEDGER_CALLS")"
[ "$(printf '%s' "$OUT4E2" | jq -r '.window_cost_usd')" = "101.25" ] && [ "$(printf '%s' "$OUT4E2" | jq -r '.cost_usd')" = "101.25" ] \
  && ok || bad "U4e2 the cost script must print the window's cost under window_cost_usd and its cost_usd alias, which a loop started before the rename reads at exit: $OUT4E2"

echo "== U4e3: claude-loop still reads a cost helper that prints only the pre-rename cost_usd key (a rollback) =="
cat >"$TMP/bin/cost-old-key.py" <<'STUB'
print('{"cost_usd": 2.5, "tokens": 7}')
STUB
read -r R4E3 _ <<<"$(mk_repo_with_origin loop-u4e3)"
WT4E3=$(mk_worktree "$R4E3" dispatch-u4e3)
: >"$LEDGER_CALLS"
DISPATCHER_COST_BIN="$TMP/bin/cost-old-key.py" DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R4E3" "test prompt" --use-worktree "$WT4E3" --run-id run-u4e3 >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "U4e3 loop exit $RC"
grep -A1 -- '^--cost$' "$LEDGER_CALLS" | grep -qx '2.5' && ok || bad "U4e3 ledger --cost should read the pre-rename key's 2.5: $(cat "$LEDGER_CALLS")"

echo "== U4f: overlap detection — a live session flips --overlap to true (over-flagging is the safe direction) =="
read -r R4F BARE4F <<<"$(mk_repo_with_origin loop-u4f)"
WT4F=$(mk_worktree "$R4F" dispatch-u4f)
cat >"$TMP/bin/live-sessions-stub.js" <<'STUB'
console.log(JSON.stringify([{ pid: 999999, sessionId: "fake-live-session" }]));
STUB
: >"$LEDGER_CALLS"
LIVE_SESSIONS_BIN="$TMP/bin/live-sessions-stub.js" DISCORD_WEBHOOK_URL="https://stub.invalid/wh" \
  bash "$LOOP" "$R4F" "test prompt" --use-worktree "$WT4F" --run-id run-u4f >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "U4f loop exit $RC"
grep -A1 -- '^--overlap$' "$LEDGER_CALLS" | grep -q "^true$" && ok || bad "U4f ledger --overlap should be true: $(cat "$LEDGER_CALLS")"

echo "== U4g: --use-worktree push FAILURE — commits never reach the PR, run notifies WARN but still exits CLAUDE_RC and closes the ledger =="
# "no silent fallback": a swallowed push failure would let a kept run reconcile
# as waste. Break the origin URL so the post-run push fails; claude itself
# succeeds (exit 0), so the run must (a) still exit 0 — publish success is
# orthogonal to the agent's exit code — (b) emit "finished OK" WITH a push-failed
# WARN, and (c) still write the `ended` ledger row despite the push failure.
read -r R4G BARE4G <<<"$(mk_repo_with_origin loop-u4g)"
WT4G=$(mk_worktree "$R4G" dispatch-u4g)
git_q "$R4G" remote set-url origin "$TMP/loop-u4g-missing.git"   # push target now nonexistent -> push fails fast
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"; : >"$LEDGER_CALLS"
OUTPUT=$(DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$LOOP" "$R4G" "test prompt" --use-worktree "$WT4G" --run-id run-u4g 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "U4g loop exit $RC (want 0 — push failure must not override CLAUDE_RC)"
CONTENT=$(jq -r .content "$CURL_PAYLOAD")
grep -q "finished OK" <<<"$CONTENT" && ok || bad "U4g payload lacks finished-OK: $CONTENT"
grep -q "push failed" <<<"$CONTENT" && ok || bad "U4g payload lacks push-failed WARN: $CONTENT"
grep -A1 -- '^--event$' "$LEDGER_CALLS" | grep -q "^ended$" && ok || bad "U4g ledger append missing --event ended after push failure: $(cat "$LEDGER_CALLS")"
grep -A1 -- '^--exit$' "$LEDGER_CALLS" | grep -q "^0$" && ok || bad "U4g ledger append missing --exit 0: $(cat "$LEDGER_CALLS")"
LOG4G=$(printf '%s\n' "$OUTPUT" | sed -n 's/^==> log:[[:space:]]*//p')
{ [ -n "$LOG4G" ] && grep -q "WARN: git push" "$LOG4G" 2>/dev/null; } && ok || bad "U4g push failure should WARN into the run log (diagnosable, not /dev/null): log=$LOG4G"

# ---- L: claude-loop.sh's own tracking-PR body ------------------------------
# The block under test is skipped by every case above: --no-pr short-circuits it
# and --use-worktree bypasses it entirely (the dispatcher's wt-new.sh already
# opened the unit). These two cases are the only ones that execute it, so
# without them claude-loop.sh's copy of the closing-keyword logic is untested.

echo "== L1: legacy-mode PR body defaults to CLOSING, with an ACTIONABLE advisory =="
read -r RL1 _ < <(mk_repo_with_origin loop-l1)
: >"$GH_CALLS"
export GH_STUB_PR_URL="https://github.com/fake/fake/pull/141"
OUTPUT=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$LOOP" "$RL1" "test prompt" loop-l1-branch '#138' 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "L1 loop exit $RC: $OUTPUT"
grep -q -- '--body Autonomous claude-loop run.' "$GH_CALLS" && ok || bad "L1 no pr create observed: $(cat "$GH_CALLS")"
grep -q -- 'Closes #138' "$GH_CALLS" && ok || bad "L1 body passed to gh pr create is not closing by default: $(cat "$GH_CALLS")"
case "$OUTPUT" in *"so merging it closes that issue"*) ok ;; *) bad "L1 no closing-keyword advisory: $OUTPUT" ;; esac
# "Re-run with --refs-only" is unfollowable here -- the branch and worktree
# already exist, so a re-run dies at `git worktree add` and a run without the
# branch just opens a SECOND PR. Only editing the PR that now exists works.
case "$OUTPUT" in *"gh pr edit"*) ok ;; *) bad "L1 advisory names no actionable remediation: $OUTPUT" ;; esac
case "$OUTPUT" in *"Refs #138"*) ok ;; *) bad "L1 remediation does not carry the corrected non-closing body: $OUTPUT" ;; esac

echo "== L2: --refs-only makes the loop's PR body NON-closing, and silences the advisory =="
read -r RL2 _ < <(mk_repo_with_origin loop-l2)
: >"$GH_CALLS"
export GH_STUB_PR_URL="https://github.com/fake/fake/pull/142"
OUTPUT=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$LOOP" "$RL2" "test prompt" loop-l2-branch '#138' --refs-only 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "L2 loop exit $RC: $OUTPUT"
grep -q -- 'Refs #138' "$GH_CALLS" && ok || bad "L2 --refs-only did not produce a non-closing body: $(cat "$GH_CALLS")"
if grep -q -- 'Closes #138' "$GH_CALLS"; then bad "L2 --refs-only still emitted a closing keyword: $(cat "$GH_CALLS")"; else ok; fi
case "$OUTPUT" in *"so merging it closes that issue"*) bad "L2 advised about a closing body that --refs-only already prevented: $OUTPUT" ;; *) ok ;; esac
unset GH_STUB_PR_URL

echo
echo '== A1728-loop-hostile-mention: branch text cannot page everyone =='
RM=$(mk_repo loop-mention)
: >"$CURL_CALLS"; : >"$CURL_PAYLOAD"
CLAUDE_STUB_RC=3 DISCORD_WEBHOOK_URL="https://stub.invalid/wh" bash "$LOOP" "$RM" "test prompt" 'loop-@here-@everyone' --no-pr >/dev/null 2>&1; RC=$?
[ "$RC" = 3 ] && ok || bad 'A1728 hostile branch failure exit changed'
[ "$(grep -c 'stub.invalid' "$CURL_CALLS")" -eq 1 ] && ok || bad 'A1728 hostile branch must still alert once'
if grep -Eq '@here|@everyone' "$CURL_PAYLOAD"; then bad 'A1728 hostile branch mass mention'; else ok; fi

echo "discord-notify: $pass passed, $fail failed"
[ "$fail" = 0 ]
