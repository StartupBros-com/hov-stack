#!/usr/bin/env bash
# ccflare launcher + key-install helper (acme-infra plan
# 2026-08-30-0030-feat-ccflare-tailnet-sharing-plan.md, U4; R8, R11, R12, R13).
#
# What this pins:
#   1. The claude() launcher's four probe outcomes (KTD4): 200 -> proxied with
#      env passed through and no log line; 401/403 -> key-invalid notice + log
#      + native fallback; 5xx -> proxy-error class; unreachable -> bypass.
#   2. The auth channel is env.ANTHROPIC_CUSTOM_HEADERS ("x-api-key: btr-…"),
#      NOT env.ANTHROPIC_AUTH_TOKEN: a token var is treated by Claude Code as
#      an auth source and disables claude.ai login/connectors, while x-api-key
#      is the header better-ccflare checks first. The probe feeds that header
#      line through a -K config — never argv (curl stub validates both).
#   3. Fallback is proxy-neutralized at BOTH layers for ALL THREE vars
#      (BASE_URL, legacy AUTH_TOKEN, CUSTOM_HEADERS): process env stripped
#      (even when exported ambient) AND a --settings overlay blanking the
#      settings-level values. The claude stub CONSUMES the --settings value it
#      receives — a wrong path or unblanked overlay fails the suite. A
#      claude-bccf-* model pin is overridden to sonnet in the overlay
#      (drill-caught 2026-08-30: route aliases break the native session with
#      unrecognized_model); any other model value passes through untouched.
#   4. Hermeticity: ambient proxy env is set BY THIS SUITE, not inherited.
#   5. ccflare-key-install (KTD3): install writes CUSTOM_HEADERS and MIGRATES
#      any legacy ANTHROPIC_AUTH_TOKEN away; rotation idempotence; unrelated
#      keys survive; non-btr rejection; valid JSON; verify-retry-once branch
#      (driven by a first-read-stale jq stub).
#   6. With a stored claude.ai login (.credentials.json claudeAiOauth), every
#      launch path (proxied, explicit idle, native fallback, no-url,
#      first-party, unverified route) drops an exported CLAUDE_CODE_OAUTH_TOKEN
#      from the child while the parent shell keeps it: the ~/.secrets
#      setup-token must not outrank the stored /login for Artifact calls.
#      Without a stored login (or with only mcpOAuth) the token is kept,
#      because it may be the host's only credential.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

REAL_JQ=$(command -v jq)

# ---- extract the launcher function from .bashrc ----------------------------
sed -n '/^# --- ccflare-launcher begin/,/^# --- ccflare-launcher end/p' \
  "$REPO/.bashrc" > "$TMP/launcher.sh"
# Redirect the fixed policy root in the scratch source only. No production env
# override exists, and no test reads/writes the host's enforced policy files.
[ "$(grep -c '^    local managed_settings_dir=/etc/claude-code$' "$TMP/launcher.sh")" = 1 ] \
  || { echo "FATAL: fixed policy-root fixture seam changed" >&2; exit 1; }
sed -i "s|^    local managed_settings_dir=/etc/claude-code$|    local managed_settings_dir=$TMP/managed-policy|" "$TMP/launcher.sh"
mkdir -p "$TMP/managed-policy/managed-settings.d"
grep -q '^claude()' "$TMP/launcher.sh" \
  || { echo "FATAL: could not extract claude() from .bashrc markers" >&2; exit 1; }

