#!/usr/bin/env bash
# supabase-access-token.test.sh: the SUPABASE_ACCESS_TOKEN resolver that
# migration-apply.sh sources (scripts/lib/supabase-access-token.sh) against a
# fake bws.
#
# Hermetic: every case runs the resolver under `env -i` with a HOME fixture, an
# empty BWS_ACCESS_TOKEN/BWS_PROJECT_ID and a PATH that leads with the stub
# directory, so the machine's bws, its config and its ~/.secrets are never read.
# The driver sources the lib under `set -euo pipefail`, the strictest mode a
# caller uses, so a guard that aborts the shell would fail here first.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB="$HERE/scripts/lib/supabase-access-token.sh"
JQ=$(command -v jq) || { echo "jq is required" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
fail() { echo "FAIL: $*" >&2; exit 1; }

ENV_FIXTURE='sbp_envfixture00000000000000000000000000000'
BWS_FIXTURE='sbp_bwsfixture00000000000000000000000000000'
SECRETS_FIXTURE='sbp_secretsfixture0000000000000000000000000'
LISTING_WITH_RECORD='[{"key":"OTHER","value":"x"},{"key":"SUPABASE_ACCESS_TOKEN","value":"'"$BWS_FIXTURE"'"}]'

cat >"$TMP/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
. "$LIB"
rc=0
resolve_supabase_access_token || rc=$?
printf 'rc=%s src=%s tok=%s marker=%s\n' "$rc" "${SUPABASE_ACCESS_TOKEN_SOURCE-}" "${SUPABASE_ACCESS_TOKEN-}" "${SECRETS_MARKER-}"
DRIVER

# The bws stub records every call with the access token it was handed, fails
# the first BWS_FAIL_FIRST calls like a rate limit, then prints BWS_STDOUT.
cat >"$TMP/bin/bws" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$*" "${BWS_ACCESS_TOKEN:-<unset>}" >>"$BWS_CALLS"
if [ "$(wc -l <"$BWS_CALLS")" -le "${BWS_FAIL_FIRST:-0}" ]; then
  echo 'bws: 429 Too Many Requests' >&2
  exit 1
fi
printf '%s\n' "$BWS_STDOUT"
STUB
cat >"$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$TIMEOUT_CALLS"
shift
exec "$@"
STUB
chmod +x "$TMP/bin/bws" "$TMP/bin/timeout"

case_no=0
setup_case() {
  case_no=$((case_no + 1))
  CASE="$TMP/case-$case_no"
  HOME_FIXTURE="$CASE/home"
  BWS_CALLS="$CASE/bws-calls"
  TIMEOUT_CALLS="$CASE/timeout-calls"
  mkdir -p "$HOME_FIXTURE"
  : >"$BWS_CALLS"
  : >"$TIMEOUT_CALLS"
  BWS_STDOUT="$LISTING_WITH_RECORD"
  BWS_FAIL_FIRST=0
  ENV_TOKEN=''
}
bws_configured() {
  mkdir -p "$HOME_FIXTURE/.config/bws"
  printf 'bws-access-fixture\n' >"$HOME_FIXTURE/.config/bws/token"
  printf 'project-fixture\n' >"$HOME_FIXTURE/.config/bws/sb-project-id"
}
secrets_file() {
  # SECRETS_MARKER proves whether the file was sourced at all.
  printf 'export SUPABASE_ACCESS_TOKEN=%s\nSECRETS_MARKER=sourced\n' "$SECRETS_FIXTURE" >"$HOME_FIXTURE/.secrets"
}
resolve() {
  # $@ = extra NAME=value pairs for the driver's environment.
  set +e
  OUT=$(env -i HOME="$HOME_FIXTURE" PATH="$TMP/bin:/usr/bin:/bin" LIB="$LIB" JQ_BIN="$JQ" \
    BWS_CALLS="$BWS_CALLS" TIMEOUT_CALLS="$TIMEOUT_CALLS" BWS_STDOUT="$BWS_STDOUT" BWS_FAIL_FIRST="$BWS_FAIL_FIRST" \
    BWS_ACCESS_TOKEN= BWS_PROJECT_ID= SUPABASE_ACCESS_TOKEN="$ENV_TOKEN" "$@" \
    bash "$TMP/driver.sh" 2>"$CASE/stderr")
  RC=$?
  set -e
}
assert_out() {
  # The driver reports the resolver's status in its line and must itself exit 0:
  # a non-zero RC means a guard aborted the `set -e` shell instead of returning.
  [ "$RC" = 0 ] || fail "$1: the driver shell aborted with $RC (stderr: $(cat "$CASE/stderr"))"
  [ "$OUT" = "$2" ] || fail "$1: expected '$2', got '$OUT' (stderr: $(cat "$CASE/stderr"))"
}
assert_calls() {
  [ "$(wc -l <"$BWS_CALLS")" = "$2" ] || fail "$1: expected $2 bws call(s), saw $(wc -l <"$BWS_CALLS"): $(tr '\n' '|' <"$BWS_CALLS")"
}

# 1. An env token wins untouched and bws is never consulted.
setup_case; bws_configured; secrets_file
ENV_TOKEN="$ENV_FIXTURE"
resolve
assert_out "1: env wins" "rc=0 src=env tok=$ENV_FIXTURE marker="
assert_calls "1: env wins without a bws call" 0

# 2. bws answers with the record: it wins over ~/.secrets, which is not even
# sourced; the listing ran once under timeout 30 with the configured project and
# access token.
setup_case; bws_configured; secrets_file
resolve
assert_out "2: bws record resolves" "rc=0 src=bws tok=$BWS_FIXTURE marker="
assert_calls "2: one listing" 1
[ "$(cat "$BWS_CALLS")" = '--color no secret list project-fixture|bws-access-fixture' ] \
  || fail "2: unexpected bws argv or access token: $(cat "$BWS_CALLS")"
[ "$(cat "$TIMEOUT_CALLS")" = 30 ] || fail "2: the listing must run under timeout 30, saw: $(cat "$TIMEOUT_CALLS")"

# 3. bws env variables outrank the config files.
setup_case; bws_configured
resolve BWS_ACCESS_TOKEN=env-access BWS_PROJECT_ID=env-project
assert_out "3: bws env overrides" "rc=0 src=bws tok=$BWS_FIXTURE marker="
[ "$(cat "$BWS_CALLS")" = '--color no secret list env-project|env-access' ] \
  || fail "3: expected the env project and access token: $(cat "$BWS_CALLS")"

# 4. One transient bws failure is retried and the retry's answer wins.
setup_case; bws_configured; secrets_file
BWS_FAIL_FIRST=1
resolve
assert_out "4: one failure is retried" "rc=0 src=bws tok=$BWS_FIXTURE marker="
assert_calls "4: exactly one retry" 2

# 5. Two bws failures fall through to ~/.secrets (sourced, as before).
setup_case; bws_configured; secrets_file
BWS_FAIL_FIRST=2
resolve
assert_out "5: two failures fall through" "rc=0 src=~/.secrets tok=$SECRETS_FIXTURE marker=sourced"
assert_calls "5: no third attempt" 2

# 6. PLANTED NEGATIVE: two bws failures and no ~/.secrets resolve nothing.
setup_case; bws_configured
BWS_FAIL_FIRST=2
resolve
assert_out "6: nothing resolves" "rc=1 src= tok= marker="
assert_calls "6: still exactly two attempts" 2

# 7. A listing without the record falls through to ~/.secrets.
setup_case; bws_configured; secrets_file
BWS_STDOUT='[{"key":"OTHER","value":"x"}]'
resolve
assert_out "7: absent record falls through" "rc=0 src=~/.secrets tok=$SECRETS_FIXTURE marker=sourced"
assert_calls "7: one listing" 1

# 8. A listing that is not JSON counts as a failed read, not a missing record.
setup_case; bws_configured; secrets_file
BWS_STDOUT='not json'
resolve
assert_out "8: unreadable listing falls through" "rc=0 src=~/.secrets tok=$SECRETS_FIXTURE marker=sourced"

# 9. PLANTED NEGATIVE: a record that is not an sbp_ token stops the resolution
# (rc 2) and ~/.secrets is not sourced to paper over it.
setup_case; bws_configured; secrets_file
BWS_STDOUT='[{"key":"SUPABASE_ACCESS_TOKEN","value":"sbp_short"}]'
resolve
assert_out "9: malformed record refused" "rc=2 src= tok= marker="
grep -q 'is not a personal access token' "$CASE/stderr" || fail "9: the refusal must name the record (stderr: $(cat "$CASE/stderr"))"

# 10. BWS_BIN set but empty means "no bws" even with one on PATH.
setup_case; bws_configured; secrets_file
resolve BWS_BIN=
assert_out "10: BWS_BIN= disables bws" "rc=0 src=~/.secrets tok=$SECRETS_FIXTURE marker=sourced"
assert_calls "10: no bws call" 0

# 11. bws on PATH but unconfigured (no access token or project) is skipped.
setup_case; secrets_file
resolve
assert_out "11: unconfigured bws is skipped" "rc=0 src=~/.secrets tok=$SECRETS_FIXTURE marker=sourced"
assert_calls "11: no bws call" 0

# 12. Nothing anywhere: rc 1 and an empty token.
setup_case
resolve
assert_out "12: no source at all" "rc=1 src= tok= marker="

# 13. PLANTED NEGATIVE (dotfiles#1960): a record whose value is not a string is present
# but unusable: rc 2, and ~/.secrets is not sourced to paper over it. Before the
# fix the jq `strings` filter dropped the value and the record read as absent.
setup_case; bws_configured; secrets_file
BWS_STDOUT='[{"key":"SUPABASE_ACCESS_TOKEN","value":42}]'
resolve
assert_out "13: non-string record refused" "rc=2 src= tok= marker="
grep -q 'its value is a number' "$CASE/stderr" || fail "13: the refusal must name the JSON type (stderr: $(cat "$CASE/stderr"))"
assert_calls "13: one listing" 1

# 14. PLANTED NEGATIVE (dotfiles#1960): a null value is a present record, not an absent one.
setup_case; bws_configured; secrets_file
BWS_STDOUT='[{"key":"SUPABASE_ACCESS_TOKEN","value":null}]'
resolve
assert_out "14: null record refused" "rc=2 src= tok= marker="
grep -q 'its value is null' "$CASE/stderr" || fail "14: the refusal must say null (stderr: $(cat "$CASE/stderr"))"

# 15. PLANTED NEGATIVE (dotfiles#1960): an empty string is a present record, not an absent one.
setup_case; bws_configured; secrets_file
BWS_STDOUT='[{"key":"SUPABASE_ACCESS_TOKEN","value":""}]'
resolve
assert_out "15: empty record refused" "rc=2 src= tok= marker="
grep -q 'its value is an empty string' "$CASE/stderr" || fail "15: the refusal must say empty (stderr: $(cat "$CASE/stderr"))"

echo "ok — supabase-access-token: 15 scenarios passed (env > bws > ~/.secrets, one retry, malformed, non-string and empty records refused, hermetic bws)"
