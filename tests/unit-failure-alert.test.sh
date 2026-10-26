#!/usr/bin/env bash
# Hermetic tests for unit-failure-alert.sh and the harness-unit-failure-alert@
# wiring (issue #476).
#
# The guarantee this suite exists to protect is "a failed unit actually pages".
# Its most important case is therefore the DEPLOY-SHAPED one (case 8): every
# other case injects a stub notifier, and a suite made only of stubbed cases is
# exactly how tokscale-timeout-alert.py shipped a bare `discord-notify` PATH
# lookup that resolved to nothing in production while its tests stayed green.
# Stubs prove the logic; case 8 proves the wiring.
#
# Two rules this suite follows so it cannot manufacture the world it tests:
#   - Never reconstruct one of the script's private conventions (the stamp
#     filename, the NOTIFY default) by parsing source text or rebuilding the
#     name. Read what the script actually did, or run it for real.
#   - Every planted negative must be inverted against the real source at least
#     once, to confirm it can fail.
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel); cd "$ROOT"
TMP=$(mktemp -d /tmp/unit-failure-alert-test.XXXXXX); trap 'rm -rf "$TMP"' EXIT
unset MONITOR_UNIT MONITOR_INVOCATION_ID MONITOR_SERVICE_RESULT MONITOR_EXIT_STATUS
mkdir -p "$TMP/bin" "$TMP/stamps"

SCRIPT=scripts/unit-failure-alert.sh
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# ── stubs ───────────────────────────────────────────────────────────────────
# systemctl answers the property reads the script makes; anything else is an
# unexpected call and exits 92 so a silent grammar change is caught. Note the
# ${VAR-default} form (no colon) on InvocationID: exporting it EMPTY is how the
# no-invocation fallback path gets exercised.
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "--user show "*" -p Result --value")                printf '%s\n' "${TEST_RESULT:-exit-code}" ;;
  "--user show "*" -p ExecMainStatus --value")        printf '%s\n' "${TEST_STATUS:-1}" ;;
  "--user show "*" -p ExecMainExitTimestamp --value") printf '%s\n' "${TEST_STAMP-Wed 2026-08-26 03:48:11 EDT}" ;;
  "--user show "*" -p InvocationID --value")          printf '%s\n' "${TEST_INVOCATION-f9b7ae2557204e71900a7d4d69f7784d}" ;;
  *) exit 92 ;;
esac
EOF
cat > "$TMP/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'JOURNALARGS:%s\n' "$*" >>"${TEST_JARGS:-/dev/null}"
if [ "${TEST_JOURNAL_HANG:-0}" = 1 ]; then
  trap '' TERM
  sleep 8
  exit 124
fi
if [ -n "${TEST_JOURNAL_DELAY:-}" ] && [ ! -f "$TEST_JOURNAL_DELAY" ]; then
  touch "$TEST_JOURNAL_DELAY"
  exit 0
fi
[ "${TEST_JOURNAL_RC:-0}" -eq 0 ] || exit "$TEST_JOURNAL_RC"
if [ -n "${TEST_JOURNAL_FILE:-}" ]; then
  entries=$(cat "$TEST_JOURNAL_FILE")
  lines=20 format=cat
  while [ "$#" -gt 0 ]; do
    case $1 in
      -n) lines=$2; shift ;;
      -o) format=$2; shift ;;
      --output-fields=*) ;;
      *=*) entries=$(printf '%s\n' "$entries" | jq -c --arg k "${1%%=*}" --arg v "${1#*=}" 'select(.[$k] == $v)') ;;
    esac
    shift
  done
  if [ "$format" = json ]; then
    printf '%s\n' "$entries" | tail -n "$lines"
  else
    printf '%s\n' "$entries" | tail -n "$lines" | jq -r '.MESSAGE'
  fi
  exit 0
fi
printf '%s\n' "${TEST_JOURNAL-memory push refused: sensitive indicator or symlink found}"
EOF
cat > "$TMP/bin/notify-stub" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" >>"${TEST_CALLS:?}"
cat >>"${TEST_CALLS:?}"
printf '\n===END===\n' >>"${TEST_CALLS:?}"
exit "${TEST_NOTIFY_RC:-0}"
EOF
chmod +x "$TMP/bin/systemctl" "$TMP/bin/journalctl" "$TMP/bin/notify-stub"

# Per-case overrides are exported by the caller (in a subshell), never passed as
# extra words here: an assignment arriving via "$@" is NOT re-parsed as an
# assignment, it becomes the command name, so the script silently never runs.
run() {
  PATH="$TMP/bin:$PATH" \
  UNIT_ALERT_TEST_MODE=1 \
  DISCORD_NOTIFY_BIN="${NOTIFY_OVERRIDE:-$TMP/bin/notify-stub}" \
  UNIT_ALERT_STAMP_DIR="$TMP/stamps" \
  TEST_CALLS="$TMP/calls" \
  bash "$SCRIPT" "$1"
}