# ---- stubs ----------------------------------------------------------------
STUB_BIN=$TMP/bin
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<'SH'
#!/usr/bin/env bash
{
  printf 'argv:'; printf ' %q' "$@"; printf '\n'
  printf 'API_FORCE_IDLE_TIMEOUT=%s\n' "${API_FORCE_IDLE_TIMEOUT-__UNSET__}"
  printf 'ANTHROPIC_BASE_URL=%s\n' "${ANTHROPIC_BASE_URL-__UNSET__}"
  printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "${ANTHROPIC_AUTH_TOKEN-__UNSET__}"
  printf 'ANTHROPIC_CUSTOM_HEADERS=%s\n' "${ANTHROPIC_CUSTOM_HEADERS-__UNSET__}"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN-__UNSET__}"
} >> "$CLAUDE_STUB_RECORD"
# Consume the overlay the way the real CLI would have to: the value passed to
# --settings must exist, parse, and blank all three proxy vars.
prev=
for a in "$@"; do
  if [ "$prev" = "--settings" ]; then
    if [ -f "$a" ]; then overlay_json=$(cat -- "$a"); else overlay_json=$a; fi
    if jq -e '.env.ANTHROPIC_BASE_URL == "" and .env.ANTHROPIC_AUTH_TOKEN == "" and .env.ANTHROPIC_CUSTOM_HEADERS == ""' <<< "$overlay_json" >/dev/null 2>&1; then
      echo "overlay-ok:$a" >> "$CLAUDE_STUB_RECORD"
    else
      echo "overlay-bad:$a" >> "$CLAUDE_STUB_RECORD"
    fi
    if [ -f "$a" ]; then printf 'overlay-mode:%s\n' "$(stat -c %a "$a")" >> "$CLAUDE_STUB_RECORD"; fi
    echo "overlay-idle:$(jq -r '.env.API_FORCE_IDLE_TIMEOUT // "__ABSENT__"' <<< "$overlay_json" 2>/dev/null)" >> "$CLAUDE_STUB_RECORD"
    echo "overlay-other:$(jq -r '.env.KEEP_SETTING // "__ABSENT__"' <<< "$overlay_json" 2>/dev/null)" >> "$CLAUDE_STUB_RECORD"
    echo "overlay-model:$(jq -r '.model // "__ABSENT__"' <<< "$overlay_json" 2>/dev/null)" >> "$CLAUDE_STUB_RECORD"
  fi
  prev=$a
done
exit "${CLAUDE_STUB_EXIT:-0}"
SH
cat > "$STUB_BIN/curl" <<'SH'
#!/usr/bin/env bash
# Records its full invocation, then validates the production probe contract
# before answering: key-gated /api/api-keys target and auth supplied via a -K
# config file carrying an x-api-key header line. An argv-borne auth header
# (Authorization or x-api-key) is recorded as a leak. Wrong endpoint or
# missing auth answers 000 so a contract regression surfaces as failures.
{ printf 'curl-argv:'; printf ' %q' "$@"; printf '\n'; } >> "$CURL_STUB_RECORD"
if [ "${CCFLARE_TEST_CURL_EXIT:-0}" != 0 ]; then exit "$CCFLARE_TEST_CURL_EXIT"; fi
url_ok=0 auth_ok=0 prev=
for a in "$@"; do
  if [ "$prev" = "-K" ] && grep -q 'x-api-key' "$a" 2>/dev/null; then auth_ok=1; fi
  case "$a" in
    *"/api/api-keys") url_ok=1 ;;
    *Authorization*|*x-api-key*) echo "argv-auth-leak" >> "$CURL_STUB_RECORD" ;;
  esac
  prev=$a
done
if [ "$url_ok" = 1 ] && [ "$auth_ok" = 1 ]; then
  printf '%s' "${CCFLARE_TEST_HTTP_CODE:-200}"
else
  printf '000'
fi
SH
chmod +x "$STUB_BIN/claude" "$STUB_BIN/curl"
export PATH="$STUB_BIN:$PATH"
unset API_FORCE_IDLE_TIMEOUT CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_GATEWAY

# ---- fixture home ---------------------------------------------------------
export HOME=$TMP/home
export CLAUDE_HOME=$TMP/home/.claude
export CLAUDE_CONFIG_DIR=$CLAUDE_HOME
unset CLAUDE_CODE_PROJECT_DIR_NAME CLAUDE_CODE_HOST_GATEWAY_LINEAGE
export XDG_STATE_HOME=$TMP/home/.local/state
mkdir -p "$CLAUDE_HOME"
mkdir -p "$TMP/project"
cd "$TMP/project" || exit 1
SETTINGS=$CLAUDE_HOME/settings.json
LOG=$XDG_STATE_HOME/ccflare-launcher/fallback.log
RECORD=$TMP/claude-record
CURL_RECORD=$TMP/curl-record
export CLAUDE_STUB_RECORD=$RECORD
export CURL_STUB_RECORD=$CURL_RECORD

