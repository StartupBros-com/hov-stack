#!/usr/bin/env bash
# Focused regressions for announce()'s bounded canonical Retry-After behavior.
# Stubs token mint, HTTP send, and sleep; no network or real waiting occurs.
# shellcheck disable=SC2030,SC2031,SC2317,SC2329
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$HERE")")"
PASS=0
FAIL=0

setup() {
  WORK="$(mktemp -d)" || exit 1
  STUB_SCENARIO="$WORK/scenario"
  STUB_CALLS="$WORK/calls"
  STUB_SLEEPS="$WORK/sleeps"
  STUB_MINTS="$WORK/mints"
  STUB_AUDIENCES="$WORK/audiences"
  STUB_BODY="$WORK/body"
  STUB_POST_TOKENS="$WORK/post-tokens"
  : >"$STUB_CALLS"
  : >"$STUB_SLEEPS"
  : >"$STUB_MINTS"
  : >"$STUB_AUDIENCES"
  : >"$STUB_BODY"
  : >"$STUB_POST_TOKENS"

  export REPOSITORY="stub-repo" PLUGIN_NAME="stub-repo" RELEASE_ID="1"
  export CURRENT_RELEASE_NOTES=""
  # shellcheck source=/dev/null
  source "$REPO_ROOT/release/scripts/tool-drop-announce.sh"

  mint_oidc_token() {
    printf '%s\n' "$1" >>"$STUB_AUDIENCES"
    printf 'mint\n' >>"$STUB_MINTS"
    printf 'stub-token-%s\n' "$(wc -l <"$STUB_MINTS")"
  }

  send_request() {
    local request_body="$1" oidc_token="$3" response_body="$4" response_headers="$5" status_name="$6"
    local line_no line status body retry_after
    printf '%s\n' "$oidc_token" >>"$STUB_POST_TOKENS"
    printf '%s' "$request_body" >"$STUB_BODY"
    printf 'post\n' >>"$STUB_CALLS"
    line_no="$(wc -l <"$STUB_CALLS")"
    line="$(sed -n "${line_no}p" "$STUB_SCENARIO")"
    status="${line%% *}"
    line="${line#* }"
    body="${line%% *}"
    retry_after="${line#* }"
    printf '%s' "$body" >"$response_body"
    printf 'HTTP/1.1 %s Fixture\r\n' "$status" >"$response_headers"
    if [[ "$retry_after" != "$line" && -n "$retry_after" ]]; then
      printf 'Retry-After: %s\r\n' "$retry_after" >>"$response_headers"
    fi
    printf '\r\n' >>"$response_headers"
    printf -v "$status_name" '%s' "$status"
  }

  sleep() {
    printf '%s\n' "$1" >>"$STUB_SLEEPS"
  }
}