pages() { grep -c '===END===' "$TMP/calls" 2>/dev/null || echo 0; }
reset() { : >"$TMP/calls"; rm -f "$TMP/stamps"/* 2>/dev/null || true; }

# Rewrite every stamp the script actually created, without knowing its naming
# convention. Hardcoding "$TMP/stamps/<unit>" is how the earlier version of this
# suite silently stopped testing the cooldown when the filename gained a digest.
plant_stamps() {
  local value=$1 f found=0
  for f in "$TMP/stamps"/*; do
    [ -e "$f" ] || continue
    printf '%s\n' "$value" >"$f"; found=$((found + 1))
  done
  [ "$found" -gt 0 ]
}

# ── 1. a failed unit pages, and the page carries the diagnostic ──────────────
reset
run backup-harness.service >/dev/null 2>&1 || bad "1: alerter exited non-zero on a normal failure"
grep -q 'ARGS:--title harness unit FAILED -' "$TMP/calls" \
  && ok "1a: invoked the notifier with a title and stdin body" \
  || bad "1a: notifier argv wrong: $(head -1 "$TMP/calls")"
grep -q 'backup-harness.service failed on' "$TMP/calls" && ok "1b: names the failed unit" || bad "1b: page omits the unit name"
grep -q 'Result=exit-code ExecMainStatus=1' "$TMP/calls" && ok "1c: carries Result and ExecMainStatus" || bad "1c: page omits the status pair"
grep -q 'memory push refused' "$TMP/calls" && ok "1d: carries the journal tail" || bad "1d: page omits the journal tail"
# The whole point of the issue: the operator must not have to go find the probe.
grep -q 'systemctl --user status backup-harness.service' "$TMP/calls" \
  && ok "1e: names the follow-up probe" || bad "1e: page omits the probe command"

# ── 2. PLANTED NEGATIVE: the alerter must never alert on itself ──────────────
# Drop the self-guard and this pages, which in production is a page loop: the
# handler fails, which triggers the handler.
reset
run 'harness-unit-failure-alert@backup-harness.service.service' >/dev/null 2>&1 \
  && ok "2a: self-invocation exits 0" || bad "2a: self-invocation exited non-zero"
[ ! -s "$TMP/calls" ] && ok "2b: self-invocation sent no page" || bad "2b: ALERT LOOP — the alerter paged about itself"

# The guard is suffix-scoped, so a same-prefix unit of a DIFFERENT type is still
# reportable. OnFailure= only ever produces .service, so this cannot widen the
# loop it guards against.
reset
run 'harness-unit-failure-alert@backup-harness.service.timer' >/dev/null 2>&1 || true
[ "$(pages)" -eq 1 ] && ok "2c: self-guard is .service-scoped, not prefix-only" \
  || bad "2c: a same-prefix .timer was wrongly suppressed"

# ── 3. cooldown suppresses a repeat page for the same unit ───────────────────
reset
run backup-harness.service >/dev/null 2>&1
run backup-harness.service >/dev/null 2>&1
[ "$(pages)" -eq 1 ] && ok "3: second failure inside the cooldown did not double-page" \
  || bad "3: cooldown did not suppress (pages: $(pages))"

# ── 4. a different unit is never suppressed by another unit's cooldown ───────
reset
run backup-harness.service >/dev/null 2>&1
run skills-update.service >/dev/null 2>&1
[ "$(pages)" -eq 2 ] && ok "4: cooldown is per-unit, not global" \
  || bad "4: one unit's cooldown swallowed another unit's failure"

# ── 4b. units whose names collapse to the same sanitized filename ────────────
# `tr -c 'A-Za-z0-9._@-' '_'` maps both of these to alpha_beta.service. Without
# a digest on the stamp name, the first would mute the second.
reset
run 'alpha:beta.service' >/dev/null 2>&1
run 'alpha_beta.service' >/dev/null 2>&1
[ "$(pages)" -eq 2 ] && ok "4b: sanitized-name collision does not cross-mute units" \
  || bad "4b: two distinct units shared one cooldown stamp (pages: $(pages))"

# ── 5. an expired cooldown pages again ───────────────────────────────────────
reset
run backup-harness.service >/dev/null 2>&1
plant_stamps 1 || bad "5: no stamp was created to expire"   # epoch 1 = 1970
run backup-harness.service >/dev/null 2>&1
[ "$(pages)" -eq 2 ] && ok "5: an expired cooldown pages again" || bad "5: expired cooldown still suppressed"

# ── 5b. REGRESSION: a leading-zero stamp must not raise an interpreter error ──
# `08` is valid OCTAL to $(( )) and fails evaluation. Measured: at this call site
# that is NOT fatal — the expansion is inside `[ ... ]`, so bash writes to stderr
# and the alerter still pages. So asserting "it paged" is VACUOUS: that holds
# with or without the fix. The real difference is a silently dead cooldown and a
# bash error in the unit log that reads like a bug in the alerter. Assert THAT.
reset
run backup-harness.service >/dev/null 2>&1
plant_stamps 08 || bad "5b: no stamp was created to corrupt"
rc=0
err=$(run backup-harness.service 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 0 ] && ok "5b: leading-zero stamp did not abort the alerter" \
  || bad "5b: alerter died (exit $rc) on an octal-looking stamp"
grep -q 'value too great for base' <<<"$err" \
  && bad "5b: octal stamp raised a bash arithmetic error: $err" \
  || ok "5b: leading-zero stamp produced no interpreter error"
# The cooldown must still be honoured for that unit rather than silently dying:
# 08 -> 8 (epoch 1970) is far outside the window, so this run pages.
[ "$(pages)" -eq 2 ] && ok "5b: expired octal stamp pages, cooldown still evaluated" \
  || bad "5b: octal stamp swallowed the page (pages: $(pages))"

# ── 5c. a future-dated stamp must not mute an unbounded window ───────────────
# Clock skew or a planted file would otherwise suppress every page until the
# stamp's date arrives.
reset
run backup-harness.service >/dev/null 2>&1
plant_stamps "$(( $(date +%s) + 999999 ))" || bad "5c: no stamp was created"
run backup-harness.service >/dev/null 2>&1
[ "$(pages)" -eq 2 ] && ok "5c: future-dated stamp did not suppress the page" \
  || bad "5c: a future stamp muted the alerter (pages: $(pages))"

# ── 6. PLANTED NEGATIVE: a failed send must not consume the cooldown ─────────
# Stamping before knowing the send worked would let one broken webhook silence
# the next hour of real failures.
reset
( export TEST_NOTIFY_RC=1; run backup-harness.service >/dev/null 2>&1 ) \
  && bad "6a: alerter reported success on a failed send" || ok "6a: failed send exits non-zero"
[ -z "$(ls -A "$TMP/stamps" 2>/dev/null)" ] \
  && ok "6b: failed send left no cooldown stamp" || bad "6b: failed send stamped, silencing the retry"
run backup-harness.service >/dev/null 2>&1
[ "$(pages)" -eq 2 ] && ok "6c: retry after a failed send pages" || bad "6c: retry was suppressed"

# ── 7. usage and a missing notifier fail loudly, never silently ──────────────
rc=0; PATH="$TMP/bin:$PATH" UNIT_ALERT_TEST_MODE=1 UNIT_ALERT_STAMP_DIR="$TMP/stamps" \
  /usr/bin/bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "7a: no-argument call exits 2" || bad "7a: no-argument exit was $rc, expected 2"
# Clear the stamps: an earlier case's cooldown must not decide this one, and a
# missing notifier has to be reported on EVERY invocation, cooldown or not.
rm -f "$TMP/stamps"/*
rc=0
err=$(PATH="$TMP/bin:$PATH" UNIT_ALERT_TEST_MODE=1 \
  DISCORD_NOTIFY_BIN="$TMP/bin/does-not-exist" UNIT_ALERT_STAMP_DIR="$TMP/stamps" \
  /usr/bin/bash "$SCRIPT" backup-harness.service 2>&1) || rc=$?
[ "$rc" -ne 0 ] && ok "7b: missing notifier exits non-zero" || bad "7b: missing notifier exited 0"
# It must still say what failed, since this is the path where nothing can page.
grep -q 'backup-harness.service' <<<"$err" && ok "7c: missing notifier still logs the failed unit" \
  || bad "7c: missing notifier lost the diagnostic: $err"

# ── 7d. an unusable cooldown value is reported, not silently ignored ─────────
reset
msg=$( export UNIT_ALERT_COOLDOWN=not-a-number; run backup-harness.service 2>&1 >/dev/null ) || true
grep -q 'UNIT_ALERT_COOLDOWN' <<<"$msg" \
  && ok "7d: unusable cooldown is named on stderr" || bad "7d: bad cooldown was swallowed silently: $msg"
[ "$(pages)" -eq 1 ] && ok "7d: unusable cooldown still pages" || bad "7d: bad cooldown blocked the page"

# ── 8. DEPLOY-SHAPED: the DEFAULT notifier resolves next to the script ───────
# Every case above injects DISCORD_NOTIFY_BIN, so none of them exercise HERE.
# This one copies the script into a scratch directory beside a stub named
# discord-notify.sh, runs it with NO override and with that directory OFF PATH,
# and asserts the sibling stub was executed. It therefore fails if HERE breaks,
# if the default becomes a bare PATH name (the tokscale bug), or if the sibling
# filename changes — none of which source-text parsing can detect.
mkdir -p "$TMP/deploy"
cp "$SCRIPT" "$TMP/deploy/unit-failure-alert.sh"
cat > "$TMP/deploy/discord-notify.sh" <<'EOF'
#!/usr/bin/env bash
printf 'SIBLING-NOTIFIER-RAN\n' >>"${TEST_CALLS:?}"
cat >>"${TEST_CALLS:?}"
printf '\n===END===\n' >>"${TEST_CALLS:?}"
EOF
chmod +x "$TMP/deploy/unit-failure-alert.sh" "$TMP/deploy/discord-notify.sh"
reset
rc=0
PATH="$TMP/bin:$PATH" UNIT_ALERT_TEST_MODE=1 UNIT_ALERT_STAMP_DIR="$TMP/stamps" TEST_CALLS="$TMP/calls" \
  /usr/bin/bash "$TMP/deploy/unit-failure-alert.sh" backup-harness.service >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "8a: script run from its deploy dir exits 0" || bad "8a: deploy-dir run exited $rc"
grep -q 'SIBLING-NOTIFIER-RAN' "$TMP/calls" \
  && ok "8b: default resolved to the sibling discord-notify.sh (HERE works)" \
  || bad "8b: default notifier did NOT resolve to the script's own directory"
# Same run, through a symlink: units invoke ~/.claude/scripts/... which is a
# symlink into the checkout, so readlink -f in HERE is load-bearing.
mkdir -p "$TMP/linkdir"
ln -sf "$TMP/deploy/unit-failure-alert.sh" "$TMP/linkdir/unit-failure-alert.sh"
reset
PATH="$TMP/bin:$PATH" UNIT_ALERT_TEST_MODE=1 UNIT_ALERT_STAMP_DIR="$TMP/stamps" TEST_CALLS="$TMP/calls" \
  /usr/bin/bash "$TMP/linkdir/unit-failure-alert.sh" backup-harness.service >/dev/null 2>&1 || true
grep -q 'SIBLING-NOTIFIER-RAN' "$TMP/calls" \
  && ok "8c: resolves through a symlink to the real sibling" \
  || bad "8c: symlinked invocation lost the sibling notifier"
# And the real repo copy must actually have that sibling present.
[ -x scripts/discord-notify.sh ] \
  && ok "8d: scripts/discord-notify.sh exists and is executable" \
  || bad "8d: the real sibling notifier is missing from the repo"

# ── 8e. the journal tail cannot break out of the Discord code fence ──────────
# The tail is whatever the failing unit last wrote to stdout — attacker-
# influenced. A line containing a triple backtick closes our fence, after which
# @everyone renders as a live mention and pings the server for real.
reset
( export TEST_JOURNAL='oops
```
@everyone click https://evil.example
```bash'
  run backup-harness.service >/dev/null 2>&1 ) || true
fences=$(grep -c '```' "$TMP/calls" || true)
[ "$fences" -eq 2 ] && ok "8e: only our own two fences survive (found $fences)" \
  || bad "8e: journal tail broke out of the code fence (found $fences fence markers, expected 2)"
grep -q '@everyone' "$TMP/calls" \
  && bad "8e: a live @everyone mention reached the page" || ok "8e: @everyone was defanged"

# ── 8f. an ordinary tail is not mangled by the neutralizer ──────────────────
reset
( export TEST_JOURNAL='rsync: connection unexpectedly closed'; run backup-harness.service >/dev/null 2>&1 ) || true
grep -q 'rsync: connection unexpectedly closed' "$TMP/calls" \
  && ok "8f: ordinary journal text passes through unchanged" || bad "8f: neutralizer corrupted ordinary output"

# ── 8g. the journal tail is scoped to the failed invocation ─────────────────
# `journalctl -u <unit> -n 20` is unit HISTORY, and journalctl prints
# oldest-first, so a page can end on a LATER successful run's output. Measured
# on the dev host: the unscoped tail ended with "Finished ... successfully"
# while reporting a FAILURE.
reset
: >"$TMP/jargs"
( export TEST_JARGS="$TMP/jargs"; run backup-harness.service >/dev/null 2>&1 ) || true
grep -q '_SYSTEMD_INVOCATION_ID=' "$TMP/jargs" \
  && ok "8g: journal read is scoped by InvocationID" || bad "8g: journal read was not invocation-scoped: $(cat "$TMP/jargs")"
grep -q 'this invocation' "$TMP/calls" \
  && ok "8g: page labels the tail as invocation-scoped" || bad "8g: page did not label the journal scope"
# When systemd reports no InvocationID the script must fall back AND say so,
# rather than implying a scoping it did not perform.
reset
: >"$TMP/jargs"
( export TEST_INVOCATION=""; export TEST_JARGS="$TMP/jargs"; run backup-harness.service >/dev/null 2>&1 ) || true
grep -q -- '-u backup-harness.service' "$TMP/jargs" \
  && ok "8g: falls back to unit history when no InvocationID" || bad "8g: fallback did not use -u"
grep -q 'may include earlier runs' "$TMP/calls" \
  && ok "8g: fallback is labelled honestly in the page" || bad "8g: unscoped tail was not labelled"

# ── 8h. an unknown exit timestamp is never rendered as the current time ─────
reset
( export TEST_STAMP=""; run backup-harness.service >/dev/null 2>&1 ) || true
grep -q 'at unknown (this alert fired' "$TMP/calls" \
  && ok "8h: unknown exit time is labelled, not silently replaced with now" \
  || bad "8h: page presented a fabricated exit timestamp"

# ── 8i. zero journal lines is an enforced privacy policy, not `-n 0` ────────
reset
: >"$TMP/jargs"
(
  export UNIT_ALERT_JOURNAL_LINES=0
  export TEST_JARGS="$TMP/jargs"
  export TEST_JOURNAL='PRIVATE JOURNAL CONTENT'
  run private-journal.service >/dev/null 2>&1
) || true
[ ! -s "$TMP/jargs" ]   && ok "8i: zero-line privacy policy makes no journalctl call"   || bad "8i: privacy policy still invoked journalctl: $(cat "$TMP/jargs")"
if grep -q 'PRIVATE JOURNAL CONTENT' "$TMP/calls"; then
  bad "8i: private journal content entered the alert body"
else
  ok "8i: private alert body contains no journal content"
fi
grep -q 'journal content suppressed by unit privacy policy' "$TMP/calls"   && ok "8i: privacy omission is labelled in the page"   || bad "8i: privacy-safe page does not explain the omitted journal"

# ── 8j. real wrapper failure survives successful ExecStopPost cleanup ──────
# Only the external JSM/journal/systemctl/notifier boundaries are local stubs.
# Native markers intentionally lack stdout's trusted invocation field: logger
# can exit before journald resolves its cgroup. Its explicit invocation survives.
cat >"$TMP/bin/logger" <<'EOF'
#!/usr/bin/env bash
[ "$*" = --journald ] || exit 92
jq -Rn 'reduce inputs as $line ({}; ($line | index("=")) as $i |
  if $i == null then . else .[$line[:$i]] = $line[$i+1:] end)' >>"${TEST_MARKERS:?}"
EOF
cat >"$TMP/bin/jsm" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'upgrade --list --json')
    echo '{"updates":['
    for skill in alpha-skill bravo-skill charlie-skill delta-skill; do
      printf '{"name":"%s","pinned":false,"update_available":true},\n' "$skill"
    done
    echo '{"name":"echo-skill","pinned":false,"update_available":true}]}' ;;
  'config show --json') echo '{"values":{"skills":{}}}' ;;
  'upgrade '*-skill)
    printf 'Failed:\n  • %s - User prompt error: IO error: not a terminal\n' "$2"
    echo 'PRIVATE_TOKEN https://discord.com/api/webhooks/PRIVATE_WEBHOOK'
    exit 47 ;;
  *) exit 92 ;;
esac
EOF
chmod +x "$TMP/bin/logger" "$TMP/bin/jsm"
failed_invocation=282b9a9bf6eb486aaa4dc81424feb4db
: >"$TMP/markers"
rc=0
PATH="$TMP/bin:$PATH" TMPDIR="$TMP" INVOCATION_ID="$failed_invocation" \
  JSM_BIN="$TMP/bin/jsm" TEST_MARKERS="$TMP/markers" \
  bash scripts/jsm-auto-update-wrapper.sh >"$TMP/jsm-output" 2>&1 || rc=$?
[ "$rc" -eq 47 ] && ok "8j: real wrapper preserves the failed upgrade exit" \
  || bad "8j: real wrapper returned $rc instead of 47"
jq -Rnc --arg inv "$failed_invocation" 'inputs | {MESSAGE: ., _SYSTEMD_INVOCATION_ID: $inv}' \
  <"$TMP/jsm-output" >"$TMP/journal"
cat "$TMP/markers" >>"$TMP/journal"
for ((i=1; i<=66; i++)); do
  printf 'skills-localize: cleanup %s succeeded\n' "$i"
done | jq -Rnc --arg inv "$failed_invocation" 'inputs | {MESSAGE: ., _SYSTEMD_INVOCATION_ID: $inv}' >>"$TMP/journal"

run_jsm_alert() {
  TEST_INVOCATION="$failed_invocation" TEST_JOURNAL_FILE="$TMP/journal" \
    TEST_JARGS="$TMP/jargs" run jsm-auto-update.service
}
reset
: >"$TMP/jargs"
run_jsm_alert >/dev/null 2>&1 || bad "8j: alerter failed for the cleanup reproduction"
grep -q 'needs manual attention.*terminal' "$TMP/calls" \
  && ok "8j: notifier receives the noninteractive prompt cause after 66 cleanup lines" \
  || bad "8j: cleanup displaced the failure cause in the real notifier body"
if grep -q 'alpha-skill.*bravo-skill.*charlie-skill.*delta-skill.*echo-skill' "$TMP/calls"; then
  ok "8j: notifier names all five affected skills"
else
  bad "8j: affected skill names were lost"
fi
grep -q 'Review.*interactively' "$TMP/calls" && ok "8j: page gives a manual next action" \
  || bad "8j: page has no manual next action"
if grep -Eq 'cleanup|PRIVATE_TOKEN|PRIVATE_WEBHOOK|User prompt error|IO error' "$TMP/calls"; then
  bad "8j: raw JSM output or successful cleanup entered the page"
else
  ok "8j: page uses only the bounded failure summary"
fi
grep -q "JSM_INVOCATION_ID=$failed_invocation" "$TMP/jargs" \
  && ok "8j: summary read is scoped to the exact failed invocation" \
  || bad "8j: no invocation-scoped summary lookup"

# A privacy override must bypass even this structured journal read.
reset
: >"$TMP/jargs"
UNIT_ALERT_JOURNAL_LINES=0 run_jsm_alert >/dev/null 2>&1 || bad "8k: privacy alert failed"
[ ! -s "$TMP/jargs" ] && ok "8k: JSM privacy policy makes zero journal calls" \
  || bad "8k: JSM privacy policy queried the journal"
if grep -Eq 'alpha-skill|manual attention|PRIVATE_' "$TMP/calls"; then
  bad "8k: JSM privacy policy leaked the summary"
else
  ok "8k: privacy alert contains neither summary nor raw output"
fi

reset
rc=0
TEST_NOTIFY_RC=1 run_jsm_alert >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ok "8l: JSM failed delivery is reported" || bad "8l: failed send returned $rc"
[ -z "$(ls -A "$TMP/stamps")" ] && ok "8l: failed summary send consumes no cooldown" \
  || bad "8l: failed summary send stamped cooldown"
run_jsm_alert >/dev/null 2>&1 || bad "8l: JSM retry failed"
[ "$(pages)" -eq 2 ] && ok "8l: failed JSM summary delivery retries" || bad "8l: JSM retry was suppressed"

# OnFailure's context still identifies the failure after a newer successful run.
reset
: >"$TMP/jargs"
MONITOR_UNIT=jsm-auto-update.service MONITOR_INVOCATION_ID="$failed_invocation" \
  MONITOR_SERVICE_RESULT=exit-code MONITOR_EXIT_STATUS=47 \
  TEST_INVOCATION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa TEST_RESULT=success TEST_STATUS=0 \
  TEST_JOURNAL_FILE="$TMP/journal" TEST_JARGS="$TMP/jargs" \
  run jsm-auto-update.service >/dev/null 2>&1 || bad "8m: monitored failure alert failed"
grep -q 'needs manual attention' "$TMP/calls" && ok "8m: OnFailure invocation wins over a newer run" \
  || bad "8m: newer InvocationID displaced the failed run"
grep -q 'Result=exit-code ExecMainStatus=47 at unknown' "$TMP/calls" \
  && ok "8m: OnFailure status is preserved without inventing an old exit timestamp" \
  || bad "8m: alert mixed failure identity with newer result/status/time"

reset
MONITOR_UNIT=unrelated.service MONITOR_INVOCATION_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  MONITOR_SERVICE_RESULT=success MONITOR_EXIT_STATUS=0 run_jsm_alert >/dev/null 2>&1 \
  || bad "8m: unrelated monitor context blocked alert"
grep -q 'needs manual attention' "$TMP/calls" && ok "8m: unrelated monitor context is ignored" \
  || bad "8m: unrelated monitor context changed the invocation"

# Missing/current-unavailable markers never borrow an earlier run's cause.
reset
: >"$TMP/jargs"
TEST_INVOCATION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb TEST_JOURNAL_FILE="$TMP/journal" \
  TEST_JARGS="$TMP/jargs" run jsm-auto-update.service >/dev/null 2>&1 \
  || bad "8n: missing marker prevented generic alert"
if grep -q 'no validated failure summary' "$TMP/calls" && ! grep -q 'alpha-skill' "$TMP/calls"; then
  ok "8n: previous invocation marker is never reused"
else
  bad "8n: alert borrowed a previous invocation summary"
fi
grep -q 'Journal: journalctl --user _SYSTEMD_INVOCATION_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$TMP/calls" \
  && ok "8n: generic JSM fallback gives an invocation-scoped local probe" \
  || bad "8n: generic JSM fallback lost the useful local diagnostic"
reset
: >"$TMP/jargs"
TEST_INVOCATION='' TEST_JOURNAL_FILE="$TMP/journal" TEST_JARGS="$TMP/jargs" \
  run jsm-auto-update.service >/dev/null 2>&1 || bad "8n: absent invocation blocked generic alert"
if [ ! -s "$TMP/jargs" ] && grep -q 'no validated failure summary' "$TMP/calls"; then
  ok "8n: unknown invocation does not search history for a marker"
else
  bad "8n: unknown invocation queried marker history or lost the page"
fi

# Reject malformed/expanded marker values; MESSAGE is never public content.
for mutation in \
  '.JSM_CAUSE = "PRIVATE_CAUSE"' \
  '.JSM_STAGE = ["upgrade", "PRIVATE_STAGE"]' \
  '.JSM_SKILLS = "https://discord.com/api/webhooks/PRIVATE_WEBHOOK"' \
  '.JSM_SKILLS = "a,b,c,d,e,f,g,h,i"' \
  '.JSM_SKILLS = "alpha-skill\n"' \
  '.JSM_SKILLS = null'; do
  reset
  jq -c "$mutation" "$TMP/markers" >"$TMP/invalid-marker"
  TEST_INVOCATION="$failed_invocation" TEST_JOURNAL_FILE="$TMP/invalid-marker" \
    run jsm-auto-update.service >/dev/null 2>&1 || bad "8o: malformed marker blocked generic alert"
  if grep -q 'no validated failure summary' "$TMP/calls" && ! grep -Eq 'PRIVATE_|alpha-skill' "$TMP/calls"; then
    ok "8o: rejects malformed marker ($mutation)"
  else
    bad "8o: malformed marker entered alert ($mutation)"
  fi
done
reset
jq -c '.MESSAGE = "PRIVATE_TOKEN https://discord.com/api/webhooks/PRIVATE_WEBHOOK"' "$TMP/markers" >"$TMP/arbitrary-message"
TEST_INVOCATION="$failed_invocation" TEST_JOURNAL_FILE="$TMP/arbitrary-message" \
  run jsm-auto-update.service >/dev/null 2>&1 || bad "8o: valid fields blocked by arbitrary MESSAGE"
if grep -q 'needs manual attention' "$TMP/calls" && ! grep -q 'PRIVATE_' "$TMP/calls"; then
  ok "8o: ignores arbitrary MESSAGE even on an otherwise valid marker"
else
  bad "8o: raw marker MESSAGE leaked or displaced the cause"
fi
reset
jq -c '.JSM_STAGE = "list" | .JSM_CAUSE = "stage-failed" | .JSM_SKILLS = ""' "$TMP/markers" >"$TMP/list-marker"
TEST_INVOCATION="$failed_invocation" TEST_JOURNAL_FILE="$TMP/list-marker" \
  run jsm-auto-update.service >/dev/null 2>&1 || bad "8o: list-stage marker blocked the alert"
grep -q 'Checking for skill updates failed; no skill was updated' "$TMP/calls" \
  && ok "8o: a failed update check is named as one" \
  || bad "8o: list-stage failure lost its message"

reset
: >"$TMP/jargs"
TEST_JOURNAL_DELAY="$TMP/journal-ready" run_jsm_alert >/dev/null 2>&1 \
  || bad "8p: delayed marker alert failed"
if grep -q 'needs manual attention' "$TMP/calls" && [ "$(wc -l <"$TMP/jargs")" -eq 2 ]; then
  ok "8p: one bounded retry recovers a delayed journal marker"
else
  bad "8p: delayed marker was lost or retried without a bound"
fi
reset
TEST_JOURNAL_RC=124 run_jsm_alert >/dev/null 2>&1 || bad "8p: journal timeout blocked the page"
grep -q 'no validated failure summary' "$TMP/calls" && ok "8p: journal timeout still sends a generic failure" \
  || bad "8p: journal timeout lost the failure alert"
reset
rc=0
PATH="$TMP/bin:$PATH" UNIT_ALERT_TEST_MODE=1 UNIT_ALERT_STAMP_DIR="$TMP/stamps" \
  DISCORD_NOTIFY_BIN="$TMP/bin/notify-stub" TEST_CALLS="$TMP/calls" \
  TEST_INVOCATION="$failed_invocation" TEST_JOURNAL_HANG=1 UNIT_ALERT_JOURNAL_TIMEOUT=0.1 \
  timeout --kill-after=1 6 bash "$SCRIPT" jsm-auto-update.service >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'no validated failure summary' "$TMP/calls"; then
  ok "8p: TERM-ignoring journal is killed within the bounded lookup and still pages"
else
  bad "8p: TERM-ignoring journal blocked the page (outer timeout exit $rc)"
fi

# JSM-specific diagnostics must not swallow a new backup/security incident.
reset
run_jsm_alert >/dev/null 2>&1 || bad "8q: initial JSM alert failed"
TEST_JOURNAL='backup refused: sensitive indicator found' run backup-harness.service >/dev/null 2>&1 \
  || bad "8q: backup security failure alert failed"
if [ "$(pages)" -eq 2 ] && grep -q 'backup refused: sensitive indicator found' "$TMP/calls"; then
  ok "8q: JSM alert cannot mute a backup security failure or its diagnostic"
else
  bad "8q: JSM changes muted backup/security failure"
fi

# ── 9. wiring: the units that must page, and the template that pages ─────────
for u in backup-harness codex-auto-update dcg-auto-update docker-hygiene mcp-servers-update pkg-cache-prune reclaim-sweep skills-update tools-auto-update wt-sweep; do
  grep -qx 'OnFailure=harness-unit-failure-alert@%n.service' "systemd/$u.service" \
    && ok "9: $u.service is wired to the alert template" \
    || bad "9: $u.service has no OnFailure= handler"
done
grep -qx 'ExecStart=%h/.claude/scripts/unit-failure-alert.sh %i' systemd/harness-unit-failure-alert@.service \
  && ok "9: template ExecStart passes the instance name" || bad "9: template ExecStart shape changed"
# jq lives only in ~/.local/bin; without it on the unit PATH discord-notify.sh
# cannot build its payload and every page is a silent no-op.
grep -qx 'Environment=PATH=/usr/bin:/bin' systemd/harness-unit-failure-alert@.service \
  && ok "9: template PATH is root-owned system helpers only" \
  || bad "9: template PATH permits user-writable helper shadowing"
# Units are COPIED by explicit name in sync.sh; an unregistered unit never deploys.
grep -q 'harness-unit-failure-alert@.service' sync.sh \
  && ok "9: template is registered in sync.sh UNITS" || bad "9: template missing from sync.sh UNITS — it would never install"

# ── 10. systemd accepts the units ───────────────────────────────────────────
# ExecStart is rewritten to /bin/true on portable copies because systemd-analyze
# resolves executables on the CURRENT host and CI has no /home/user layout.
# Unit/OnFailure/template semantics are unchanged by that substitution.
for u in harness-unit-failure-alert@.service $(printf '%s.service ' backup-harness codex-auto-update dcg-auto-update docker-hygiene mcp-servers-update pkg-cache-prune reclaim-sweep skills-update tools-auto-update wt-sweep); do
  cp "systemd/$u" "$TMP/$u"
  # Collapse multi-line ExecStart before replacing it, or continuation lines are
  # parsed as stray directives after the first-line rewrite.
  sed -i ':a; /\\$/ { N; s/\\\n[[:space:]]*/ /; ba; }' "$TMP/$u"
  sed -i -e 's|^ExecStart=.*|ExecStart=/bin/true|' \
         -e 's|^ExecCondition=.*|ExecCondition=/bin/true|' \
         -e 's|^ConditionFileIsExecutable=.*|ConditionFileIsExecutable=/bin/true|' "$TMP/$u"
done
verify_args=("$TMP/harness-unit-failure-alert@.service")
for u in backup-harness codex-auto-update dcg-auto-update docker-hygiene mcp-servers-update pkg-cache-prune reclaim-sweep skills-update tools-auto-update wt-sweep; do verify_args+=("$TMP/$u.service"); done
if systemd-analyze verify "${verify_args[@]}" 2>"$TMP/verify.err"; then
  ok "10: systemd-analyze verify accepts the template and all ten wired units"
else
  bad "10: systemd-analyze verify rejected a unit: $(cat "$TMP/verify.err")"
fi

echo "unit-failure-alert: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