TESTKEY="btr-hermetic-test-key-000"
printf '{"env":{"ANTHROPIC_BASE_URL":"https://proxy.example.net","ANTHROPIC_CUSTOM_HEADERS":"x-api-key: %s","OTHER":"keep"},"model":"claude-bccf-route-test-pin[1m]"}\n' "$TESTKEY" > "$SETTINGS"

# shellcheck disable=SC1090
. "$TMP/launcher.sh"

# Ambient proxy env is OWNED BY THE SUITE: the 200 path must pass it through
# untouched, and every fallback must strip all three even though exported —
# including the legacy token var a not-yet-migrated host might still carry.
export ANTHROPIC_BASE_URL="https://proxy.example.net"
export ANTHROPIC_AUTH_TOKEN="$TESTKEY"
export ANTHROPIC_CUSTOM_HEADERS="x-api-key: $TESTKEY"
# The env login token is suite-owned too: every launch path must drop it.
FIXTURE_OAUTH="fixture-env-login-token-000"
export CLAUDE_CODE_OAUTH_TOKEN=$FIXTURE_OAUTH
CREDS=$CLAUDE_HOME/.credentials.json
printf '{"claudeAiOauth":{"accessToken":"fixture-stored-login"}}\n' > "$CREDS"
no_login_token() { grep -q '^CLAUDE_CODE_OAUTH_TOKEN=__UNSET__$' "$RECORD" && ok || bad "$1: env login token reached the child"; }

run_claude() { # <http-code> <curl-exit> [args...]
  local http=$1 cexit=$2; shift 2
  : > "$RECORD"
  : > "$CURL_RECORD"
  CCFLARE_TEST_HTTP_CODE=$http CCFLARE_TEST_CURL_EXIT=$cexit claude "$@" 2> "$TMP/stderr"
}

log_lines() { [ -f "$LOG" ] && wc -l < "$LOG" || echo 0; }

# ---- 1. probe 200: proxied, env passed through, no log ---------------------
run_claude 200 0 --continue
grep -q 'argv: --continue' "$RECORD" && ok || bad "200: args not passed through: $(cat "$RECORD")"
grep -q "ANTHROPIC_BASE_URL=https://proxy.example.net" "$RECORD" && ok \
  || bad "200: proxied invocation did not pass the exported env through"
grep -q "ANTHROPIC_CUSTOM_HEADERS=x-api-key: " "$RECORD" && ok \
  || bad "200: proxied invocation did not pass the custom-headers env through"
[ "$(log_lines)" = 0 ] && ok || bad "200: fallback log written on the proxied path"
[ "${API_FORCE_IDLE_TIMEOUT-__UNSET__}" = __UNSET__ ] && ok || bad "200: timeout default leaked to parent shell"
grep -q '^API_FORCE_IDLE_TIMEOUT=false$' "$RECORD" && ok || bad "200: missing gateway child timeout default"
no_login_token "200"
[ "${CLAUDE_CODE_OAUTH_TOKEN-}" = "$FIXTURE_OAUTH" ] && ok || bad "200: env login token removed from the parent shell"
grep -q 'settings' "$RECORD" && bad "200: proxied path passed a settings overlay" || ok
grep -q '/api/api-keys' "$CURL_RECORD" && ok \
  || bad "200: probe did not target the key-gated endpoint: $(cat "$CURL_RECORD")"

# ---- 2. probe 401: key-invalid fallback, neutralized both layers -----------
run_claude 401 0
grep -q 'key-invalid' "$TMP/stderr" && ok || bad "401: no key-invalid notice: $(cat "$TMP/stderr")"
grep -q ' key-invalid http=401' "$LOG" && ok || bad "401: no key-invalid log line: $(cat "$LOG" 2>/dev/null)"
grep -q 'ANTHROPIC_BASE_URL=__UNSET__' "$RECORD" && ok || bad "401: fallback env still carries ANTHROPIC_BASE_URL"
grep -q 'ANTHROPIC_AUTH_TOKEN=__UNSET__' "$RECORD" && ok || bad "401: fallback env still carries the legacy token"
grep -q 'ANTHROPIC_CUSTOM_HEADERS=__UNSET__' "$RECORD" && ok || bad "401: fallback env still carries custom headers"
no_login_token "401 fallback"
grep -q 'overlay-ok:' "$RECORD" && ok || bad "401: claude stub did not receive a valid blanked overlay: $(grep overlay "$RECORD")"
grep -q 'overlay-bad:' "$RECORD" && bad "401: overlay handed to claude was not blanked/readable" || ok
grep -q 'overlay-model:sonnet' "$RECORD" && ok || bad "401: bccf model pin not overridden to sonnet in overlay: $(grep overlay-model "$RECORD")"
grep -q 'overridden to sonnet' "$TMP/stderr" && ok || bad "401: no model-override notice on stderr"

