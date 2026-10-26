#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/bin/with-gemini-sandbox"
TMP="${TMPDIR:-/tmp}/with-gemini-sandbox-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.config/bws"
printf 'test-token\n' >"$TMP/home/.config/bws/token"
REAL_JQ=$(command -v jq)
VALID_KEY='AQ.test-sandbox-credential-123'
export GEMINI_SANDBOX_BWS_ID=00000000-0000-4000-8000-000000000000
export BWS_CALLS="$TMP/bws.calls"

cat >"$TMP/bin/bws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'call\n' >>"$BWS_CALLS"
expected='--color no secret get 00000000-0000-4000-8000-000000000000'
[[ "$*" == "$expected" ]]
[[ ${BWS_ACCESS_TOKEN:-} == test-token ]]
printf '{"value":"%s"}\n' "${BWS_TEST_VALUE:-AQ.test-sandbox-credential-123}"
EOF

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  printf '%s\n' '[[ ! ${BWS_ACCESS_TOKEN+x} ]]'
  printf 'exec %q "$@"\n' "$REAL_JQ"
} >"$TMP/bin/jq"
chmod +x "$TMP/bin/bws" "$TMP/bin/jq"

result=$(
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" BWS_TEST_VALUE="$VALID_KEY" \
    "$SCRIPT" bash -c '
      [[ $GEMINI_API_KEY == AQ.test-sandbox-credential-123 ]]
      [[ $GOOGLE_API_KEY == AQ.test-sandbox-credential-123 ]]
      [[ $GOOGLE_GENERATIVE_AI_API_KEY == AQ.test-sandbox-credential-123 ]]
      [[ ! ${BWS_ACCESS_TOKEN+x} ]]
      printf ok
    '
)
[[ $result == ok ]]

trace="$TMP/xtrace.log"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" BWS_TEST_VALUE="$VALID_KEY" \
  bash -x "$SCRIPT" true 2>"$trace"
! grep -qF 'test-token' "$trace"
! grep -qF "$VALID_KEY" "$trace"

set +e
HOME="$TMP/home" PATH="$TMP/bin:$PATH" "$SCRIPT" >/dev/null 2>&1
no_args_status=$?
set -e
[[ $no_args_status == 64 ]]

for invalid in 'AIza-not-an-auth-key' 'AQ.' 'AQ.short' 'AQ.contains whitespace credential'; do
  set +e
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" BWS_TEST_VALUE="$invalid" \
    "$SCRIPT" true >/dev/null 2>&1
  status=$?
  set -e
  [[ $status == 1 ]]
done

rm -f "$BWS_CALLS"
set +e
missing_err=$(env -u GEMINI_SANDBOX_BWS_ID HOME="$TMP/home" PATH="$TMP/bin:$PATH" "$SCRIPT" true 2>&1 >/dev/null)
missing_status=$?
set -e
[[ $missing_status == 1 ]]
[[ $missing_err == *GEMINI_SANDBOX_BWS_ID* ]]

for invalid_id in 'not-a-uuid' '00000000-0000-4000-8000-000000000000 --x'; do
  set +e
  GEMINI_SANDBOX_BWS_ID="$invalid_id" HOME="$TMP/home" PATH="$TMP/bin:$PATH" "$SCRIPT" true >/dev/null 2>&1
  status=$?
  set -e
  [[ $status == 1 ]]
done
[[ ! -e $BWS_CALLS ]]

echo "with-gemini-sandbox: 12/12 passed"