report() {
  if [[ "$2" == 0 ]]; then
    printf 'ok - %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf 'not ok - %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

(
  setup
  printf '200 posted\n' >"$STUB_SCENARIO"
  out="$(announce)" || exit 1
  [[ "$out" == *posted ]] || exit 1
  [[ "$(wc -l <"$STUB_CALLS")" == 1 ]] || exit 1
  [[ "$(wc -l <"$STUB_MINTS")" == 1 ]] || exit 1
  [[ ! -s "$STUB_SLEEPS" ]] || exit 1
)
report "200 succeeds on the first freshly minted token" $?

(
  setup
  printf '429 limited 3\n200 posted\n' >"$STUB_SCENARIO"
  out="$(announce)" || exit 1
  [[ "$out" == *posted ]] || exit 1
  [[ "$(wc -l <"$STUB_CALLS")" == 2 ]] || exit 1
  [[ "$(wc -l <"$STUB_MINTS")" == 2 ]] || exit 1
  jitter="$(retry_jitter_seconds "$REPOSITORY" "$RELEASE_ID" 1)"
  [[ "$(<"$STUB_SLEEPS")" == "$((3 + RETRY_LEASE_EXPIRY_CUSHION_SECONDS + jitter))" ]] || exit 1
)
report "canonical 429 retries with cushion and deterministic jitter" $?

(
  setup
  printf '400 bad\n200 posted\n' >"$STUB_SCENARIO"
  if (announce) >/dev/null 2>&1; then exit 1; fi
  [[ "$(wc -l <"$STUB_CALLS")" == 1 ]] || exit 1
  [[ "$(wc -l <"$STUB_MINTS")" == 1 ]] || exit 1
  [[ ! -s "$STUB_SLEEPS" ]] || exit 1
)
report "400 fails immediately without retry (planted negative)" $?

(
  setup
  for _ in $(seq 1 "$ANNOUNCE_MAX_ATTEMPTS"); do
    printf '409 busy 2\n'
  done >"$STUB_SCENARIO"
  if (announce) >/dev/null 2>&1; then exit 1; fi
  [[ "$(wc -l <"$STUB_CALLS")" == "$ANNOUNCE_MAX_ATTEMPTS" ]] || exit 1
  [[ "$(wc -l <"$STUB_MINTS")" == "$ANNOUNCE_MAX_ATTEMPTS" ]] || exit 1
  [[ "$(wc -l <"$STUB_SLEEPS")" == "$((ANNOUNCE_MAX_ATTEMPTS - 1))" ]] || exit 1
)
report "persistent canonical 409 exhausts eight attempts without a ninth" $?

(
  setup
  export EVENT_ACTION=published RELEASE_TAG=v1.2.3 LATEST_STABLE_ID=1
  export SOURCE_ROOT="$WORK/source" SOURCE_SHA=fixture MARKETPLACE_MANIFEST="$WORK/manifest.json"
  out="$(main 2>&1)" && exit 1
  [[ "$out" == 'error: CURRENT_RELEASE_FILE is required' ]] || exit 1
  [[ ! -s "$STUB_MINTS" && ! -s "$STUB_CALLS" ]] || exit 1
)
report "main fails fast with a clear message when CURRENT_RELEASE_FILE is unset" $?

# --- promotion-propagation 403 -------------------------------------------------
# Observed on pro-gate v0.41.0 (2026-09-09): the announce POSTed 61s after its marketplace
# repin merged and got 403 "release does not match the marketplace promotion" although the
# manifest already pinned the correct commit; a later re-run succeeded. v0.42.0's gap was
# 77s and passed, so ordering does not close it -- only a retry does.
promotion_lag_body='{"success":false,"error":"release does not match the marketplace promotion"}'

(
  setup
  send_request() {
    local response_body="$4" response_headers="$5" status_name="$6" n
    printf 'post\n' >>"$STUB_CALLS"
    n="$(wc -l <"$STUB_CALLS")"
    : >"$response_headers"
    if ((n < 3)); then
      printf '%s' "$promotion_lag_body" >"$response_body"
      printf -v "$status_name" '%s' 403
    else
      printf '%s' '{"success":true,"status":"announced","messageId":"1"}' >"$response_body"
      printf -v "$status_name" '%s' 200
    fi
  }
  out="$(announce)" || exit 1
  [[ "$out" == *announced* ]] || exit 1
  [[ "$(wc -l <"$STUB_CALLS")" == 3 ]] || exit 1
  # The fixed backoff is used because this 403 carries no Retry-After at all.
  j1="$(retry_jitter_seconds "$REPOSITORY" "$RELEASE_ID" 1)"
  j2="$(retry_jitter_seconds "$REPOSITORY" "$RELEASE_ID" 2)"
  [[ "$(<"$STUB_SLEEPS")" == "$((PROMOTION_LAG_RETRY_SECONDS + RETRY_LEASE_EXPIRY_CUSHION_SECONDS + j1))
$((PROMOTION_LAG_RETRY_SECONDS + RETRY_LEASE_EXPIRY_CUSHION_SECONDS + j2))" ]] || exit 1
)
report "promotion-lag 403 retries on a fixed backoff with no Retry-After, then succeeds" $?

# The safety half. Widening a 403 must not soften an authorization refusal: anything but the
# exact promotion message has to die on attempt one, as every 403 did before this change.
(
  setup
  send_request() {
    local response_body="$4" response_headers="$5" status_name="$6"
    printf 'post\n' >>"$STUB_CALLS"
    : >"$response_headers"
    printf '%s' '{"success":false,"error":"missing or invalid OIDC token"}' >"$response_body"
    printf -v "$status_name" '%s' 403
  }
  if (announce) >/dev/null 2>&1; then exit 1; fi
  [[ "$(wc -l <"$STUB_CALLS")" == 1 ]] || exit 1
  [[ ! -s "$STUB_SLEEPS" ]] || exit 1
)
report "a 403 that is not the promotion lag stays terminal on the first attempt" $?

# A body jq cannot read must not be guessed at: unparseable reads as not-retryable.
(
  setup
  send_request() {
    local response_body="$4" response_headers="$5" status_name="$6"
    printf 'post\n' >>"$STUB_CALLS"
    : >"$response_headers"
    printf '%s' '<html>403 Forbidden</html>' >"$response_body"
    printf -v "$status_name" '%s' 403
  }
  if (announce) >/dev/null 2>&1; then exit 1; fi
  [[ "$(wc -l <"$STUB_CALLS")" == 1 ]] || exit 1
  [[ ! -s "$STUB_SLEEPS" ]] || exit 1
)
report "a 403 with a non-JSON body fails closed instead of retrying" $?

# Bounded, like the 409/429 path: a lag that never clears still ends.
(
  setup
  send_request() {
    local response_body="$4" response_headers="$5" status_name="$6"
    printf 'post\n' >>"$STUB_CALLS"
    : >"$response_headers"
    printf '%s' "$promotion_lag_body" >"$response_body"
    printf -v "$status_name" '%s' 403
  }
  if (announce) >/dev/null 2>&1; then exit 1; fi
  [[ "$(wc -l <"$STUB_CALLS")" == "$ANNOUNCE_MAX_ATTEMPTS" ]] || exit 1
  [[ "$(wc -l <"$STUB_SLEEPS")" == "$((ANNOUNCE_MAX_ATTEMPTS - 1))" ]] || exit 1
)
report "a promotion lag that never clears exhausts the attempt budget and fails" $?

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