# ---- 3. probe 403: same key-invalid arm ------------------------------------
run_claude 403 0
grep -q ' key-invalid http=403' "$LOG" && ok || bad "403: no key-invalid log line"

# ---- 4. probe 500: proxy-error class ---------------------------------------
run_claude 500 0
grep -q ' proxy-error http=500' "$LOG" && ok || bad "500: no proxy-error log line"
grep -q 'proxy-error' "$TMP/stderr" && ok || bad "500: notice does not name proxy-error"

# ---- 5. transport failure: bypass class ------------------------------------
run_claude 000 7
grep -q ' bypass http=000' "$LOG" && ok || bad "unreachable: no bypass log line"
grep -q 'NATIVE' "$TMP/stderr" && ok || bad "unreachable: no visible native-session notice"

# ---- 5b. a non-proxy model pin passes through untouched --------------------
printf '{"env":{"ANTHROPIC_BASE_URL":"https://proxy.example.net","ANTHROPIC_CUSTOM_HEADERS":"x-api-key: %s"},"model":"opusplan"}\n' "$TESTKEY" > "$SETTINGS"
run_claude 401 0
grep -q 'overlay-model:__ABSENT__' "$RECORD" && ok \
  || bad "non-bccf model was overridden in the overlay: $(grep overlay-model "$RECORD")"
grep -q 'overlay-ok:' "$RECORD" && ok || bad "non-bccf fallback overlay invalid"

# ---- 6. hygiene: key absent from logs and BOTH stubs' argv -----------------
grep -q "$TESTKEY" "$LOG" && bad "API key leaked into the fallback log" || ok
grep -q "$TESTKEY" "$RECORD" && bad "API key leaked into claude argv/env on a fallback run" || ok
grep -q "$TESTKEY" "$CURL_RECORD" && bad "API key leaked into curl argv (must ride the -K config)" || ok
grep -q 'argv-auth-leak' "$CURL_RECORD" && bad "auth header passed via curl argv" || ok
grep -q "$FIXTURE_OAUTH" "$RECORD" && bad "env login token leaked into claude env on a fallback run" || ok

# ---- 6b. no stored login: the env token may be the only credential ---------
mv "$CREDS" "$CREDS.saved"
# 200 only: a fallback here would add a fallback.log line that case 7 counts.
run_claude 200 0 --continue
grep -q "^CLAUDE_CODE_OAUTH_TOKEN=$FIXTURE_OAUTH\$" "$RECORD" && ok || bad "200 without stored login: env token dropped"
printf '{"mcpOAuth":{}}\n' > "$CREDS"
run_claude 200 0
grep -q "^CLAUDE_CODE_OAUTH_TOKEN=$FIXTURE_OAUTH\$" "$RECORD" && ok || bad "mcpOAuth-only credentials: env token dropped"
mv "$CREDS.saved" "$CREDS"
run_claude 200 0
no_login_token "stored login restored"

# ---- 7. no base URL configured: transparent passthrough --------------------
printf '{"env":{"OTHER":"keep"}}\n' > "$SETTINGS"
run_claude 200 0 --resume
grep -q 'argv: --resume' "$RECORD" && ok || bad "no-url: args not passed through"
no_login_token "no-url"
[ "$(log_lines)" = 5 ] && ok || bad "no-url: unexpected log write ($(log_lines) lines, want 5 from earlier)"

# ---- 7b. scoped timeout default and fallback settings precedence -----------
grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "no-url: idle override was added"
[ ! -s "$CURL_RECORD" ] && ok || bad "no-url: unexpected probe"

printf '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","ANTHROPIC_CUSTOM_HEADERS":"x-api-key: fixture-native"}}\n' > "$SETTINGS"
run_claude 200 0 --resume
grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "first-party: idle override was added"
no_login_token "first-party"
[ ! -s "$CURL_RECORD" ] && ok || bad "first-party: unexpected gateway probe"

printf '{"env":{"ANTHROPIC_BASE_URL":"https://proxy.example.net","ANTHROPIC_CUSTOM_HEADERS":"x-api-key: %s"}}\n' "$TESTKEY" > "$SETTINGS"
API_FORCE_IDLE_TIMEOUT=true run_claude 200 0
grep -q '^API_FORCE_IDLE_TIMEOUT=true$' "$RECORD" && ok || bad "explicit true: operator value replaced"
no_login_token "explicit idle"
API_FORCE_IDLE_TIMEOUT=false run_claude 200 0
grep -q '^API_FORCE_IDLE_TIMEOUT=false$' "$RECORD" && ok || bad "explicit false: operator value replaced"

for http in 401 403 000; do
  API_FORCE_IDLE_TIMEOUT=false run_claude "$http" 0 --continue
  grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "$http: native child inherited idle override"
  grep -q '^overlay-idle:true$' "$RECORD" && ok || bad "$http: settings can re-arm idle override on native fallback"
done
# Native fallback with no stored login keeps the env token (the only credential).
mv "$CREDS" "$CREDS.saved"
run_claude 401 0 --continue
grep -q "^CLAUDE_CODE_OAUTH_TOKEN=$FIXTURE_OAUTH\$" "$RECORD" && ok || bad "401 without stored login: env token dropped"
grep -q 'ANTHROPIC_BASE_URL=__UNSET__' "$RECORD" && ok || bad "401 without stored login: proxy env not stripped"
mv "$CREDS.saved" "$CREDS"

CALLER_SETTINGS=$TMP/caller-settings.json
printf '{"env":{"API_FORCE_IDLE_TIMEOUT":"false","KEEP_SETTING":"caller-value"},"model":"opusplan"}\n' > "$CALLER_SETTINGS"
run_claude 401 0 --settings "$CALLER_SETTINGS" --continue --effort high
[ "$(grep -c '^overlay-idle:true$' "$RECORD")" = 1 ] && ok || bad "caller settings: fallback idle override not authoritative"
grep -q '^overlay-other:caller-value$' "$RECORD" && ok || bad "caller settings: unrelated value lost"
grep -q '^overlay-model:opusplan$' "$RECORD" && ok || bad "caller settings: native model lost"
grep -q -- '--continue --effort high' "$RECORD" && ok || bad "caller settings: other arguments lost"
run_claude 403 0 --settings='{"env":{"API_FORCE_IDLE_TIMEOUT":"false","KEEP_SETTING":"inline"}}' --resume
grep -q '^overlay-idle:true$' "$RECORD" && ok || bad "inline settings: fallback idle override not authoritative"
grep -q '^overlay-other:inline$' "$RECORD" && ok || bad "inline settings: unrelated value lost"

# Explicit caller destination selection is passed through, never reinterpreted
# as proof that the default user-settings gateway handles this launch.
run_claude 200 0 --settings '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}'
grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "caller native destination: gateway default applied"

ANTHROPIC_BASE_URL=https://api.anthropic.com run_claude 200 0
grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "ambient native destination: gateway default applied"

# Higher-scope destination and explicit timeout choices are never guessed.
mkdir -p .claude
printf '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}\n' > .claude/settings.local.json
run_claude 200 0
grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "project native route: gateway default applied"
printf '{"env":{"API_FORCE_IDLE_TIMEOUT":"true"}}\n' > .claude/settings.local.json
run_claude 200 0
grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "project explicit timeout: default injected"
printf 'not-json\n' > .claude/settings.local.json
run_claude 200 0
grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "malformed project: destination assumed"
rm .claude/settings.local.json
run_claude 200 0 --setting-sources project,local
grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "custom sources: destination assumed"
no_login_token "custom sources (unverified route)"
printf '{}\n' > "$CLAUDE_CONFIG_DIR/remote-settings.json"
run_claude 200 0
grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "remote managed settings: destination assumed"
rm "$CLAUDE_CONFIG_DIR/remote-settings.json"
run_claude 200 0 --settings '{"env":{"API_FORCE_IDLE_TIMEOUT":"false"}}'
grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "CLI explicit timeout: default injected"
grep -q 'API_FORCE_IDLE_TIMEOUT' "$RECORD" && ok || bad "CLI explicit timeout: settings removed"
# Native overrides are per-child, private, and removed after normal child exit.
run_claude 401 0 --settings "$CALLER_SETTINGS"
[ -z "$(find "$XDG_STATE_HOME/ccflare-launcher" -name 'native-overlay.*.json' -print)" ] && ok || bad "fallback settings file retained after child exit"

grep -q '^overlay-mode:600$' "$RECORD" && ok || bad "fallback overlay is not private"
CLAUDE_STUB_EXIT=17 run_claude 401 0
[ "$?" = 17 ] && ok || bad "fallback child exit status lost"
run_claude 401 0 --settings not-valid-json
[ "$?" = 2 ] && [ ! -s "$RECORD" ] && ok || bad "invalid caller settings silently discarded"
run_claude 401 0 --settings not-valid-json --settings '{"env":{"KEEP_SETTING":"last-value"}}'
grep -q '^overlay-other:last-value$' "$RECORD" && ok || bad "last --settings occurrence did not win"

# Linked worktrees also inherit canonical-root local settings. A worktree-only
# scan would wrongly apply the default when canonical settings choose native.
CANONICAL=$TMP/canonical
WORKTREE=$TMP/linked
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git init -q -b main "$CANONICAL"
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$CANONICAL" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m fixture
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$CANONICAL" -c core.hooksPath=/dev/null worktree add -q -b fixture "$WORKTREE"
mkdir -p "$CANONICAL/.claude"
printf '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}\n' > "$CANONICAL/.claude/settings.local.json"
cd "$WORKTREE" || exit 1
run_claude 200 0
grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "canonical local native route: gateway default applied"
printf '{"env":{"API_FORCE_IDLE_TIMEOUT":"false"}}\n' > "$CANONICAL/.claude/settings.local.json"
run_claude 200 0
grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "canonical explicit timeout: launcher replaced it"
cd "$TMP/project" || exit 1

# Provider selectors and alternate routes bypass the whole launcher. A failed
# unrelated gateway must never rewrite these launches into "native" fallback.
cp "$SETTINGS" "$TMP/gateway-settings.json"
for selector in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_GATEWAY; do
  export "$selector=1"
  run_claude 200 0 --continue
  [ ! -s "$CURL_RECORD" ] && ok || bad "$selector healthy shell: unrelated gateway probed"
  grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "$selector healthy shell: idle override injected"
  no_login_token "$selector healthy shell"
  run_claude 401 0 --continue
  [ ! -s "$CURL_RECORD" ] && ok || bad "$selector shell: unrelated gateway probed"
  grep -q '^argv: --continue$' "$RECORD" && ok || bad "$selector shell: launch rewritten"
  grep -q '^API_FORCE_IDLE_TIMEOUT=__UNSET__$' "$RECORD" && ok || bad "$selector shell: idle override injected"
  unset "$selector"
  "$REAL_JQ" --arg selector "$selector" '.env[$selector] = "1"' "$TMP/gateway-settings.json" > "$SETTINGS"
  run_claude 401 0 --continue
  [ ! -s "$CURL_RECORD" ] && ok || bad "$selector user settings: unrelated gateway probed"
  grep -q '^argv: --continue$' "$RECORD" && ok || bad "$selector user settings: launch rewritten"
  cp "$TMP/gateway-settings.json" "$SETTINGS"
  printf '{"env":{"%s":"yes"}}\n' "$selector" > .claude/settings.local.json
  run_claude 000 0 --continue
  [ ! -s "$CURL_RECORD" ] && ok || bad "$selector project: unrelated gateway probed"
  grep -q '^argv: --continue$' "$RECORD" && ok || bad "$selector project: launch rewritten"
  rm .claude/settings.local.json
  run_claude 403 0 --settings "{\"env\":{\"$selector\":\"true\"}}" --continue
  [ ! -s "$CURL_RECORD" ] && ok || bad "$selector CLI: unrelated gateway probed"
  grep -q 'native-overlay' "$RECORD" && bad "$selector CLI: settings rewritten" || ok
  export "$selector=false"
  run_claude 200 0
  grep -q '^API_FORCE_IDLE_TIMEOUT=false$' "$RECORD" && ok || bad "$selector disabled shell: managed default lost"
  unset "$selector"
done
for destination in https://api.anthropic.com https://other.example; do
  ANTHROPIC_BASE_URL=$destination run_claude 401 0 --continue
  [ ! -s "$CURL_RECORD" ] && ok || bad "$destination env: unrelated gateway probed"
  grep -q '^argv: --continue$' "$RECORD" && ok || bad "$destination env: launch rewritten"
  printf '{"env":{"ANTHROPIC_BASE_URL":"%s"}}\n' "$destination" > .claude/settings.local.json
  run_claude 000 0 --continue
  [ ! -s "$CURL_RECORD" ] && ok || bad "$destination project: unrelated gateway probed"
  grep -q '^argv: --continue$' "$RECORD" && ok || bad "$destination project: launch rewritten"
  rm .claude/settings.local.json
  run_claude 401 0 --settings "{\"env\":{\"ANTHROPIC_BASE_URL\":\"$destination\"}}" --continue
  [ ! -s "$CURL_RECORD" ] && ok || bad "$destination CLI: unrelated gateway probed"
  grep -q 'native-overlay' "$RECORD" && bad "$destination CLI: settings rewritten" || ok
done
run_claude 401 0 --settings '{} {}' --settings '{"env":{"KEEP_SETTING":"last-single-object"}}'
grep -q '^overlay-other:last-single-object$' "$RECORD" && ok || bad "last valid --settings did not supersede multiple documents"
for invalid in '{} {}' '[]' 'null' ''; do
  run_claude 401 0 --settings "$invalid"
  [ "$?" = 2 ] && [ ! -s "$RECORD" ] && ok || bad "invalid inline settings launched: $invalid"
  printf '%s\n' "$invalid" > "$CALLER_SETTINGS"
  run_claude 401 0 --settings "$CALLER_SETTINGS"
  [ "$?" = 2 ] && [ ! -s "$RECORD" ] && ok || bad "invalid file settings launched: $invalid"
done

# Enforced policy applies after CLI flags. Owning even the SAME destination
# means a native fallback overlay cannot win, so no probe/fallback is allowed.
MANAGED=$TMP/managed-policy/managed-settings.json
for policy in '{"env":{"ANTHROPIC_BASE_URL":"https://proxy.example.net"}}' '{"env":{"API_FORCE_IDLE_TIMEOUT":"false"}}' '{"env":{"CLAUDE_CODE_USE_BEDROCK":"false"}}' '{"env":{"ANTHROPIC_CUSTOM_HEADERS":"x-api-key: fixture-policy"}}' '{"model":"claude-bccf-route-policy"}' '{} {}' 'not-json'; do
  printf '%s\n' "$policy" > "$MANAGED"
  run_claude 401 0 --continue
  [ ! -s "$CURL_RECORD" ] && ok || bad "managed-owned transport: unrelated gateway probed"
  grep -q '^argv: --continue$' "$RECORD" && ok || bad "managed-owned transport: native overlay attempted"
  grep -q 'NATIVE' "$TMP/stderr" && bad "managed-owned transport: incorrectly labeled native" || ok
done
printf '{"permissions":{"deny":["Read(dummy)"]}}\n' > "$MANAGED"
run_claude 200 0 --continue
grep -q '^API_FORCE_IDLE_TIMEOUT=false$' "$RECORD" && ok || bad "harmless managed policy prevented verified gateway default"
run_claude 401 0 --continue
grep -q '^overlay-idle:true$' "$RECORD" && ok || bad "harmless managed policy prevented neutral native fallback"
FRAGMENT=$TMP/managed-policy/managed-settings.d/transport.json
printf '{"env":{"ANTHROPIC_BASE_URL":"https://proxy.example.net"}}\n' > "$FRAGMENT"
run_claude 000 0 --continue
[ ! -s "$CURL_RECORD" ] && ok || bad "managed fragment same route: gateway probed"
grep -q '^argv: --continue$' "$RECORD" && ok || bad "managed fragment same route: native overlay attempted"
printf 'not-json\n' > "$FRAGMENT"
run_claude 401 0 --continue
[ ! -s "$CURL_RECORD" ] && ok || bad "ambiguous managed fragment: gateway probed"
grep -q '^argv: --continue$' "$RECORD" && ok || bad "ambiguous managed fragment: native overlay attempted"
rm "$MANAGED" "$FRAGMENT"

# ---- 8. ccflare-key-install: install, MIGRATE legacy, rotate, validate -----
printf '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:8788","ANTHROPIC_AUTH_TOKEN":"btr-legacy-old","OTHER":"keep"}}\n' > "$SETTINGS"
KI=$REPO/bin/ccflare-key-install
printf 'btr-first-key\n' | bash "$KI" >/dev/null 2>&1
[ "$("$REAL_JQ" -r '.env.ANTHROPIC_CUSTOM_HEADERS' "$SETTINGS")" = "x-api-key: btr-first-key" ] && ok \
  || bad "key-install: first key not installed as custom header"
"$REAL_JQ" -e '.env | has("ANTHROPIC_AUTH_TOKEN")' "$SETTINGS" >/dev/null 2>&1 \
  && bad "key-install: legacy ANTHROPIC_AUTH_TOKEN survived (it disables claude.ai connectors)" || ok
printf 'btr-second-key\n' | bash "$KI" >/dev/null 2>&1
[ "$("$REAL_JQ" -r '.env.ANTHROPIC_CUSTOM_HEADERS' "$SETTINGS")" = "x-api-key: btr-second-key" ] && ok \
  || bad "key-install: rotation did not replace the first key"
[ "$("$REAL_JQ" -r '.env.OTHER' "$SETTINGS")" = "keep" ] && ok \
  || bad "key-install: unrelated env key did not survive"
[ "$("$REAL_JQ" -r '.env.ANTHROPIC_BASE_URL' "$SETTINGS")" = "http://127.0.0.1:8788" ] && ok \
  || bad "key-install: base URL did not survive"
"$REAL_JQ" -e . "$SETTINGS" >/dev/null 2>&1 && ok || bad "key-install: settings no longer valid JSON"
printf 'not-a-key\n' | bash "$KI" >/dev/null 2>&1 \
  && bad "key-install accepted a non-btr key" || ok
[ "$("$REAL_JQ" -r '.env.ANTHROPIC_CUSTOM_HEADERS' "$SETTINGS")" = "x-api-key: btr-second-key" ] && ok \
  || bad "key-install: rejected input still mutated the header"

# ---- 9. key-install verify-retry branch (first verify reads stale) ---------
# A jq stub returns a stale header on the FIRST custom-headers read
# (simulating a racing live-session rewrite between write and verify), then
# delegates to real jq.
rm -f "$TMP/jq-once"
cat > "$STUB_BIN/jq" <<SH
#!/usr/bin/env bash
case "\$*" in
  *ANTHROPIC_CUSTOM_HEADERS*)
    if [ ! -f "$TMP/jq-once" ]; then touch "$TMP/jq-once"; echo "x-api-key: btr-stale-race"; exit 0; fi ;;
esac
exec "$REAL_JQ" "\$@"
SH
chmod +x "$STUB_BIN/jq"
printf 'btr-retry-key\n' | bash "$KI" >/dev/null 2>&1
retry_rc=$?
rm -f "$STUB_BIN/jq"
[ "$retry_rc" -eq 0 ] && ok || bad "retry: key-install exited $retry_rc under a stale first verify"
[ -f "$TMP/jq-once" ] && ok || bad "retry: the stale-verify branch was never exercised"
[ "$("$REAL_JQ" -r '.env.ANTHROPIC_CUSTOM_HEADERS' "$SETTINGS")" = "x-api-key: btr-retry-key" ] && ok \
  || bad "retry: key not installed after retry (got '$("$REAL_JQ" -r '.env.ANTHROPIC_CUSTOM_HEADERS' "$SETTINGS")')"

echo "ccflare-launcher: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
