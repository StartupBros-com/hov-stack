#!/usr/bin/env bash
# U1/U2/U3/U4/U5 contract tests. Private PATH contains only the fake vendor and shim tools.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$REPO/bin/firecrawl-cli"
MODULE="$REPO/bin/firecrawl_cli.py"
FIXTURES="$REPO/tests/fixtures/firecrawl-cli"
TMP=$(mktemp -d /tmp/firecrawl-cli-test.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/no-vendor" "$TMP/work" "$TMP/fixtures"
for tool in python3 bash dirname readlink; do
  ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
  ln -s "$(command -v "$tool")" "$TMP/no-vendor/$tool"
done
cp "$FIXTURES/fake-firecrawl.py" "$TMP/bin/firecrawl"
cp "$FIXTURES/fake-exa.py" "$TMP/bin/exa-cli"
chmod +x "$TMP/bin/firecrawl" "$TMP/bin/exa-cli"
unset EXA_TEST_SOURCE EXA_TEST_EXIT EXA_TEST_SLEEP FIRECRAWL_API_KEY
export FIRECRAWL_TEST_CONTROL="$TMP/control.json"
export FIRECRAWL_TEST_LOG="$TMP/calls.jsonl"
export FIRECRAWL_TEST_FIXTURES="$TMP/fixtures"
unset CLAUDE_CODE_SESSION_ID
# Do not inherit an operator's budget overrides into this hermetic suite.
for name in ${!FIRECRAWL_CLI_@}; do unset "$name"; done
# Free-first keyless routing (#2118) is off for the legacy blocks, which pin keyed
# behavior; the keyless block turns it back on per call.
export FIRECRAWL_CLI_KEYLESS=0
export PYTHONDONTWRITEBYTECODE=1
python3 - "$FIXTURES/responses.json" "$TMP/fixtures" <<'PY'
import json, pathlib, sys
for name, data in json.loads(pathlib.Path(sys.argv[1]).read_text()).items():
    pathlib.Path(sys.argv[2], name + '.json').write_text(json.dumps(data))
PY
cp "$FIXTURES/usage.txt" "$TMP/fixtures/usage.txt"
cp "$FIXTURES/login-menu.txt" "$TMP/fixtures/login-menu.txt"

pass=0 fail=0
RESET_LEDGER=1
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
contains() { case "$1" in *"$2"*) ok ;; *) bad "$3: missing '$2'" ;; esac; }
omits() { case "$1" in *"$2"*) bad "$3: contained '$2'" ;; *) ok ;; esac; }
status_is() { [[ "$ST" -eq "$1" ]] && ok || bad "$2: expected exit $1, got $ST"; }
jcheck() {
  local result
  result=$(printf '%s' "$2" | python3 -c "import json,sys; d=json.load(sys.stdin); $3; print('OK')" 2>&1)
  [[ "$result" == OK ]] && ok || bad "$1: $result"
}
configure() {
  printf '%s\n' "$1" >"$FIRECRAWL_TEST_CONTROL"
  : >"$FIRECRAWL_TEST_LOG"
  if [[ "$RESET_LEDGER" == 1 ]]; then
    rm -rf "$TMP/home/.claude/state/firecrawl-cli"
  fi
}
fixture() { configure "{\"default\":{\"fixture\":\"$1.json\"}}"; }
run_cli() {
  ST=0
  (cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" "$CLI" "$@") >"$TMP/out" 2>"$TMP/err" || ST=$?
  OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
}
argv_is() {
  jcheck "$1" "$(python3 -c 'import json,os; print(next(line for line in open(os.environ["FIRECRAWL_TEST_LOG"]) if json.loads(line)[0]!="credit-usage"))')" "$2"
}
all_argv_is() {
  jcheck "$1" "$(python3 -c 'import json,os; print(json.dumps([json.loads(line) for line in open(os.environ["FIRECRAWL_TEST_LOG"])]))')" "$2"
}
no_calls() { [[ ! -s "$FIRECRAWL_TEST_LOG" ]] && ok || bad "$1: vendor invoked"; }

# Vendor 1.26.25 category, discovery and Alexandria accounting contracts.
fixture search-id
run_cli search query --categories github --json
status_is 4 'removed github category rejected'
contains "$ERR" 'valid categories: research, pdf, developer, gov' 'removed category names valid list'
no_calls 'removed category rejected before vendor contact'
run_cli search query --categories gov,pdf --json
status_is 4 'gov cannot combine with pdf'
contains "$ERR" 'gov cannot be combined' 'gov combination explanation'
no_calls 'gov combination rejected before vendor contact'
run_cli search query --sources alexandria --json
status_is 4 'alexandria without key or login refused'
contains "$OUT$ERR" 'FIRECRAWL_API_KEY' 'alexandria remedy names key'
no_calls 'alexandria refused before credit read or reservation'

export CLAUDE_CODE_SESSION_ID='vendor-126-accounting'
configure '{"default":{"text":"{\"data\":{\"tools\":[]}}"}}'
run_cli raw --json -- find-tools query
status_is 0 'discovery succeeds without reported cost'
jcheck 'discovery envelope is free' "$OUT" "assert d['credits_spent']==0 and d['budget_remaining']==300"
run_cli budget --json
jcheck 'discovery ledger reserves and charges zero' "$OUT" "assert not d['data']['reservations'] and d['data']['session']['spent']==0 and d['data']['day_state']['spent']==0"

for charge in 0 7; do
  configure "{\"default\":{\"text\":\"{\\\"data\\\":{\\\"creditsCost\\\":$charge}}\"}}"
  run_cli raw --json -- scrape --alexandria provider/cap --options '{}'
  status_is 0 'alexandria execution succeeds'
  jcheck 'alexandria execution uses exact creditsCost' "$OUT" "assert d['credits_spent']==$charge and d['budget_remaining']==300-$charge"
  run_cli budget --json
  jcheck 'alexandria execution holds only final charge' "$OUT" "r=list(d['data']['reservations'].values()); assert len(r)==1 and r[0]['amount']==$charge and r[0]['state']=='held'"
done
configure '{"default":{"text":"{\"data\":{}}"}}'
run_cli raw --json -- unknown-vendor-command
status_is 0 'unknown raw remains bounded'
run_cli budget --json
jcheck 'unknown raw retains 100-credit hold' "$OUT" "r=list(d['data']['reservations'].values()); assert len(r)==1 and r[0]['amount']==100 and r[0]['state']=='held'"
run_cli raw --json -- alexandria feedback
status_is 0 'alexandria feedback remains bounded'
run_cli budget --json
jcheck 'alexandria feedback adds its own bounded hold' "$OUT" "r=list(d['data']['reservations'].values()); assert len(r)==2 and all(x['amount']==100 and x['state']=='held' for x in r)"
unset CLAUDE_CODE_SESSION_ID

# U5/KTD9: status first, substring second; stdout is one JSON envelope.
for scenario in quota injected rate-limit concurrency-limit unauthorized provider-failure; do
  case "$scenario" in
    quota) http=402; exit_code=1; tag=quota_exhausted; retryable=False ;;
    injected) http=403; exit_code=1; tag=injection_blocked; retryable=False ;;
    rate-limit) http=429; exit_code=2; tag=rate_limited; retryable=True ;;
    concurrency-limit) http=429; exit_code=2; tag=concurrency_limited; retryable=True ;;
    unauthorized) http=401; exit_code=2; tag=auth_failure; retryable=True ;;
    provider-failure) http=503; exit_code=2; tag=provider_failure; retryable=True ;;
  esac
  configure "{\"default\":{\"fixture\":\"$scenario.json\",\"stderr_text\":\"HTTP $http\",\"exit\":1}}"
  run_cli extract https://x -Q 'title' --json
  status_is "$exit_code" "$scenario HTTP mapping"
  jcheck "$scenario JSON contract" "$OUT" "e=d['error']; assert not d['ok']; assert e['code']=='$tag'; assert e['retryable'] is $retryable; assert e['message'].startswith('error: ') and '\nwhy: ' in e['message']; assert e['next_action']; assert e['http_status']==$http"
  contains "$ERR" 'next: ' "$scenario next command"
  case "$scenario" in
    quota)
      contains "$ERR" 'Insufficient credits' 'AE6 quota reason'
      contains "$ERR" 'operator action: top up' 'AE6 operator action'
      contains "$ERR" 'Exa: credential present (source: env), live status unknown' 'AE15 credential state'
      contains "$ERR" 'exa-cli search "https://x" --limit 3 --json' 'AE6 exact live fallback'
      ;;
    injected)
      contains "$ERR" 'not retryable as-is' 'AE17 injection refusal'
      contains "$ERR" 'narrow the schema or prompt' 'AE17 narrow extraction'
      contains "$ERR" 'firecrawl-cli fetch https://x --full --json' 'AE17 plain text command'
      contains "$ERR" 'read it as data' 'AE17 treat page as data'
      ;;
    rate-limit) contains "$ERR" 'retry after 12s' 'Retry-After honored' ;;
    concurrency-limit) contains "$ERR" 'concurrency' 'concurrency reason' ;;
    unauthorized)
      contains "$ERR" 'credential source: vendor-managed configuration' '401 vendor source'
      contains "$ERR" 'firecrawl --status' '401 check command'
      ;;
  esac
  if [[ "$retryable" == True ]]; then
    contains "$ERR" 'doubling to' 'transient backoff'
  fi
  # Substring-only stderr from the vendor CLI follows the same mapping.
  message=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["error"])' "$TMP/fixtures/$scenario.json")
  configure "{\"default\":{\"stderr_text\":\"$message\",\"exit\":1}}"
  run_cli fetch https://x --json
  status_is "$exit_code" "$scenario substring mapping"
  jcheck "$scenario substring envelope" "$OUT" "assert d['error']['code']=='$tag' and d['error']['retryable'] is $retryable"
done
for scenario in unsupported hosted timeout malformed; do
  case "$scenario" in
    unsupported) rule='"stderr_text":"we do not support this site","exit":1'; tag=unsupported_site; exit_code=1 ;;
    hosted) rule='"stderr_text":"credential validation unavailable","exit":1'; tag=auth_failure; exit_code=2 ;;
    timeout) rule='"stderr_text":"HTTP 408 Request Timeout","exit":1'; tag=request_timeout; exit_code=2 ;;
    malformed) rule='"text":"{not JSON"'; tag=vendor_output_changed; exit_code=2 ;;
  esac
  configure "{\"default\":{$rule}}"
  run_cli fetch https://x --json
  status_is "$exit_code" "$scenario mapping"
  jcheck "$scenario error contract" "$OUT" "e=d['error']; assert e['code']=='$tag' and e['message'] and e['next_action']; assert e['retryable'] is ($exit_code==2)"
  case "$scenario" in
    unsupported) contains "$ERR" 'exa-cli contents https://x --json' 'unsupported site alternative' ;;
    malformed) contains "$ERR" 'vendor output changed; run the drift check (harness-doctor check 32)' 'drift check hint' ;;
    *) contains "$ERR" 'retry after 5s, doubling to 60s' 'default transient backoff' ;;
  esac
done
for http in 500 502 503 504 599; do
  configure "{\"default\":{\"stderr_text\":\"Request failed with status code $http\",\"exit\":1}}"
  run_cli search 'example query' --json
  status_is 2 "HTTP $http provider mapping"
  jcheck "HTTP $http JSON" "$OUT" "assert d['error']['code']=='provider_failure' and d['error']['retryable']"
done

# KTD10 probes only the fake --where; absence never falls through to real PATH.
for state in env empty absent failed timeout; do
  export EXA_TEST_SOURCE=env EXA_TEST_EXIT=0 EXA_TEST_SLEEP=0
  case "$state" in
    empty) export EXA_TEST_SOURCE='' ;;
    absent) mv "$TMP/bin/exa-cli" "$TMP/fake-exa" ;;
    failed) export EXA_TEST_EXIT=1 ;;
    timeout) export EXA_TEST_SLEEP=6 ;;
  esac
  fixture quota
  run_cli search 'example query' --json
  status_is 1 "Exa $state quota mapping"
  jcheck "Exa $state envelope" "$OUT" "assert d['error']['code']=='quota_exhausted'"
  if [[ "$state" == env ]]; then
    contains "$ERR" 'Exa: credential present (source: env), live status unknown' 'AE15 present state'
    contains "$ERR" 'exa-cli search "example query" --limit 3 --json' 'AE15 exact search command'
  else
    contains "$ERR" 'Exa: no credential resolved — operator action: add EXA_API_KEY to bws' "Exa $state operator action"
  fi
  for word in down unavailable broken; do
    omits "$ERR" "$word" "Exa never asserts $word"
  done
  if [[ "$state" == absent ]]; then mv "$TMP/fake-exa" "$TMP/bin/exa-cli"; fi
done
unset EXA_TEST_SOURCE EXA_TEST_EXIT EXA_TEST_SLEEP

# HTTP status wins conflicting substrings; generic 403 is not injection.
configure '{"default":{"text":"{\"success\":false,\"statusCode\":402,\"error\":\"Rate limit exceeded\"}"}}'
run_cli fetch https://x --json
status_is 1 'HTTP priority over substring'
jcheck 'HTTP priority tag' "$OUT" "assert d['error']['code']=='quota_exhausted'"
configure '{"default":{"stderr_text":"HTTP 403 Forbidden","exit":1}}'
run_cli fetch https://x --json
status_is 1 'generic forbidden'
jcheck 'generic forbidden not injected' "$OUT" "assert d['error']['code']==1 and not d['error']['retryable']"
configure '{"default":{"stderr_text":"HTTP 429 Rate limit exceeded\nRetry-After: 90","exit":1}}'
run_cli fetch https://x --json
contains "$ERR" 'retry after 90s' 'long Retry-After not capped'
export FIRECRAWL_API_KEY=synthetic-env-key
fixture unauthorized
run_cli fetch https://x --json
contains "$ERR" 'credential source: env (FIRECRAWL_API_KEY)' '401 env source'
omits "$OUT$ERR" 'synthetic-env-key' '401 never prints key'
unset FIRECRAWL_API_KEY
configure '{"default":{"stderr_text":"HTTP 402 Bearer secretTOKEN --token tokenSECRET fc-abcdefgh12345678","exit":1}}'
run_cli fetch https://x --json
for secret in secretTOKEN tokenSECRET fc-abcdefgh12345678; do
  omits "$OUT$ERR" "$secret" 'mapped error redaction'
done
fixture quota
run_cli fetch https://x
status_is 1 'human error mode'
[[ -z "$OUT" ]] && ok || bad 'human error wrote stdout'
contains "$ERR" 'error: ' 'human what line'
contains "$ERR" 'why: ' 'human why line'
contains "$ERR" 'next: ' 'human next line'

# Keep mapped failures intact across raw, fan-out, native batches and preflight.
fixture injected
run_cli raw --json -- scrape https://x --format json --json
status_is 1 'raw injection mapping'
jcheck 'raw injection contract' "$OUT" "assert d['error']['code']=='injection_blocked' and not d['error']['retryable']"
configure '{"default":{"fixture":"scrape.json"},"targets":{"https://y":{"fixture":"injected.json","exit":1}}}'
run_cli fetch https://x https://y --json
status_is 6 'fan-out injection partial success'
jcheck 'fan-out injection action' "$OUT" "e=d['data']['items'][1]['error']; assert e['code']=='injection_blocked' and not e['retryable']; assert 'fetch https://y --full --json' in e['next_action']"
configure '{"default":{"text":"{\"items\":[{\"url\":\"https://x\",\"success\":false,\"statusCode\":429,\"error\":\"Concurrency limit reached\"}]}"}}'
run_cli raw --json -- scrape https://x --json
status_is 2 'native batch transient mapping'
jcheck 'native batch error action' "$OUT" "e=d['data']['items'][0]['error']; assert e['code']=='concurrency_limited' and e['retryable'] and e['next_action']"
configure '{"credit-usage":{"fixture":"quota.json","exit":1}}'
run_cli fetch https://x --json
status_is 1 'quota during credit preflight'
jcheck 'preflight keeps quota template' "$OUT" "assert d['error']['code']=='quota_exhausted' and not d['error']['retryable']"
[[ "$(wc -l <"$FIRECRAWL_TEST_LOG")" -eq 1 ]] && ok || bad 'quota preflight retried'
configure '{"credit-usage":{"fixture":"unauthorized.json","exit":1}}'
run_cli fetch https://x --json
status_is 2 'auth during credit preflight'
jcheck 'preflight keeps auth template' "$OUT" "assert d['error']['code']=='auth_failure' and d['error']['retryable']; assert 'firecrawl --status' in d['error']['next_action']"
# Live 2026-10-30: with no FIRECRAWL_API_KEY and no stored login, vendor 1.19.26
# prints its interactive login menu (ANSI colour included) on stdout and exits 0.
# That is a missing credential, not vendor drift: no retries and no drift check.
configure '{"credit-usage":{"fixture":"login-menu.txt"}}'
run_cli fetch https://x --json
status_is 1 'login menu during credit preflight'
jcheck 'login menu names the missing credential' "$OUT" "e=d['error']; assert e['code']=='credentials_missing' and not e['retryable'], e; assert 'FIRECRAWL_API_KEY' in e['next_action'] and 'firecrawl login' in e['next_action'], e"
[[ "$(wc -l <"$FIRECRAWL_TEST_LOG")" -eq 1 ]] && ok || bad 'login menu preflight retried'
omits "$ERR" 'failed transiently' 'login menu is not transient'
omits "$ERR" 'harness-doctor check 32' 'login menu is not vendor drift'
# Probed 2026-11-08 on vendor 1.26.25 with an empty HOME and no key: credit-usage exits 1
# with this stderr and prints nothing on stdout; it must read as a missing credential.
configure '{"credit-usage":{"stderr_text":"Error: Not authenticated. Set FIRECRAWL_API_KEY, pass --api-key, or run \"firecrawl login\" in a terminal.\n","exit":1}}'
run_cli fetch https://x --json
status_is 1 'not-authenticated error during credit preflight'
jcheck 'not-authenticated names the missing credential' "$OUT" "e=d['error']; assert e['code']=='credentials_missing' and not e['retryable'], e"
[[ "$(wc -l <"$FIRECRAWL_TEST_LOG")" -eq 1 ]] && ok || bad 'not-authenticated preflight retried'

# Date-valued Retry-After and shell quoting are deterministic without a provider.
RESULT=$(PYTHONDONTWRITEBYTECODE=1 python3 - "$MODULE" "$TMP/bin" "$TMP/work" <<'PY'
import importlib.util, subprocess, sys
from email.utils import formatdate
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('firecrawl_cli', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
with patch.object(m.time, 'time', return_value=1000):
    assert m.error_metadata({'details': {'headers': {'Retry-After': formatdate(1090, usegmt=True)}}}, '') == (None, 90, 90)
for value in ('nonsense', 'NaN', '-2', 'Infinity'):
    assert m.error_metadata({'headers': {'Retry-After': value}}, '') == (None, 5, None)
assert m.error_metadata({'error': 'Request failed with status code 402'}, '') == (402, 5, None)
assert m.error_metadata({'data': {'markdown': 'HTTP 402'}}, '') == (None, 5, None)
# The keyless refusal's body names its window as retry_after_seconds (#2118).
assert m.error_metadata({'reason': 'credits', 'retry_after_seconds': 13600}, 'HTTP 429') == (429, 13600, 13600)
query = 'a "quote"; $(touch forbidden) `false` $HOME \\ literal'
with patch.object(m.subprocess, 'run', return_value=m.subprocess.CompletedProcess([], 0, 'env\n', '')) as run:
    line = m.exa_fallback(query)
    run.assert_called_once_with(['exa-cli', '--where'], capture_output=True, text=True, errors='replace', timeout=5)
# A shell function captures the fallback arguments; it cannot contact Exa.
result = subprocess.run(
    [sys.argv[2] + '/bash', '-c', 'exa-cli() { printf "%s\\0" "$@"; }; ' + line.split('try: ', 1)[1]],
    cwd=sys.argv[3], env={'PATH': sys.argv[2]}, capture_output=True, text=True, check=True,
)
assert result.stdout.split('\0') == ['search', query, '--limit', '3', '--json', '']
print('OK')
PY
)
[[ "$RESULT" == OK ]] && ok || bad 'Retry-After dates and shell-safe fallback'

# AE1: local PDF routes to parse; bare URL to scrape; schema to JSON scrape.
touch "$TMP/work/report.pdf"
fixture parse
run_cli fetch ./report.pdf --json
status_is 0 'local PDF'
argv_is 'local PDF argv' "assert d == ['parse','$TMP/work/report.pdf','--only-main-content','--format','summary','--json']"
jcheck 'single envelope contract' "$OUT" "assert set(d)=={'ok','surface','verb','credits_spent','credits_remaining','budget_remaining','degraded','error','data'}; assert d['surface']=='parse' and d['verb']=='fetch' and d['ok']; assert d['data']['markdown']=='# Local document'"
fixture scrape
run_cli fetch https://x --json
status_is 0 'bare URL'
argv_is 'bare URL argv' "assert d == ['scrape','https://x','--only-main-content','--format','summary','--json']"
fixture scrape-json
run_cli fetch https://x --schema '{"type":"object"}' --json
status_is 0 'schema extraction'
argv_is 'schema format' "assert d == ['scrape','https://x','--format','json','--only-main-content','--schema','{\"type\":\"object\"}','--json']"
jcheck 'vendor payload preserved' "$OUT" "assert d['data']=={'json':{'title':'Example'},'metadata':{'sourceURL':'https://x'}}"

# AE7: safe correction includes adjacent transposition; protected flags refuse.
fixture scrape
run_cli fetch https://x --jsno
status_is 0 'safe flag typo'
contains "$ERR" '--json' 'safe correction warning'
contains "$ERR" 'warning' 'safe correction diagnostic'
jcheck 'corrected JSON' "$OUT" "assert d['ok']"
for flag in --allow-code-exex --raise-budge; do
  fixture interact
  run_cli interact 'print(1)' "$flag" --json
  status_is 4 'protected typo'
  no_calls 'protected typo'
  if [[ "$flag" == --allow-code-exex ]]; then
    contains "$ERR" '--allow-code-exec' 'protected spelling hint'
  else
    contains "$ERR" '--raise-budget' 'protected spelling hint'
  fi
done

# AE8: complete introspected contract, offline help/version, both flag positions.
fixture scrape
run_cli capabilities --json
status_is 0 capabilities
no_calls capabilities
jcheck 'capabilities verbs and exits' "$OUT" "c=d['data']; assert set(c['verbs'])=={'fetch','extract','shot','act','agent','interact','search','gov','developer','map','raw','capabilities','budget'}; assert set(c['exit_codes'])==set(map(str,range(7))); assert all(isinstance(v['retryable'],bool) for v in c['exit_codes'].values()); assert c['exit_codes']['2']['retryable']; assert all('flags' in v and 'cost_class' in v for v in c['verbs'].values()); assert '--schema' in c['verbs']['fetch']['flags']; assert 'limits' in c; assert 'monitor' in str(c['warnings']) and 'crawl' in str(c['warnings'])"
CAPS=$OUT
run_cli --json capabilities
status_is 0 'parent JSON flag'
[[ "$OUT" == "$CAPS" ]] && ok || bad 'parent flag clobbered'
for flag in --help --version; do
  run_cli "$flag"
  status_is 0 "$flag"
  no_calls "$flag"
done
# U1 contract: --help, --version, and capabilities never touch the ledger. A read-only
# HOME proves it (an unwritable state directory would otherwise exit 4); the stronger
# check, that no ~/.claude appears at all, holds even when the suite runs as root.
RO_HOME=$(mktemp -d "$TMP/ro-home.XXXXXX") || exit 1
chmod 500 "$RO_HOME"
for offline in '--help' '--version' 'capabilities --json'; do
  ST=0
  # shellcheck disable=SC2086
  (cd "$TMP/work" && HOME="$RO_HOME" PATH="$TMP/bin" "$CLI" $offline) >"$TMP/out" 2>"$TMP/err" || ST=$?
  status_is 0 "$offline under read-only HOME"
  [[ ! -e "$RO_HOME/.claude" ]] && ok || bad "$offline touched the ledger directory"
done
if [[ "$(id -u)" -ne 0 ]]; then
  ST=0
  (cd "$TMP/work" && HOME="$RO_HOME" PATH="$TMP/bin" "$CLI" budget --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
  status_is 4 'budget under read-only HOME'
  contains "$(cat "$TMP/err")" 'Permission denied' 'budget names the state-directory failure'
fi
chmod 700 "$RO_HOME"
# FIRECRAWL_CLI_STATE_DIR relocates the ledger (a sandbox with a read-only home
# points it at a writable directory); the default location stays untouched.
fixture scrape
ALT_STATE="$TMP/alt-state"
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_CLI_STATE_DIR="$ALT_STATE" "$CLI" budget --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
status_is 0 'budget with a relocated state directory'
[[ -f "$ALT_STATE/ledger.json" ]] && ok || bad 'relocated ledger not written'
[[ ! -e "$TMP/home/.claude/state/firecrawl-cli/ledger.json" ]] && ok || bad 'default ledger written despite override'
if [[ "$(id -u)" -ne 0 ]]; then
  chmod 500 "$RO_HOME"
  ST=0
  (cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_CLI_STATE_DIR="$RO_HOME/state" "$CLI" budget --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
  status_is 4 'unwritable state directory refuses'
  contains "$(cat "$TMP/err")" 'unwritable' 'unwritable state directory named'
  contains "$(cat "$TMP/err")" 'FIRECRAWL_CLI_STATE_DIR' 'unwritable state directory remedy'
  chmod 700 "$RO_HOME"
fi

# A sandbox with a read-only home (Codex workspace-write) still reaches the vendor: the
# ledger relocates and the vendor's throwaway working directory leaves home for /tmp.
# Before this fix the isolation directory under $HOME raised OSError, which retried into
# a misleading transient credit-usage failure.
if [[ "$(id -u)" -ne 0 ]]; then
  fixture scrape
  chmod 500 "$RO_HOME"
  ST=0
  (cd "$TMP/work" && HOME="$RO_HOME" PATH="$TMP/bin" FIRECRAWL_CLI_STATE_DIR="$TMP/sandbox-state" "$CLI" fetch https://x --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
  OUT=$(cat "$TMP/out")
  status_is 0 'vendor call under a read-only HOME'
  jcheck 'read-only HOME still bills the ledger' "$OUT" "assert d['ok']; assert d['credits_spent']==1"
  chmod 700 "$RO_HOME"
  rm -rf "$TMP/sandbox-state"
fi
run_cli --help
# argparse reflows the epilog, so a phrase can straddle a line break.
HELP_TEXT=$(printf '%s' "$OUT" | tr -s ' \n' '  ')
contains "$HELP_TEXT" 'after the verb' 'canonical JSON placement'
contains "$HELP_TEXT" 'cron callers must alert' 'AE16 unattended budget advice'
run_cli budget --json
jcheck 'U3 ledger schema' "$OUT" "assert d['data']['available']; assert isinstance(d['budget_remaining'], (int,float)); assert d['data']['tags']==[]"
run_cli capabilities --json
jcheck 'U3 tunable budget contract' "$OUT" "assert d['data']['budget']['session_budget']==300; assert d['data']['budget']['bounded_crawl']==100"

# Non-JSON vendor failure: JSON envelope on stdout, diagnostics on stderr.
configure '{"default":{"stderr":"usage.txt","exit":9}}'
run_cli fetch https://x --json
status_is 1 'plain vendor rejection'
jcheck 'failure stdout envelope' "$OUT" "assert not d['ok']"
jcheck 'structured error' "$OUT" "assert not d['ok']; assert d['error']['code']==1; assert 'vendor rejected the call' in d['error']['message']; assert '--weird-flag' in d['error']['message']; assert d['error']['next_action']"
omits "$ERR" 'Traceback' 'no traceback'
fixture empty
run_cli search nothing --json
status_is 0 'empty search'
jcheck 'empty list' "$OUT" "assert d['ok'] and d['data']==[]"
contains "$ERR" 'hint' 'empty result hint'

# No vendor on PATH: offline still works; paid verb names the latest reinstall
# (from 1.27.0 a global install updates itself, so nothing pins a release).
ST=0
HOME="$TMP/home" PATH="$TMP/no-vendor" "$CLI" fetch https://x --json >"$TMP/out" 2>"$TMP/err" || ST=$?
status_is 4 'missing vendor'
contains "$(cat "$TMP/err")" 'pnpm add -g firecrawl-cli@latest' 'latest reinstall remedy'
omits "$(cat "$TMP/err")" 'firecrawl-cli@1.' 'remedy pins no release'
# Issue #2105: nothing installs the vendor under mise, so that path was a dead end.
omits "$(cat "$TMP/err")" 'mise/installs/node' 'no dead mise remedy'

# Raw is exact passthrough (including unknown flags), wrapped without mutation.
fixture plain-success
run_cli raw --json -- scrape https://x --weird-flag
status_is 0 'raw unknown vendor flag'
argv_is 'raw unchanged' "assert d == ['scrape','https://x','--weird-flag']"
jcheck 'raw envelope' "$OUT" "assert d['surface']=='raw' and 'credits_spent' in d and d['data']['exitCode']==0"
fixture plain-success
run_cli raw -- scrape https://x --weird-flag
status_is 0 'raw canonical passthrough'
argv_is 'raw default unchanged' "assert d == ['scrape','https://x','--weird-flag']"
for subcommand in login logout config view-config env setup init launch launcher make; do
  fixture plain-success
  run_cli raw -- "$subcommand"
  status_is 4 "raw $subcommand"
  no_calls "raw $subcommand"
  contains "$ERR" 'credential' 'credential refusal reason'
  contains "$ERR" 'firecrawl --status' 'auth remedy'
done
# The vendor's self-updater (1.27.0+) stays the operator's: update --rollback and
# --disable-auto turn background updates off, so raw refuses the subcommand
# wherever it sits, while the same word as a positional value still passes.
fixture plain-success
run_cli raw -- update --rollback
status_is 4 'raw update --rollback'
no_calls 'raw update --rollback'
contains "$ERR" "refuses the vendor's self-update command" 'raw update refusal reason'
contains "$ERR" 'firecrawl update --help' 'raw update remedy'
fixture plain-success
run_cli raw -- --timeout 5 update --disable-auto
status_is 4 'raw update behind a value flag'
no_calls 'raw update behind a value flag'
fixture plain-success
run_cli raw -- scrape https://x update
status_is 0 'raw update as a positional value'
argv_is 'raw update as data unchanged' "assert d == ['scrape','https://x','update']"
for flag in --api-key --api-key=SECRET --api-url --api-url=https://evil -k -kSECRET; do
  fixture plain-success
  run_cli raw -- scrape https://x "$flag" SECRET
  status_is 4 'raw credential flag'
  no_calls 'raw credential flag'
  omits "$ERR" 'SECRET' 'credential redaction'
done
fixture plain-success
run_cli raw -- scrape https://x --jsno
status_is 4 'raw typo never corrected'
contains "$ERR" '--json' 'raw typo hint'
no_calls 'raw typo'
fixture plain-success
run_cli raw -- search env --json
status_is 0 'raw account word as data'
argv_is 'raw query unchanged' "assert d==['search','env','--json']"

# Multi-item envelopes and partial success are distinct from empty search arrays.
fixture multi
run_cli raw --json -- scrape https://x
status_is 0 'multi success'
jcheck 'multi contract' "$OUT" "assert d['error'] is None and d['credits_spent']==3; assert len(d['data']['items'])==2; assert all(set(('ok','error','credits_spent','data'))<=set(i) for i in d['data']['items']); assert d['data']['items'][0]['data']=={'markdown':'X'}"
fixture partial
run_cli raw --json -- scrape https://x
status_is 6 'partial success'
jcheck 'partial contract' "$OUT" "assert not d['ok'] and d['error'] is None; assert d['data']['items'][1]['error']['code']==1"
contains "$ERR" 'partial' 'partial diagnostic'

# Shape verbs and explicit text mode: code-looking text never becomes -c.
fixture interact
run_cli interact 'print(1)' --scrape-id X --json
status_is 0 'interact text'
argv_is 'interact text argv' "assert d==['interact','--prompt','print(1)','-s','X','--timeout','30','--json']; assert '-c' not in d"
fixture interact
run_cli interact stop --scrape-id X --json
status_is 0 'interact stop'
argv_is 'interact stop argv' "assert d==['interact','-s','X','stop','X','--json']"
fixture scrape
run_cli shot https://x --json
status_is 0 shot
argv_is 'shot argv' "assert d==['scrape','https://x','--screenshot','--only-main-content','--json']"
fixture scrape
run_cli act https://x --actions '[{"type":"wait","milliseconds":1}]' --json
status_is 0 act
argv_is 'act argv' "assert d[0:2]==['scrape','https://x']; assert json.loads(d[d.index('--actions')+1])[0]['type']=='wait'; assert '--only-main-content' in d"
fixture agent
run_cli agent 'find prices' --json
status_is 0 agent
argv_is 'agent argv' "assert d==['agent','find prices','--json']"
fixture map
run_cli map https://x --json
status_is 0 map
jcheck 'map payload' "$OUT" "assert d['data']['links'][0]['url']=='https://x'"
fixture search
run_cli search example --json
status_is 0 search
jcheck 'search payload' "$OUT" "assert d['data']['data']['web'][0]['title']=='Example'"
# Issue #2108: an empty bucket beside a populated one is not an empty result.
fixture search-research
run_cli search 'base editing' --categories research --json
status_is 0 'research-bucket search'
jcheck 'research papers pass through' "$OUT" "p=d['data']['data']; assert p['web']==[] and p['research'][0]['paperId']=='p-1'"
omits "$ERR" 'hint: empty result' 'no empty hint beside research papers'
fixture search-news
run_cli search 'edition' --sources web,news --json
status_is 0 'news-bucket search'
omits "$ERR" 'hint: empty result' 'no empty hint beside news items'
fixture search-all-empty
run_cli search 'nothing' --sources web,news --json
status_is 0 'all-buckets-empty search'
contains "$ERR" 'hint: empty result' 'empty hint when every bucket is empty'
fixture scrape-json
run_cli extract https://x -Q 'What is the title?' --json
status_is 0 'extract prompt'
argv_is 'extract prompt argv' "assert d==['scrape','https://x','--only-main-content','--query','What is the title?','--json']"
# #2123: vendor 1.19.26 printed a --query answer, and an empty search, as text despite --json.
configure '{"default":{"text":"Example Domain is a reserved page.\n","stderr_text":"Scrape ID: s-1\n"}}'
run_cli extract https://x -Q 'What is this page?' --json
status_is 0 'text query answer'
jcheck 'text query answer envelope' "$OUT" "assert d['ok'] and d['data']=={'answer':'Example Domain is a reserved page.'}; assert d['credits_spent']==5 and 'cost estimated, not measured' in d['degraded']"
run_cli extract report.pdf -Q 'What is this?' --json
status_is 0 'local text query answer'
jcheck 'local text query answer envelope' "$OUT" "assert d['data']=={'answer':'Example Domain is a reserved page.'} and d['credits_spent']==25"
configure '{"default":{"text":"42"}}'
run_cli extract https://x -Q 'How many?' --json
status_is 0 'JSON-scalar query answer'
jcheck 'JSON-scalar answer stays text' "$OUT" "assert d['data']=={'answer':'42'}"
configure '{"default":{"text":"{\"title\":\"Example\"}"}}'
run_cli extract https://x -Q 'Return the title as JSON' --json
status_is 0 'JSON-object query answer'
jcheck 'JSON-object answer stays text' "$OUT" "assert d['data']=={'answer':'{\"title\":\"Example\"}'}"
fixture scrape-json
run_cli extract https://x -Q 'What is this page?' --json
jcheck 'empty-answer document passes through' "$OUT" "assert 'metadata' in d['data'] and 'answer' not in d['data']"
configure '{"default":{"text":""}}'
run_cli extract https://x -Q 'What is this page?' --json
status_is 2 'empty query output stays malformed'
jcheck 'empty query output code' "$OUT" "assert d['error']['code']=='vendor_output_changed' and d['credits_spent']==0"
for printed in 'No results found.\n' ''; do
  configure "{\"default\":{\"text\":\"$printed\"}}"
  run_cli search nothing --sources web,news --json
  status_is 0 "text empty search: '$printed'"
  jcheck "text empty search buckets: '$printed'" "$OUT" "assert d['ok'] and d['data']=={'success':True,'data':{'web':[],'news':[]}}; assert d['credits_spent']==2"
  contains "$ERR" 'hint: empty result' "text empty search hint: '$printed'"
done
configure '{"default":{"text":"No results found.\n"}}'
run_cli search nothing --json
jcheck 'text empty search defaults to web' "$OUT" "assert d['data']['data']=={'web':[]}"
omits "$OUT" 'research-bucket' 'no research note without the category'
run_cli search nothing --categories research --json
jcheck 'text empty research search note' "$OUT" "assert any('research-bucket' in note for note in d['degraded'])"
run_cli fetch https://x --json
status_is 2 'no-results text outside search stays malformed'
jcheck 'no-results text outside search code' "$OUT" "assert d['error']['code']=='vendor_output_changed'"
configure '{"default":{"text":"No results found.\n","exit":1}}'
run_cli search nothing --json
status_is 1 'failed search printing no-results stays a failure'
fixture scrape
run_cli extract https://x --json
status_is 4 'extract needs schema or prompt'
no_calls 'extract validation'
run_cli act https://x --json
status_is 4 'act needs actions'
no_calls 'actions validation'
run_cli budget --json
status_is 0 'budget offline surface'
no_calls budget

# Schema/action files and invalid input fail before invoking the vendor.
printf '{"type":"object"}\n' >"$TMP/work/schema.json"
printf '[]\n' >"$TMP/work/actions.json"
fixture scrape-json
run_cli extract https://x --schema-file schema.json --json
status_is 0 'schema file'
argv_is 'schema file argv' "assert '--schema-file' in d and '--format' in d"
fixture scrape
run_cli act https://x --actions-file actions.json --json
status_is 0 'actions file'
argv_is 'actions file argv' "assert '--actions-file' in d"
fixture scrape
run_cli fetch https://x --schema broken --json
status_is 4 'malformed JSON'
no_calls 'malformed JSON'
run_cli fetch ./missing.pdf --json
status_is 4 'missing local file'
no_calls 'missing local file'
run_cli crawl https://x --json
status_is 4 'raw-only command'
# Vendor crawl and monitor print JSON by default and reject --json (live
# 2026-10-30), so the remedy keeps --json on the wrapper side of the separator.
contains "$ERR" 'next: firecrawl-cli raw --json -- crawl https://x' 'raw-only remedy'
omits "$ERR" 'crawl https://x --json' 'raw-only remedy passes no vendor --json'
run_cli --json monitor list
status_is 4 'raw-only monitor'
contains "$ERR" 'next: firecrawl-cli raw --json -- monitor list' 'raw-only monitor remedy keeps a leading --json'

# The fake can model file-writing without littering the checkout.
configure '{"default":{"fixture":"plain-success.json","write":"vendor-artifact.txt"}}'
run_cli raw -- scrape https://x --json
status_is 0 'fake vendor file writer'
[[ -f "$TMP/work/vendor-artifact.txt" ]] && ok || bad 'fake did not write artifact'

# Regression checks for inference, scalar JSON, error payloads, and token values.
fixture scrape
run_cli https://x --json
status_is 0 'implicit URL fetch'
argv_is 'implicit URL argv' "assert d==['scrape','https://x','--only-main-content','--format','summary','--json']"
fixture parse
run_cli ./report.pdf --json
status_is 0 'implicit file fetch'
argv_is 'implicit file argv' "assert d==['parse','$TMP/work/report.pdf','--only-main-content','--format','summary','--json']"
fixture scrape
run_cli fetch https://x --jso
status_is 0 'one deletion typo'
contains "$ERR" '--json' 'deletion correction'
fixture scrape
run_cli fetch https://x -Q=--jsno --json
status_is 0 'option-like query value'
argv_is 'query value unchanged' "assert '--jsno' in d"
fixture scrape
run_cli fetch https://x --j
status_is 4 'abbreviations disabled'
no_calls 'abbreviations disabled'
fixture scrape
run_cli fetch https://x --schema-file nonexistent.json --json
status_is 4 'missing schema file'
no_calls 'missing schema file'
run_cli act https://x --actions '{}' --json
status_is 4 'actions must be array'
no_calls 'actions array validation'
run_cli search example --limit 101 --json
status_is 4 'search limit'
no_calls 'search limit validation'
run_cli budget --raise-budget 100 --json
status_is 4 'raise requires a reason'
no_calls 'no ledger side effects'
run_cli interact 'print(1)' --allow-code-exec --json
status_is 4 'opt-in cannot supply a missing scrape id'
no_calls 'no accidental code invocation'
configure '{"default":{"fixture":"plain-success.json","exit":7}}'
run_cli raw --json -- scrape https://x
status_is 1 'vendor exit is not wrapper exit'
jcheck 'error payload preserved' "$OUT" "assert d['data']=={'success':True,'exitCode':7,'value':'opaque vendor payload'} and d['error']['code']==1"
jcheck 'JSON vendor failure stdout' "$OUT" "assert not d['ok']"
configure '{"default":{"fixture":"usage.txt"}}'
run_cli fetch https://x --json
status_is 2 'malformed vendor success'
jcheck 'malformed vendor error' "$OUT" "assert d['error']['code']=='vendor_output_changed' and 'JSON' in d['error']['message']"
configure '{"default":{"fixture":"partial.json","exit":1}}'
run_cli raw --json -- scrape https://x
status_is 6 'multi partial on nonzero vendor exit'
jcheck 'partial items preserved' "$OUT" "assert d['error'] is None and not d['data']['items'][1]['ok']"
configure '{"default":{"fixture":"multi.json","exit":1}}'
run_cli raw --json -- scrape https://x
status_is 1 'nonzero vendor exit with successful items'
jcheck 'vendor failure not masked by items' "$OUT" "assert d['error']['code']==1 and len(d['data']['items'])==2"
jcheck 'nonzero multi failure stdout' "$OUT" "assert not d['ok']"

# U2: sequential one-URL calls, no caller-directory writes, and mixed outcomes.
snapshot() {
  python3 - "$TMP/work" <<'PY'
import pathlib, sys
print('\n'.join(sorted(str(p.relative_to(sys.argv[1])) for p in pathlib.Path(sys.argv[1]).rglob('*'))))
PY
}
BEFORE=$(snapshot)
for verb in fetch shot act; do
  configure '{"default":{"fixture":"scrape.json","write":"unexpected-vendor-write.txt"}}'
  extra=()
  [[ "$verb" == act ]] && extra=(--actions '[]')
  run_cli "$verb" https://x https://y https://z "${extra[@]}" --json
  status_is 0 "three URL $verb"
  jcheck "three URL $verb envelope" "$OUT" "assert len(d['data']['items'])==3; assert all(i['ok'] for i in d['data']['items'])"
  CALLS=$(python3 -c 'import json,os; print(json.dumps([json.loads(line) for line in open(os.environ["FIRECRAWL_TEST_LOG"]) if json.loads(line)[0]!="credit-usage"]))')
  jcheck "three URL $verb calls" "$CALLS" "assert len(d)==3; assert [a[1] for a in d]==['https://x','https://y','https://z']; assert all(sum(v.startswith('https://') for v in a)==1 for a in d)"
  [[ "$(snapshot)" == "$BEFORE" ]] && ok || bad "three URL $verb wrote to cwd"
done
configure '{"default":{"fixture":"scrape.json"},"targets":{"https://y":{"text":"{\"success\":false,\"error\":\"unsupported site\"}","exit":1}}}'
run_cli fetch https://x https://y https://z --json
status_is 6 'fan-out mixed outcome'
jcheck 'fan-out mixed items' "$OUT" "i=d['data']['items']; assert [v['ok'] for v in i]==[True,False,True]; assert 'unsupported site' in i[1]['error']['message']; assert all(set(('ok','error','credits_spent','data')) <= set(v) for v in i)"

# AE10: unsupported extensions and oversized inputs fail before all vendor calls.
python3 - "$TMP/work" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
(root / 'notes.txt').write_text('Read me locally')
with (root / 'large.pdf').open('wb') as stream:
    stream.truncate(51 * 1024 * 1024)
PY
for target in notes.txt large.pdf; do
  fixture parse
  run_cli fetch "$target" --json
  status_is 4 "parse pre-check $target"
  no_calls "parse pre-check $target"
  if [[ "$target" == notes.txt ]]; then
    contains "$ERR" '.txt' 'unsupported extension named'
    contains "$ERR" 'locally' 'local read alternative'
  else
    contains "$ERR" '51' 'oversize size named'
    contains "$ERR" 'split' 'oversize alternative'
  fi
done
fixture scrape
run_cli fetch https://x notes.txt --json
status_is 4 'pre-check entire batch'
no_calls 'pre-check entire batch'

configure '{"default":{"body_size":30000}}'
run_cli fetch https://x --json
status_is 0 'bounded body is successful'
jcheck 'bounded body' "$OUT" "assert len(d['data']['data']['markdown'])==24576; assert 'body truncated at 24576 chars; --full lifts the bound' in d['degraded']; assert 'cost estimated, not measured' in d['degraded']"
jcheck 'oversized response next command' "$OUT" "assert d['error'] is None and d['ok']; assert 'next: firecrawl-cli fetch https://x --json --full' in d['degraded']"
argv_is 'cheap defaults' "assert '--only-main-content' in d and d[d.index('--format')+1]=='summary'"
configure '{"default":{"body_size":30000}}'
run_cli fetch https://x --full --json
status_is 0 'full body'
jcheck 'full body unbounded' "$OUT" "assert len(d['data']['data']['markdown'])==30000 and d['degraded']==['cost estimated, not measured']"
argv_is 'full format' "assert '--full' not in d and d[d.index('--format')+1]=='markdown'"
run_cli capabilities --json
jcheck 'injection limitation' "$OUT" "assert d['data']['injection_check']=='unavailable through the vendor CLI v1.26.25; the API json-format option is not exposed'"
for verb in fetch extract; do
  run_cli "$verb" --help
  contains "$OUT" 'Injection check unavailable' "$verb injection help"
done
run_cli raw --help
contains "$OUT" 'best-effort' 'raw snapshot help'
contains "$OUT" 'non-exclusive' 'raw snapshot concurrency help'

configure '{"default":{"text":"plain vendor text"}}'
run_cli raw -- scrape https://x
status_is 0 'raw plain text'
jcheck 'raw plain text envelope' "$OUT" "assert d['ok'] and d['data']=={'text':'plain vendor text','exitCode':0}"
configure '{"default":{"text":"plain vendor text","exit":9,"write":"raw-failed.txt"}}'
run_cli raw --json -- scrape https://x
status_is 1 'raw failed plain text'
jcheck 'raw failed text and write' "$OUT" "assert d['data']['text']=='plain vendor text' and d['data']['exitCode']==9; assert 'vendor wrote raw-failed.txt' in d['degraded']"
run_cli raw -- scrape https://x
status_is 1 'raw failure stays wrapped without JSON flag'
jcheck 'raw failure envelope without JSON flag' "$ERR" "assert d['data']['exitCode']==9 and 'vendor wrote raw-failed.txt' in d['degraded']; assert d['error']['next_action'] and not d['error']['retryable']"
configure '{"default":{"fixture":"plain-success.json","write":"raw-success.txt"}}'
run_cli raw -- scrape https://x
jcheck 'raw write reported' "$OUT" "assert 'vendor wrote raw-success.txt' in d['degraded']"

configure '{"default":{"stderr_text":"\u001b[31mdenied Bearer abcDEF123456 --token tokenSECRET --api-key keySECRET -k shortSECRET\u001b[0m","exit":9}}'
run_cli fetch https://x --json
status_is 1 'redacted ANSI vendor stderr'
for secret in abcDEF123456 tokenSECRET keySECRET shortSECRET; do
  omits "$ERR" "$secret" 'vendor stderr secret'
done
jcheck 'ANSI stripped and redacted' "$OUT" "assert '\x1b' not in d['error']['message'] and '[REDACTED]' in d['error']['message']"
fixture scrape
run_cli raw -- search --token 'SECRET with spaces' --jsno
status_is 4 'raw typo token redaction'
omits "$ERR" 'SECRET' 'raw argv token value'

configure '{"default":{"stderr_text":"vendor timeout expired","exit":1}}'
run_cli fetch report.pdf --timeout 2 --vendor-timeout 100 --json
status_is 1 'vendor timeout'
contains "$ERR" 'vendor timeout' 'vendor timeout distinction'
contains "$ERR" 'wrapper --timeout=2' 'wrapper timeout reported'
contains "$ERR" 'vendor --timeout=100 ms' 'vendor timeout reported'
argv_is 'vendor timeout mapping' "assert d[d.index('--timeout')+1]=='100'"
# Issue #1308: the fetch path first reads credit-usage with the SAME --timeout,
# and that pre-read spawns the python fake vendor up to three times. At 0.05 s
# a loaded CI runner's python start-up alone outran the budget, every pre-read
# expired, and the CLI exited 2 ("credit-usage read failed on all three retry
# attempts") before the fetch ever ran -- so these assertions measured spawn
# latency, not the timeout path they name. 1 s gives the pre-read ~30x its idle
# cost; the fixture sleeps 3 s so the vendor can never answer before the
# wrapper expires (load only delays the vendor further). The wrapper kills the
# sleeping child at 1 s, so the case costs 1 s, not 3.
configure '{"default":{"sleep":3,"fixture":"parse.json"}}'
run_cli fetch report.pdf --timeout 1 --vendor-timeout 100 --json
status_is 1 'wrapper timeout'
contains "$ERR" 'wrapper subprocess timeout' 'wrapper timeout distinction'
contains "$ERR" 'wrapper --timeout=1 s' 'wrapper expiry reports the fetch call, not the credit pre-read'
contains "$ERR" 'vendor --timeout=100 ms' 'wrapper expiry reports vendor timeout'

fixture scrape
run_cli fetch https://x https://z -o results.json --json
status_is 0 'explicit output'
jcheck 'named output envelope' "$(cat "$TMP/work/results.json" 2>/dev/null)" "assert len(d['data']['items'])==2"

# Every fixture in the source bundle above has a call scenario in this suite.

# U3: offline accounting uses the host-verified credit-usage shape (2026-09-13).
LEDGER="$TMP/home/.claude/state/firecrawl-cli/ledger.json"
ledger_edit() {
  python3 - "$LEDGER" "$1" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
h = next(iter(d['hosts'].values()))
day = h['days'][max(h['days'])]
exec(sys.argv[2])
p.write_text(json.dumps(d))
PY
}
paid_calls() {
  python3 - "$FIRECRAWL_TEST_LOG" <<'PY'
import json, sys
print(sum(json.loads(line)[0] != 'credit-usage' for line in open(sys.argv[1])))
PY
}
error_json() { tail -n 1 "$TMP/out"; }

export CLAUDE_CODE_SESSION_ID='session-full-value-abcdefgh'

# Issue #1380: only exact, validated research --help is local and uncharged.
# Inspect the complete vendor log: argv_is deliberately hides credit-usage.
for budget_state in normal exhausted; do
  configure '{"default":{"text":"Usage: firecrawl research [options]\n"},"credit-usage":{"failures":99}}'
  run_cli budget --json
  if [[ "$budget_state" == exhausted ]]; then
    ledger_edit "h['sessions']['session-full-value-abcdefgh']['spent']=300; day['spent']=300"
    run_cli budget --json
  fi
  cp "$LEDGER" "$TMP/help-ledger-before.json"
  cp "${LEDGER%/*}/snapshot.json" "$TMP/help-snapshot-before.json"
  run_cli raw --json -- research --help
  status_is 0 "research help with $budget_state budget and failing credit query"
  argv_is 'research help exact passthrough' "assert d==['research','--help'], d"
  all_argv_is 'research help is the sole vendor call' "assert d==[['research','--help']], d"
  jcheck 'research help text and unestimated zero-cost envelope' "$OUT" "assert d['ok'] and d['verb']=='raw' and d['surface']=='raw'; assert d['data']=={'text':'Usage: firecrawl research [options]\\n','exitCode':0}; assert d['credits_spent']==0 and d['credits_remaining'] is None and d['degraded'] is None"
  [[ ! -s "$TMP/err" ]] && ok || bad 'research help emitted diagnostics'
  cmp -s "$LEDGER" "$TMP/help-ledger-before.json" && cmp -s "${LEDGER%/*}/snapshot.json" "$TMP/help-snapshot-before.json" && ok || bad 'research help changed the ledger or snapshot'
  run_cli budget --json
  jcheck 'research help creates no spend or reservation' "$OUT" "expected=300 if '$budget_state'=='exhausted' else 0; assert d['data']['session']['spent']==expected and d['data']['day_state']['spent']==expected and not d['data']['reservations']; assert d['budget_remaining']==300-expected"
done

configure '{"default":{"text":"research local help\n"}}'
run_cli raw -- research --help
status_is 0 'research help without wrapper json flag'
jcheck 'raw help keeps its default JSON envelope' "$OUT" "assert d['data']=={'text':'research local help\\n','exitCode':0} and d['credits_spent']==0 and d['degraded'] is None"
all_argv_is 'bare raw help also skips credit queries' "assert d==[['research','--help']], d"

configure '{"default":{"text":"research local help\n","stderr_text":"unknown research option","exit":9},"credit-usage":{"failures":99}}'
run_cli raw --json -- research --help
status_is 1 'research help vendor failure uses normal wrapper exit mapping'
jcheck 'research help failure envelope' "$OUT" "assert not d['ok'] and d['error']['code']==1 and d['error']['next_action']; assert d['data']=={'text':'research local help\\n','exitCode':9}; assert d['credits_spent']==0 and d['credits_remaining'] is None and d['degraded'] is None"
contains "$ERR" 'unknown research option' 'research help vendor error detail'
all_argv_is 'failing research help is still the sole vendor call' "assert d==[['research','--help']], d"
run_cli budget --json
jcheck 'failed research help leaves no charge or hold' "$OUT" "assert d['data']['session']['spent']==0 and d['data']['day_state']['spent']==0 and not d['data']['reservations']"

# The same exact `<verb> --help` is local for every listed vendor work verb, not
# only research: no credit query, no charge, no 100-credit hold.
for verb in scrape crawl batch-scrape map search agent find-skills alexandria; do
  configure "{\"default\":{\"text\":\"Usage: firecrawl $verb [options]\\n\"},\"credit-usage\":{\"failures\":99}}"
  run_cli raw --json -- "$verb" --help
  status_is 0 "$verb help is local"
  all_argv_is "$verb help is the sole vendor call" "assert d==[['$verb','--help']], d"
  jcheck "$verb help zero-cost envelope" "$OUT" "assert d['ok'] and d['credits_spent']==0 and d['credits_remaining'] is None and d['degraded'] is None"
  run_cli budget --json
  jcheck "$verb help leaves no charge or hold" "$OUT" "assert d['data']['session']['spent']==0 and not d['data']['reservations']"
done

configure '{"default":{"text":"research local help\n"}}'
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/no-vendor" "$CLI" raw --json -- research --help) >"$TMP/out" 2>"$TMP/err" || ST=$?
OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
status_is 4 'research help without vendor is a normal missing-vendor error'
jcheck 'missing research vendor envelope' "$OUT" "assert not d['ok'] and d['error']['code']==4 and d['credits_spent']==0 and d['credits_remaining'] is None"
contains "$ERR" 'vendor firecrawl is missing from PATH' 'research help missing vendor detail'
# Issue #2105: nothing installs the vendor into mise; name the latest reinstall.
contains "$ERR" 'pnpm add -g firecrawl-cli@latest' 'missing vendor names the latest reinstall'
no_calls 'missing research vendor invokes nothing'
run_cli budget --json
jcheck 'missing research vendor creates no reservation' "$OUT" "assert not d['data']['reservations'] and d['data']['session']['spent']==0"

# The exemption stays behind wrapper timeouts, raw restrictions, and consent.
for timeout in 0 3600; do
  configure '{"default":{"text":"research local help\n"}}'
  run_cli raw --timeout "$timeout" --json -- research --help
  status_is 4 'research help preserves timeout validation'
  no_calls 'invalid research help timeout invokes nothing'
done
for guard in account credential typo consent; do
  fixture plain-success
  case "$guard" in
    account) vendor_args=(config research --help); expected_status=4 ;;
    credential) vendor_args=(research --help --api-key SYNTHETIC); expected_status=4 ;;
    typo) vendor_args=(research --help --jsno); expected_status=4 ;;
    consent) vendor_args=(research --help interact -c 'print(1)' -s X); expected_status=5 ;;
  esac
  run_cli raw --json -- "${vendor_args[@]}"
  status_is "$expected_status" "research help preserves $guard guard"
  no_calls "research help preserves $guard guard"
done

# Planted bypasses: values, substrings, other help spellings, and added argv
# remain normal raw work. Each costs 100 when admitted and is refused at zero.
for candidate in question prompt extra-command extra-flag unknown short-help equals-help reordered-help redundant-separator ordinary scrape-url scrape-short-help; do
  case "$candidate" in
    question) vendor_args=(research read-paper paper-id --question --help) ;;
    prompt) vendor_args=(research ask 'explain --help usage') ;;
    extra-command) vendor_args=(research --help read-paper paper-id) ;;
    extra-flag) vendor_args=(research --help --json) ;;
    unknown) vendor_args=(future-expensive-verb --help) ;;
    short-help) vendor_args=(research -h) ;;
    equals-help) vendor_args=(research --help=true) ;;
    reordered-help) vendor_args=(--help research) ;;
    redundant-separator) vendor_args=(-- research --help) ;;
    ordinary) vendor_args=(research search-papers 'research topic') ;;
    scrape-url) vendor_args=(scrape https://x --help) ;;
    scrape-short-help) vendor_args=(scrape -h) ;;
  esac
  expected_argv=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${vendor_args[@]}")
  fixture plain-success
  run_cli raw --json -- "${vendor_args[@]}"
  status_is 0 "research help bypass negative admitted: $candidate"
  argv_is "research help bypass preserves argv: $candidate" "assert d==$expected_argv, d"
  all_argv_is "research help bypass probes credit normally: $candidate" "assert d==[['credit-usage','--json'],$expected_argv], d"
  jcheck "research help bypass charged conservatively: $candidate" "$OUT" "assert d['credits_spent']==100 and d['budget_remaining']==200 and 'cost estimated, not measured' in d['degraded']"
  run_cli budget --json
  jcheck "research help bypass retains the 100-credit hold: $candidate" "$OUT" "r=list(d['data']['reservations'].values()); assert len(r)==1 and r[0]['amount']==100 and r[0]['state']=='held'"
  fixture plain-success
  run_cli budget --json
  ledger_edit "h['sessions']['session-full-value-abcdefgh']['spent']=300"
  run_cli raw --json -- "${vendor_args[@]}"
  status_is 3 "research help bypass refused at exhausted budget: $candidate"
  all_argv_is "research help bypass never executes at exhausted budget: $candidate" "assert d==[['credit-usage','--json']], d"
done

fixture scrape
run_cli fetch https://x --json
status_is 0 'AE13 first uncosted scrape'
jcheck 'AE13 documented estimate' "$OUT" "assert d['credits_spent']==1; assert d['credits_remaining']==2856; assert d['budget_remaining']==299; assert 'cost estimated, not measured' in d['degraded']"
run_cli budget --json
jcheck 'AE13 recorded charge' "$OUT" "assert d['data']['session']['spent']==1; assert d['data']['session_id']=='session-full-value-abcdefgh'; assert not d['data']['reservations']"
python3 - "$LEDGER" <<'PY'
import pathlib, stat, sys
p = pathlib.Path(sys.argv[1])
assert stat.S_IMODE(p.parent.stat().st_mode) == 0o700
assert all(stat.S_IMODE(f.stat().st_mode) == 0o600 for f in (p, p.with_name('snapshot.json')))
PY
[[ $? == 0 ]] && ok || bad 'private ledger modes'

# Live 2026-09-13: scrape and parse report their charge at data.metadata.creditsUsed.
# A reported cost is measured, never flagged as an estimate, and is what the ledger records.
fixture scrape-metered
run_cli fetch https://x --json
status_is 0 'metered scrape'
jcheck 'metadata.creditsUsed is the measured cost' "$OUT" "assert d['credits_spent']==3; assert not (d['degraded'] or []) or 'cost estimated, not measured' not in d['degraded']"
run_cli budget --json
jcheck 'metered charge recorded' "$OUT" "assert d['data']['session']['spent']==3"

# A read-only pass (reap with nothing to free) leaves the ledger bytes untouched.
REV_BEFORE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$LEDGER")
run_cli budget --json
REV_AFTER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$LEDGER")
[[ "$REV_BEFORE" == "$REV_AFTER" ]] && ok || bad "read-only pass rewrote the ledger ($REV_BEFORE -> $REV_AFTER)"

# The vendor period total is larger than the remaining balance: only the latter
# may satisfy the floor, even when the local session still has its full budget.
export FIRECRAWL_CLI_FLOOR=3000
fixture scrape
run_cli fetch https://x --json
status_is 3 'host credit shape floor refusal'
jcheck 'floor reads remaining rather than period total' "$(error_json)" "assert d['credits_remaining']==2856 and d['budget_remaining']==300 and d['credits_spent']==0"
[[ "$(paid_calls)" == 0 ]] && ok || bad 'host credit shape floor allowed paid call'
unset FIRECRAWL_CLI_FLOOR

# AE3: N-1 spent refuses a two-credit search before any paid invocation.
fixture search
run_cli budget --json
ledger_edit "h['sessions']['session-full-value-abcdefgh']['spent']=299"
run_cli search query --json
status_is 3 'AE3 pre-call refusal'
contains "$ERR" '1 credits remaining' 'AE3 remaining amount'
contains "$ERR" '--raise-budget' 'AE3 remedy'
[[ "$(paid_calls)" == 0 ]] && ok || bad 'AE3 paid vendor invoked'
jcheck 'refusal accounting envelope' "$(error_json)" "assert d['credits_spent']==0 and d['credits_remaining']==2856 and d['budget_remaining']==1"
run_cli budget --raise-budget 50 --reason 'one-off crawl' --json
status_is 0 'reasoned raise'
jcheck 'recorded raise' "$OUT" "assert d['data']['raises'][0]['amount']==50 and d['data']['raises'][0]['reason']=='one-off crawl'; assert d['budget_remaining']==51"
run_cli search query --json
status_is 0 'raised budget admits next call'
run_cli budget --raise-budget 451 --reason 'over bound' --json
status_is 3 'cumulative daily raise bound'
contains "$ERR" '500' 'raise bound named'
contains "$ERR" 'session budget' 'raise names session'
run_cli budget --raise-budget 1 --reason '   ' --json
status_is 4 'blank reason refused'

# AE11: exactly two charges; a failing URL releases its reservation immediately.
configure '{"default":{"fixture":"scrape.json"},"targets":{"https://y":{"text":"{\"success\":false,\"error\":\"failed\"}","exit":1}}}'
run_cli fetch https://x https://y https://z --json
status_is 6 'AE11 mixed fan-out accounting'
jcheck 'AE11 item charges' "$OUT" "assert d['credits_spent']==2; assert [i['credits_spent'] for i in d['data']['items']]==[1,0,1]"
run_cli budget --json
jcheck 'AE11 exactly two ledger charges' "$OUT" "assert d['data']['session']['spent']==2 and d['data']['day_state']['spent']==2; assert not d['data']['reservations']"

configure '{"default":{"exit":1,"stderr_text":"immediate failure"}}'
run_cli fetch https://x --json
status_is 1 'immediate failure'
run_cli budget --json
jcheck 'failure synchronously released' "$OUT" "assert not d['data']['reservations']; assert d['budget_remaining']==300 and d['data']['day_state']['spent']==0"
# Issue #1308: same pre-read spawn-cost margin as the wrapper-timeout case above.
configure '{"default":{"sleep":3,"fixture":"scrape.json"}}'
run_cli fetch https://x --timeout 1 --json
status_is 1 'timeout releases reservation'
run_cli budget --json
jcheck 'timeout release before expiry' "$OUT" "assert not d['data']['reservations'] and d['budget_remaining']==300"

# Reported job costs adjust held reservations; raw never shrinks on zero delta.
fixture agent-cost
run_cli agent prompt --json
status_is 0 'reported agent cost'
jcheck 'agent reconciles to creditsUsed' "$OUT" "assert d['credits_spent']==17 and d['budget_remaining']==283; assert d['degraded'] is None"
run_cli budget --json
jcheck 'agent lag hold uses reported cost' "$OUT" "r=list(d['data']['reservations'].values()); assert len(r)==1 and r[0]['amount']==17 and r[0]['state']=='held'"
export FIRECRAWL_CLI_SESSION_BUDGET=40
run_cli agent agent-job --status --json
status_is 0 'status poll is a free read'
jcheck 'status poll reserves nothing beyond the existing hold' "$OUT" "assert d['budget_remaining']==23 and d['credits_spent']==0"
unset FIRECRAWL_CLI_SESSION_BUDGET
fixture plain-success
run_cli raw --json -- crawl https://x --limit 100 --json
status_is 0 'raw zero-delta crawl'
jcheck 'raw conservative cost' "$OUT" "assert d['credits_spent']==100 and d['budget_remaining']==200; assert 'cost estimated, not measured' in d['degraded']"
run_cli budget --json
jcheck 'raw hold stays reserved' "$OUT" "assert sum(r['amount'] for r in d['data']['reservations'].values())==100"
ledger_edit "[r.update(created=0) for r in h['reservations'].values()]"
run_cli budget --json
jcheck 'settled hold becomes spent, never free' "$OUT" "assert not d['data']['reservations']; assert d['data']['day_state']['spent']==100 and d['budget_remaining']==200"

# Issue #2117, live 2026-10-30: a finished raw job's creditsUsed is the charge.
# A terminal status, or none at all (a synchronous answer), makes it final; the
# reported cost is still held until settle_window, then settles as reported.
# A failed job bills its partial work, and a reported 0 is a charge of 0.
for shape in raw-crawl-completed:2 raw-agent-completed:5 search-id:2 raw-crawl-failed:1 raw-crawl-cancelled-free:0; do
  name=${shape%%:*} charge=${shape##*:}
  fixture "$name"
  run_cli raw --json -- crawl https://x --wait
  status_is 0 "finished raw job: $name"
  jcheck "finished raw job charges the reported cost: $name" "$OUT" "assert d['credits_spent']==$charge and d['budget_remaining']==300-$charge; assert 'cost estimated, not measured' not in (d['degraded'] or [])"
  run_cli budget --json
  jcheck "finished raw job holds only the reported cost: $name" "$OUT" "r=list(d['data']['reservations'].values()); assert len(r)==1 and r[0]['amount']==$charge and r[0]['state']=='held'"
  ledger_edit "[r.update(created=0) for r in h['reservations'].values()]"
  run_cli budget --json
  jcheck "finished raw job settles as reported: $name" "$OUT" "assert not d['data']['reservations']; assert d['data']['day_state']['spent']==$charge and d['budget_remaining']==300-$charge"
done

# Planted negatives: a running job's creditsUsed is a running total, a started
# job reports nothing yet, and a status the wrapper cannot read is not terminal.
# Each keeps today's 100-credit hold and settles 100.
for name in raw-crawl-running raw-crawl-started raw-agent-running raw-running-parent raw-opaque-status; do
  fixture "$name"
  run_cli raw --json -- crawl https://x
  status_is 0 "unfinished raw job: $name"
  jcheck "unfinished raw job is labelled an estimate: $name" "$OUT" "assert 'cost estimated, not measured' in d['degraded']"
  run_cli budget --json
  jcheck "unfinished raw job keeps the 100-credit hold: $name" "$OUT" "r=list(d['data']['reservations'].values()); assert len(r)==1 and r[0]['amount']==100 and r[0]['state']=='held'"
  ledger_edit "[r.update(created=0) for r in h['reservations'].values()]"
  run_cli budget --json
  jcheck "unfinished raw job settles the full hold: $name" "$OUT" "assert d['data']['day_state']['spent']==100 and d['budget_remaining']==200"
done

# AE12 and concurrency: a novel raw verb blocks so its reservation is observable.
export FIRECRAWL_CLI_SESSION_BUDGET=150
configure "{\"default\":{\"fixture\":\"plain-success.json\",\"block\":\"$TMP/release\"}}"
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" "$CLI" raw --json -- future-expensive-verb --json) >"$TMP/concurrent-out" 2>"$TMP/concurrent-err" &
FIRST_PID=$!
for ((attempt=0; attempt<200; attempt++)); do
  [[ -f "$TMP/release.entered" ]] && break
  sleep 0.02
done
[[ -f "$TMP/release.entered" ]] && ok || bad 'blocking fixture entered'
run_cli budget --json
jcheck 'AE12 unknown raw worst-case observable' "$OUT" "r=list(d['data']['reservations'].values()); assert len(r)==1 and r[0]['amount']==100 and r[0]['state']=='active'; assert d['budget_remaining']==50"
run_cli raw --json -- another-future-verb --json
status_is 3 'concurrent second call refused'
[[ "$(paid_calls)" == 1 ]] && ok || bad 'concurrent reservation exceeded ceiling'
touch "$TMP/release"
ST=0
wait "$FIRST_PID" || ST=$?
status_is 0 'first concurrent call completed'
run_cli budget --json
jcheck 'concurrency total within ceiling' "$OUT" "assert d['budget_remaining']==50 and len(d['data']['reservations'])==1"
unset FIRECRAWL_CLI_SESSION_BUDGET

# Reap abandoned work on the next invocation, including offline invocations.
ledger_edit "[r.update(created=0,state='active') for r in h['reservations'].values()]"
run_cli capabilities --json
status_is 0 'offline reaper invocation'
run_cli budget --json
jcheck 'expired active reservation released' "$OUT" "assert not d['data']['reservations'] and d['budget_remaining']==300"

# Snapshot recovery preserves spend and enforces the floor after corruption.
fixture scrape
run_cli fetch https://x --json
printf 'garbage\n' >"$LEDGER"
run_cli fetch https://x --json
status_is 0 'corrupt ledger recovers'
contains "$ERR" 'last known good sub-budget' 'corruption warning'
jcheck 'snapshot retains previous charge' "$OUT" "assert d['budget_remaining']==298"
printf '{"version":1,"hosts":null}\n' >"$LEDGER"
run_cli budget --json
status_is 0 'invalid schema recovers'
jcheck 'invalid schema retains charge' "$OUT" "assert d['data']['session']['spent']==2"
# Simulate a crash after snapshot rename but before the primary rename.
python3 - "$LEDGER" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]).with_name('snapshot.json')
d = json.loads(p.read_text())
d['revision'] += 1
next(iter(d['hosts'].values()))['sessions']['session-full-value-abcdefgh']['spent'] = 299
p.write_text(json.dumps(d))
PY
run_cli search query --json
status_is 3 'newer snapshot charge survives interrupted write'
jcheck 'newer snapshot budget retained' "$(error_json)" "assert d['budget_remaining']==1"
# A session-bucket refusal keeps naming --raise-budget: that remedy does lift it (#2105).
jcheck 'session refusal names --raise-budget' "$(error_json)" "e=d['error']; assert e['message'].startswith('session budget refused') and '--raise-budget' in e['next_action'], e"
RESET_LEDGER=0
configure '{"credit-usage":{"remaining":[200]},"default":{"fixture":"scrape.json"}}'
printf 'garbage\n' >"$LEDGER"
run_cli fetch https://x --json
status_is 3 'vendor floor after recovery'
[[ "$(paid_calls)" == 0 ]] && ok || bad 'floor allowed a paid call'
RESET_LEDGER=1
printf 'garbage\n' >"$LEDGER"
printf 'garbage\n' >"${LEDGER%/*}/snapshot.json"
run_cli budget --json
status_is 0 'both ledger copies recover without latching'
jcheck 'both-copy corruption keeps finite ceiling' "$OUT" "assert 0 < d['budget_remaining'] < 300"
# Issue #2105: an overdrawn account reports a negative balance. That is a real
# reading below any floor: refuse (exit 3) naming the balance, never retry it as
# a transient credit-read failure (exit 2), and never point at --raise-budget.
configure '{"credit-usage":{"remaining":[-384]},"default":{"fixture":"scrape.json"}}'
run_cli fetch https://x --json
status_is 3 'overdrawn account is a budget refusal'
[[ "$(paid_calls)" == 0 ]] && ok || bad 'overdrawn account allowed a paid call'
all_argv_is 'overdrawn balance is read once, not retried' "assert d==[['credit-usage','--json']], d"
jcheck 'overdrawn refusal names the balance and the account remedy' "$(error_json)" "e=d['error']; assert e['code']==3 and e['retryable'] is False, e; assert 'has -384 credits' in e['message'], e; assert 'top up Firecrawl credits' in e['next_action'] and '--raise-budget' not in e['next_action'], e; assert d['credits_remaining']==-384, d"

# Full session values stay distinct even when their last eight characters match.
fixture scrape
run_cli fetch https://x --json
export CLAUDE_CODE_SESSION_ID='different-full-value-abcdefgh'
run_cli fetch https://x --json
run_cli budget --json
jcheck 'second full identity' "$OUT" "assert d['data']['session']['spent']==1 and d['data']['day_state']['spent']==2"
ledger_edit "assert len(h['sessions'])==2; assert all(s['spent']==1 for s in h['sessions'].values())"
[[ $? == 0 ]] && ok || bad 'full session identity collision'
unset CLAUDE_CODE_SESSION_ID
run_cli fetch https://x --json
run_cli budget --json
jcheck 'unattended day-only identity' "$OUT" "assert d['data']['session'] is None and d['data']['day_state']['spent']==3"
ledger_edit "assert len(h['sessions'])==2; assert all(s['spent']==1 for s in h['sessions'].values())"
[[ $? == 0 ]] && ok || bad 'unattended call charged a session'
export CLAUDE_CODE_SESSION_ID='session-full-value-abcdefgh'
ledger_edit "h['days']={'1999-01-01':day}"
run_cli fetch https://x --json
run_cli budget --json
jcheck 'session spend carries over midnight' "$OUT" "assert d['data']['session']['spent']==2 and d['data']['day_state']['spent']==1 and d['budget_remaining']==298"
run_cli budget --raise-budget 50 --reason 'session spans midnight' --json
ledger_edit "h['days']['2000-01-01']=h['days'].pop(max(h['days']))"
run_cli budget --json
jcheck 'session raises carry with spend' "$OUT" "assert d['budget_remaining']==348 and d['data']['day_state']['raises']==[]"

# Transient credit reads warn and retry; every retry failing exits 2 pre-call.
configure '{"credit-usage":{"failures":1,"fixture":"credit-usage.json"},"default":{"fixture":"scrape.json"}}'
run_cli fetch https://x --json
status_is 0 'credit read recovers on retry'
contains "$ERR" 'retrying' 'credit retry warning'
jcheck 'transient credit read degraded' "$OUT" "assert any('transiently' in n for n in d['degraded']); assert d['credits_spent']==1"
configure '{"credit-usage":{"failures":3},"default":{"fixture":"scrape.json"}}'
run_cli fetch https://x --json
status_is 2 'all three credit retries fail'
contains "$ERR" 'three retry attempts' 'retry exhaustion named'
[[ "$(paid_calls)" == 0 && "$(wc -l <"$FIRECRAWL_TEST_LOG")" -eq 3 ]] && ok || bad 'retry count or paid call on failure'
configure '{"credit-usage":{"failed_reads":[2,3,4],"fixture":"credit-usage.json"},"default":{"fixture":"scrape.json"}}'
run_cli fetch https://x --json
status_is 0 'post-call retry failure keeps successful charge'
jcheck 'post-call failure accounting' "$OUT" "assert d['credits_spent']==1 and d['budget_remaining']==299; assert any('post-call' in n for n in d['degraded'])"
run_cli budget --json
jcheck 'post-call failure durable charge' "$OUT" "assert d['data']['session']['spent']==1 and not d['data']['reservations']"
configure '{"credit-usage":{"remaining":[10000,9997]},"default":{"fixture":"scrape.json"}}'
run_cli fetch https://x --json
jcheck 'synchronous observed delta' "$OUT" "assert d['credits_spent']==3 and d['credits_remaining']==9997 and d['budget_remaining']==297"
configure '{"credit-usage":{"remaining":[10000,9000]},"default":{"fixture":"plain-success.json"}}'
run_cli raw --json -- crawl https://x --json
jcheck 'lag-billed raw skips downward reconciliation' "$OUT" "assert d['credits_spent']==100"
[[ "$(wc -l <"$FIRECRAWL_TEST_LOG")" -eq 2 ]] && ok || bad 'lag-billed raw made a post-call credit read'

# Cost classes, conservative raw override, and bounded raises are introspectable.
export FIRECRAWL_CLI_BOUNDED_CRAWL=120
fixture plain-success
run_cli raw --json -- unknown --json
jcheck 'raw class override' "$OUT" "assert d['credits_spent']==120 and d['budget_remaining']==180"
unset FIRECRAWL_CLI_BOUNDED_CRAWL
fixture search
run_cli search query --limit 11 --json
jcheck 'search per ten rounds upward' "$OUT" "assert d['credits_spent']==4"
fixture scrape-json
run_cli extract https://x -Q fields --json
jcheck 'JSON extraction rate' "$OUT" "assert d['credits_spent']==5"
fixture parse
run_cli fetch report.pdf --json
jcheck 'parse reservation rate' "$OUT" "assert d['credits_spent']==25"
fixture interact
run_cli interact prompt --scrape-id X --timeout 60 --json
jcheck 'interact one minute minimum' "$OUT" "assert d['credits_spent']==7"

# U4/KTD6: every lane needs an explicit ID; fetch exports and records it.
for lane in claude unattended; do
  if [[ "$lane" == claude ]]; then export CLAUDE_CODE_SESSION_ID=u4; else unset CLAUDE_CODE_SESSION_ID; fi
  fixture interact
  run_cli interact 'click the tab' --json
  status_is 4 "AE9 missing id ($lane)"
  contains "$ERR" 'run a fetch first' 'AE9 fetch remedy'
  contains "$ERR" '--scrape-id <id>' 'AE9 explicit id remedy'
  no_calls 'AE9 never uses vendor last scrape'
  configure '{"scrape":{"fixture":"scrape-session.json"},"interact":{"fixture":"interact.json"}}'
  run_cli fetch https://x --json
  status_is 0 'fetch session id'
  jcheck 'fetch exposes id and preserves data' "$OUT" "assert d['scrape_id']=='scrape-1'; assert d['data']['data']['metadata']['scrapeId']=='scrape-1'"
  run_cli interact 'click the tab' --scrape-id scrape-1 --json
  status_is 0 "explicit interact ($lane)"
  jcheck 'default prompt minimum minute' "$OUT" "assert d['credits_spent']==7"
  python3 - "$FIRECRAWL_TEST_LOG" <<'PYTEST'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
call = next(c for c in calls if c[0]=='interact')
assert call[call.index('-s')+1]=='scrape-1' and '-c' not in call
PYTEST
  [[ $? == 0 ]] && ok || bad 'explicit vendor scrape id'
  run_cli budget --json
  jcheck 'recorded scrape usage' "$OUT" "b=d['data']['session'] or d['data']['day_state']; assert b['scrapes']['scrape-1']>0; assert b['interacted']['scrape-1']"
done

# KTD6/KTD7: each code flag needs fresh consent and a nonblank reason.
export CLAUDE_CODE_SESSION_ID=u4
for mode in shaped raw; do
  for gate in absent allow-only reason-only blank granted; do
    fixture interact
    keys=()
    case "$gate" in
      allow-only) keys=(--allow-code-exec) ;;
      reason-only) keys=(--reason 'inspect title') ;;
      blank) keys=(--allow-code-exec --reason '   ') ;;
      granted) keys=(--allow-code-exec --reason 'inspect title') ;;
    esac
    if [[ "$mode" == shaped ]]; then
      run_cli interact --code 'print(1)' --python --scrape-id X "${keys[@]}" --json
    else
      run_cli raw --json -- interact -c 'print(1)' --python -s X "${keys[@]}" --json
    fi
    if [[ "$gate" == granted ]]; then
      status_is 0 "$mode granted code"
      argv_is 'code argv without wrapper consent flags' "assert '-c' in d and '--python' in d; assert '--allow-code-exec' not in d and '--reason' not in d"
      if [[ "$mode" == shaped ]]; then
        jcheck 'code-only minimum minute' "$OUT" "assert d['credits_spent']==2"
      fi
      granted=True
    else
      status_is 5 "AE4 $mode $gate code refusal"
      contains "$ERR" '--allow-code-exec' 'code refusal opt-in'
      contains "$ERR" '--reason' 'code refusal reason'
      contains "$ERR" 'Describe the page' 'code refusal prompt recipe'
      no_calls 'code refusal before all vendor calls'
      granted=False
    fi
    run_cli budget --json
    jcheck 'code attempt tag' "$OUT" "t=d['data']['tags']; assert len(t)==1; assert t[0]['kind']=='code-mode' and t[0]['granted']==$granted and t[0]['scrape_id']=='X' and t[0]['at']>0"
    if [[ "$gate" == granted ]]; then
      jcheck 'recorded reason' "$OUT" "assert d['data']['tags'][0]['reason']=='inspect title'"
      if [[ "$mode" == shaped ]]; then
        run_cli interact --code 'print(2)' --scrape-id X --json
      else
        run_cli raw --json -- interact -c 'print(2)' -s X --json
      fi
      status_is 5 'consent never persists'
      run_cli budget --json
      jcheck 'refusal follows prior grant' "$OUT" "assert [t['granted'] for t in d['data']['tags']]==[True,False]"
    fi
  done
done
for flag in -c --code --node --python --bash --code=snippet -csnippet; do
  fixture interact
  run_cli raw --json -- interact "$flag" -s X
  status_is 5 "raw code flag $flag"
  no_calls 'raw code flag refused'
done
fixture interact
run_cli raw --json -- interact prompt
status_is 4 'raw prompt also needs explicit id'
no_calls 'raw never uses global last scrape'
run_cli interact stop --json
status_is 4 'stop requires explicit id'
no_calls 'stop never uses global last scrape'
run_cli interact --help
contains "$OUT" '10 minutes' 'interact TTL help'
contains "$OUT" '5 idle' 'interact idle TTL help'

# Vendor global options before interact must not hide its code flags.
fixture interact
run_cli raw --json -- -o vendor-result.json interact -c snippet -s X --json
status_is 5 'raw code behind global output flag refused'
no_calls 'raw global option cannot bypass consent'
run_cli budget --json
jcheck 'raw global option refusal tagged' "$OUT" "assert len(d['data']['tags'])==1 and not d['data']['tags'][0]['granted']"
fixture interact
run_cli raw --json -- -o vendor-result.json interact -c snippet -s X --allow-code-exec --reason 'explicit raw output' --json
status_is 0 'raw code behind global output flag granted'
argv_is 'raw global option preserved' "assert d==['-o','vendor-result.json','interact','-c','snippet','-s','X','--json']"

# Reservations themselves must fit the per-minute ceiling before execution.
for runtime in --node --python --bash; do
  fixture interact
  export FIRECRAWL_CLI_SESSION_BUDGET=2
  run_cli interact --code 'snippet' "$runtime" --scrape-id X --allow-code-exec --reason 'bounded code' --timeout 5 --json
  status_is 0 'code reservation fits two credits'
  argv_is 'runtime passthrough' "assert '$runtime' in d and '-c' in d"
  jcheck 'code exhausts exact reservation' "$OUT" "assert d['budget_remaining']==0 and d['credits_spent']==2"
done
export FIRECRAWL_CLI_SESSION_BUDGET=7
fixture interact
run_cli interact prompt --scrape-id X --timeout 5 --json
status_is 0 'prompt reservation fits seven credits'
jcheck 'prompt exhausts exact reservation' "$OUT" "assert d['budget_remaining']==0 and d['credits_spent']==7"
unset FIRECRAWL_CLI_SESSION_BUDGET
fixture interact
run_cli interact prompt --code snippet --scrape-id X --allow-code-exec --reason 'combined mode' --timeout 61 --json
status_is 0 'combined prompt and code'
jcheck 'combined mode uses rounded prompt rate' "$OUT" "assert d['credits_spent']==14"
for timeout in 0.5 301; do
  fixture interact
  run_cli interact prompt --scrape-id X --timeout "$timeout" --json
  status_is 4 'interact timeout bounds'
  no_calls 'invalid timeout never reaches vendor'
done
unset CLAUDE_CODE_SESSION_ID
fixture interact
run_cli raw --json --allow-code-exec --reason 'unattended explicit consent' -- interact --code=snippet --scrape-id=X --json
status_is 0 'raw wrapper-position consent without session'
argv_is 'raw equals flags preserved' "assert d==['interact','--code=snippet','--scrape-id=X','--json']"
run_cli budget --json
jcheck 'unattended code audit tag' "$OUT" "assert d['data']['session'] is None; assert d['data']['tags'][0]['granted']; assert d['data']['tags'][0]['reason']=='unattended explicit consent'"
run_cli raw --json -- interact --code=snippet --scrape-id=X
status_is 5 'unattended refusal after grant'
run_cli budget --json
jcheck 'unattended grant never persists' "$OUT" "assert [t['granted'] for t in d['data']['tags']]==[True,False]"
export CLAUDE_CODE_SESSION_ID=u4

# Expiry is advisory; a fresh call updates the persisted per-id clock.
configure '{"scrape":{"fixture":"scrape-session.json"},"interact":{"fixture":"interact.json"}}'
run_cli fetch https://x --json
ledger_edit "h['sessions']['u4']['scrapes']['scrape-1']-=601"
run_cli interact prompt --scrape-id scrape-1 --json
status_is 0 'expired session still reaches vendor'
jcheck 'ten-minute expiry' "$OUT" "assert 'interact session likely expired' in d['degraded']"
ledger_edit "h['sessions']['u4']['scrapes']['scrape-1']-=301"
run_cli interact prompt --scrape-id scrape-1 --json
jcheck 'five-minute idle expiry' "$OUT" "assert 'interact session likely expired' in d['degraded']"
run_cli interact prompt --scrape-id scrape-1 --json
jcheck 'fresh session clears expiry' "$OUT" "assert 'interact session likely expired' not in (d['degraded'] or [])"

fixture agent
run_cli agent 'extract prices' --wait --max-credits 30 --model spark-1-mini --json
status_is 0 'agent bounded wait'
argv_is 'agent lifecycle argv' "assert d==['agent','extract prices','--max-credits','30','--model','spark-1-mini','--wait','--json']"
for flag in --status --cancel; do
  fixture agent
  run_cli agent "$flag" agent-job --json
  status_is 0 "agent $flag job-id"
  argv_is 'agent lifecycle job id' "assert d==['agent','agent-job','$flag','--json']"
done
fixture agent-capped
run_cli agent 'extract prices' --wait --max-credits 10 --json
status_is 0 'capped job payload retained'
jcheck 'failed capped job reports zero cost' "$OUT" "assert d['data']['status']=='failed' and d['credits_spent']==0 and d['budget_remaining']==300"
run_cli agent --help
contains "$OUT" '2,500' 'agent vendor default cap'
contains "$OUT" 'fetch --schema' 'cheaper deterministic recipe first'

# Synthetic runaway at 300 credits; daily raises can add only 100 in this test.
unset CLAUDE_CODE_SESSION_ID
export FIRECRAWL_CLI_DAY_CEILING=300 FIRECRAWL_CLI_DAILY_RAISE_BOUND=100
fixture plain-success
for ((attempt=0; attempt<4; attempt++)); do
  run_cli raw --json -- future-expensive-verb --json
  [[ "$ST" == 3 ]] && break
  status_is 0 'runaway admitted reservation'
done
status_is 3 'runaway stops at ceiling'
[[ "$attempt" == 3 && "$(paid_calls)" == 3 ]] && ok || bad 'runaway exceeded configured ceiling'
for ((attempt=0; attempt<3; attempt++)); do
  run_cli budget --raise-budget 50 --reason 'bounded runaway test' --json
  [[ "$ST" == 3 ]] && break
  status_is 0 'bounded raise admitted'
done
status_is 3 'runaway self-raise bound'
[[ "$attempt" == 2 ]] && ok || bad 'daily cumulative raises exceeded bound'
run_cli raw --json -- future-expensive-verb --json
status_is 0 'raised capacity admits one additional reservation'
run_cli raw --json -- future-expensive-verb --json
status_is 3 'raised runaway stops again'
run_cli budget --json
jcheck 'runaway final ledger' "$OUT" "assert d['budget_remaining']==0 and sum(r['amount'] for r in d['data']['raises'])==100; assert sum(r['amount'] for r in d['data']['reservations'].values())==400"
unset FIRECRAWL_CLI_DAY_CEILING FIRECRAWL_CLI_DAILY_RAISE_BOUND

# Validate the complete seven-code dictionary independently of future mappings.
if [[ -f "$MODULE" ]]; then
  RESULT=$(PYTHONDONTWRITEBYTECODE=1 python3 - "$MODULE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('firecrawl_cli', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert set(module.EXIT_CODES) == set(range(7))
assert {k for k,v in module.EXIT_CODES.items() if v['retryable']} == {2}
print('OK')
PY
)
  [[ "$RESULT" == OK ]] && ok || bad 'exit dictionary'
else
  bad 'module does not exist yet'
fi

# Review 2026-09-13: raw gates are position-independent. A value flag or a stray
# "--" ahead of the subcommand must never hide an account command or interact.
fixture scrape
run_cli raw --json -- --timeout 5 login
status_is 4 'raw denylist: value flag before login'
no_calls 'raw denylist: value flag before login'
contains "$(cat "$TMP/err")" 'account administration' 'raw denylist names the refusal'
run_cli raw --json -- --actions '[]' interact -c 'print(1)' -s X
status_is 5 'raw code gate: --actions before interact'
no_calls 'raw code gate: --actions before interact'
run_cli raw --json -- -- interact -c 'print(1)' -s X
status_is 5 'raw code gate: redundant -- before interact'
no_calls 'raw code gate: redundant -- before interact'
run_cli raw --json -- interact -s X -- -c 'print(1)'
status_is 5 'raw code gate: code flag after a second --'
no_calls 'raw code gate: code flag after a second --'
run_cli raw --json -- search --token abc
status_is 4 'raw denylist: --token'
no_calls 'raw denylist: --token'

# stop never demands code consent; a runtime flag on stop is a usage error.
run_cli interact stop --node --scrape-id abc --json
status_is 4 'stop with a runtime flag is usage, not consent'
contains "$(cat "$TMP/err")" 'does not accept code' 'stop rejects runtime flags'
run_cli interact stop --scrape-id abc --json
status_is 0 'bare stop still works'
jcheck 'stop reserves nothing' "$OUT" "assert d['credits_spent']==0"

# --json puts the envelope on stdout for local errors and the generic error path.
run_cli extract https://x --json
status_is 4 'local usage error'
jcheck 'local error envelope on stdout' "$OUT" "assert d['error']['code']==4 and d['error']['retryable'] is False and d['error']['http_status'] is None"
contains "$ERR" 'next: ' 'local error human line on stderr'
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_CLI_FLOOR=abc "$CLI" budget --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
OUT=$(cat "$TMP/out")
status_is 4 'invalid constant is a usage error'
jcheck 'generic error path carries the full error object' "$OUT" "assert d['error']['code']==4 and d['error']['retryable'] is False and 'http_status' in d['error']"

# agent --status is a free read: polling never re-charges the job.
fixture agent-cost
run_cli agent agent-job --status --json
status_is 0 'agent status poll'
jcheck 'status poll spends nothing' "$OUT" "assert d['credits_spent']==0"
run_cli agent agent-job --status --json
run_cli budget --json
jcheck 'two status polls charge nothing' "$OUT" "assert d['data']['day_state']['spent']==0 and not d['data']['reservations']"

# The vendor's own verb names are accepted as fetch, with a warning.
fixture scrape
run_cli scrape https://x --json
status_is 0 'scrape is fetch here'
contains "$ERR" 'is fetch here' 'scrape redirect warning'
run_cli parse https://x --json
status_is 0 'parse is fetch here'

# capabilities: extension list, cost classes that name real constants, error.code rule.
run_cli capabilities --json
jcheck 'capabilities contract additions' "$OUT" "c=d['data']; assert {'.pdf','.docx','.xlsx'} <= set(c['parse_extensions']); assert c['verbs']['interact']['cost_class']=='interact_per_minute' and c['verbs']['extract']['cost_class']=='json_extraction'; assert 'json_extraction' in c['verbs']['fetch']['cost_classes']; assert all(v['cost_class'] in c['budget'] or v['cost_class'] in {'offline','raw-unknown','scrape','map','search','free'} for v in c['verbs'].values()); assert any('error.code' in w for w in c['warnings'])"
contains "$(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" "$CLI" --help)" 'infers fetch' 'help names the inference'

# A symlinked state directory refuses.
ln -s "$TMP/work" "$TMP/link-state"
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_CLI_STATE_DIR="$TMP/link-state" "$CLI" budget --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
status_is 4 'symlinked state directory refused'
contains "$(cat "$TMP/err")" 'symlink' 'symlink refusal named'

# A ledger.json whose revision lags snapshot.json is resynced by a read-only pass.
fixture scrape
run_cli fetch https://x --json
python3 - "$LEDGER" <<'PY'
import json, pathlib, sys
ledger = pathlib.Path(sys.argv[1]); snapshot = ledger.with_name('snapshot.json')
data = json.loads(snapshot.read_text()); data['revision'] -= 1
ledger.write_text(json.dumps(data))
PY
run_cli budget --json
python3 - "$LEDGER" <<'PY'
import json, pathlib, sys
ledger = pathlib.Path(sys.argv[1]); snapshot = ledger.with_name('snapshot.json')
assert json.loads(ledger.read_text())['revision'] == json.loads(snapshot.read_text())['revision']
PY
[[ $? == 0 ]] && ok || bad 'lagging ledger revision resynced'

# Issue #1175: search filters, search_id, fetch freshness and formats, and the API
# transport for the one category the vendor CLI refuses client-side.
fixture search-id
run_cli search 'example query' --categories research,pdf --sources web,news --tbs qdr:w --limit 3 --json
status_is 0 'search filters accepted'
argv_is 'search filters forwarded' "assert d==['search','example query','--limit','3','--categories','research,pdf','--sources','web,news','--tbs','qdr:w','--json'], d"
jcheck 'search_id and measured cost' "$OUT" "assert d['ok'] and d['search_id']=='srch_fixture_1' and d['credits_spent']==2 and d['degraded'] is None"
fixture search-id
run_cli search 'example query' --location Germany --json
status_is 0 'search location accepted'
argv_is 'location forwarded to the vendor' "assert d[d.index('--location')+1]=='Germany', d"
fixture search
run_cli search 'example query' --json
jcheck 'no search_id without a vendor id' "$OUT" "assert 'search_id' not in d and d['ok']"
for bad in '--categories research,bogus' '--categories research,research' '--sources rss' '--tbs qdr:x' '--tbs yesterday'; do
  fixture search-id
  # shellcheck disable=SC2086
  run_cli search 'example query' $bad --json
  status_is 4 "search filter refused: $bad"
  no_calls "search filter refused before the vendor: $bad"
done
run_cli search 'example query' --categories '' --json
status_is 4 'empty categories refused'
contains "$ERR" 'valid categories: research, pdf, developer, gov' 'category list named'
run_cli search 'example query' --tbs qdr:x --json
contains "$ERR" 'valid values: qdr:h, qdr:d, qdr:w, qdr:m, qdr:y' 'tbs values named'

fixture scrape
run_cli fetch https://x --max-age 0 --format links,markdown --json
status_is 0 'fetch max-age and format accepted'
argv_is 'fetch max-age and format forwarded' "assert d==['scrape','https://x','--only-main-content','--format','links,markdown','--max-age','0','--json'], d"
fixture scrape-json
run_cli extract https://x --schema '{"type":"object"}' --format links --json
status_is 0 'schema with an explicit format list'
argv_is 'json appended once to explicit formats' "assert d.count('--format')==1 and d[d.index('--format')+1]=='links,json', d"
fixture scrape
run_cli fetch https://x --format json --json
status_is 4 'json format without a schema refused'
contains "$ERR" '--format json needs --schema or --schema-file' 'json format refusal named'
no_calls 'json format refused before the vendor'
run_cli fetch https://x --format bogus --json
status_is 4 'unknown format refused'
contains "$ERR" 'scrape formats: markdown, html, rawHtml' 'scrape format list named'
run_cli fetch https://x --format markdown,markdown --json
status_is 4 'duplicate format refused'
run_cli fetch https://x --max-age -1 --json
status_is 4 'negative max-age refused'
printf '<html><body>local</body></html>' >"$TMP/work/page.html"
fixture parse
run_cli fetch "$TMP/work/page.html" --max-age 5 --json
status_is 4 'max-age on a local file refused'
contains "$ERR" 'URL targets only' 'max-age scope named'
no_calls 'max-age refused before the vendor'
run_cli fetch "$TMP/work/page.html" --format changeTracking --json
status_is 4 'scrape-only format refused for a local parse'
contains "$ERR" 'parse formats: markdown, html' 'parse format list named'

run_cli capabilities --json
jcheck 'capabilities search and format contract' "$OUT" "c=d['data']; assert c['search_categories']==['research','pdf','developer','gov'] and c['api_only_categories']==['developer']; assert c['search_sources']==['web','images','news','alexandria'] and c['search_tbs'][0]=='qdr:h'; assert 'site:host' in c['search_operators']; assert 'changeTracking' in c['fetch_formats']['scrape'] and 'changeTracking' not in c['fetch_formats']['parse']; assert {'--categories','--sources','--tbs'} <= set(c['verbs']['search']['flags']); assert {'--max-age','--format'} <= set(c['verbs']['fetch']['flags']); assert any('search_id' in w for w in c['warnings']) and any('--max-age 0' in w for w in c['warnings'])"
contains "$(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" COLUMNS=400 "$CLI" search --help)" 'site:host' 'search help names the operators'
contains "$(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" COLUMNS=400 "$CLI" fetch --help)" '--max-age 0 forces a live fetch' 'fetch help names the max-age rule'

# The developer category is answered by the API directly; a loopback stub stands in.
export FIRECRAWL_API_TEST_CONTROL="$TMP/api-control.json"
export FIRECRAWL_API_TEST_LOG="$TMP/api-calls.jsonl"
python3 "$FIXTURES/fake-api.py" >"$TMP/api.port" 2>"$TMP/api.err" &
API_PID=$!
trap 'kill "$API_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 100); do [[ -s "$TMP/api.port" ]] && break; sleep 0.05; done
API_PORT=$(cat "$TMP/api.port")
# Deliberately not fc- or JWT shaped: the generic redaction patterns must not be
# what keeps this key off the streams; only SECRETS.add(key) can (review 2026-09-13).
# The old spelling held "fc-shaped-99182736", which the fc- pattern matched (#805).
API_KEY='diagnostic-marker-not-key-shaped-99182736'
api_control() { printf '%s\n' "$1" >"$FIRECRAWL_API_TEST_CONTROL"; : >"$FIRECRAWL_API_TEST_LOG"; }
run_api() {
  ST=0
  (cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_API_KEY="$API_KEY" FIRECRAWL_API_URL="http://127.0.0.1:$API_PORT" "$CLI" "$@") >"$TMP/out" 2>"$TMP/err" || ST=$?
  OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
}
api_request() { jcheck "$1" "$(head -n 1 "$FIRECRAWL_API_TEST_LOG")" "$2"; }
vendor_verbs() { python3 -c 'import json,os; print(json.dumps([json.loads(l)[0] for l in open(os.environ["FIRECRAWL_TEST_LOG"])]))'; }
no_api_calls() { [[ ! -s "$FIRECRAWL_API_TEST_LOG" ]] && ok || bad "$1: API invoked"; }

fixture search-dev
api_control "{\"status\":200,\"body\":$(cat "$TMP/fixtures/search-dev.json")}"
run_api search 'example query' --categories developer --limit 2 --json
status_is 0 'developer search answered by the API'
jcheck 'developer envelope' "$OUT" "assert d['ok'] and d['surface']=='search' and d['search_id']=='srch_dev_1' and d['credits_spent']==2 and d['degraded'] is None; assert d['data']['data']['web'][0]['category']=='developer'"
api_request 'developer request shape' "assert d['path']=='/v2/search' and d['body']=={'query':'example query','limit':2,'categories':['developer']}; assert d['authorization']=='Bearer $API_KEY' and d['content_type']=='application/json' and d['user_agent'].startswith('firecrawl-cli/')"
jcheck 'vendor search never invoked for developer' "$(vendor_verbs)" "assert d and 'search' not in d, d"
omits "$OUT$ERR" "$API_KEY" 'key never printed on success'
fixture search-dev
api_control "{\"status\":200,\"body\":$(cat "$TMP/fixtures/search-dev.json")}"
run_api search 'example query' --categories research,developer --sources news --tbs qdr:d
status_is 0 'mixed categories go to the API without --json'
api_request 'mixed request carries every filter' "assert d['body']=={'query':'example query','categories':['research','developer'],'sources':[{'type':'news'}],'tbs':'qdr:d'}"
jcheck 'bare developer output is the vendor payload' "$OUT" "assert d['id']=='srch_dev_1' and 'ok' not in d"
fixture search-dev
api_control "{\"status\":200,\"body\":$(cat "$TMP/fixtures/search-dev.json")}"
run_api search 'example query' --categories research,developer --location Germany --json
status_is 0 'mixed categories with --json'
jcheck 'mixed categories envelope' "$OUT" "assert d['ok'] and d['surface']=='search' and d['search_id']=='srch_dev_1' and d['credits_spent']==2"
api_request 'location reaches the API body' "assert d['body']['location']=='Germany' and d['body']['categories']==['research','developer']"
api_control '{"status":402,"body":{"success":false,"error":"Insufficient credits to perform this request."}}'
run_api search 'example query' --categories developer --json
status_is 1 'API 402 maps to quota'
jcheck 'API 402 envelope' "$OUT" "assert d['error']['code']=='quota_exhausted' and d['error']['http_status']==402 and d['error']['retryable'] is False"
contains "$ERR" 'operator action: top up' 'API quota operator action'
api_control '{"status":401,"body":{"success":false,"error":"Unauthorized: Invalid token"}}'
run_api search 'example query' --categories developer --json
status_is 2 'API 401 maps to auth failure'
jcheck 'API 401 envelope' "$OUT" "assert d['error']['code']=='auth_failure' and d['error']['http_status']==401"
contains "$ERR" 'credential source: env (FIRECRAWL_API_KEY)' 'API 401 names the env source'
omits "$OUT$ERR" "$API_KEY" 'key never printed on failure'
api_control '{"status":429,"headers":{"Retry-After":"12"},"body":{"success":false,"error":"Rate limit exceeded. Consumed (req/min): 61"}}'
run_api search 'example query' --categories developer --json
status_is 2 'API 429 maps to rate limit'
jcheck 'API 429 envelope' "$OUT" "assert d['error']['code']=='rate_limited' and d['error']['retryable']"
contains "$ERR" 'retry after 12s' 'API Retry-After honored'
api_control '{"status":503,"body":{"success":false,"error":"Service Unavailable"}}'
run_api search 'example query' --categories developer --json
status_is 2 'API 503 maps to provider failure'
jcheck 'API 503 envelope' "$OUT" "assert d['error']['code']=='provider_failure'"
api_control '{"status":200,"text":"<html>not json</html>"}'
run_api search 'example query' --categories developer --json
status_is 2 'API non-JSON body maps to vendor output changed'
jcheck 'API malformed envelope' "$OUT" "assert d['error']['code']=='vendor_output_changed'"
api_control '{"status":200,"body":{"success":false,"error":"Bad Request: query too long"}}'
run_api search 'example query' --categories developer --json
status_is 1 'API success:false is a vendor error'
fixture search-dev
api_control '{"status":200,"body":{}}'
run_cli search 'example query' --categories developer --json
status_is 4 'developer without a key refused'
contains "$ERR" 'needs FIRECRAWL_API_KEY in the environment' 'missing key named'
contains "$ERR" 'firecrawl-cli developer' 'missing key alternative named'
no_calls 'missing key refused before the vendor'
no_api_calls 'missing key refused before the API'
fixture search-dev
api_control '{"status":200,"body":{}}'
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_API_KEY="$API_KEY" FIRECRAWL_API_URL="http://api.example.test" "$CLI" search 'example query' --categories developer --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
status_is 4 'plain http to a non-loopback base refused'
contains "$(cat "$TMP/err")" 'must be an https URL, or http to a loopback host' 'base refusal named'
no_api_calls 'bad base refused before the API'
no_calls 'bad base refused before the vendor'
fixture search-id
api_control '{"status":200,"body":{}}'
run_api search 'example query' --categories research --json
status_is 0 'research category stays on the vendor CLI'
argv_is 'research category forwarded to the vendor' "assert d[:2]==['search','example query'] and d[d.index('--categories')+1]=='research'"
no_api_calls 'vendor category never hits the API'
# A 3xx is a failure, never a hop: the key must not travel to a Location host.
fixture search-dev
api_control '{"status":302,"headers":{"Location":"http://127.0.0.1:1/elsewhere"},"body":{}}'
run_api search 'example query' --categories developer --json
status_is 1 'API redirect refused'
contains "$ERR" 'answered with a redirect' 'redirect refusal named'
jcheck 'redirect never followed' "$(python3 -c 'import os; print(sum(1 for _ in open(os.environ["FIRECRAWL_API_TEST_LOG"])))')" "assert d==1, d"
omits "$OUT$ERR" "$API_KEY" 'key never printed on redirect'
api_control '{"status":200,"truncate":true,"body":{"success":true,"data":{"web":[]}}}'
run_api search 'example query' --categories developer --json
status_is 2 'truncated API body is a transient failure'
contains "$ERR" 'could not reach the Firecrawl API' 'truncated body named'
omits "$ERR" 'Traceback' 'truncated body raises no traceback'
api_control '{"status":200,"body":{}}'
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_API_KEY="$API_KEY" FIRECRAWL_API_URL="http://127.0.0.1:1" "$CLI" search 'example query' --categories developer --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
status_is 2 'unreachable API port is a transient failure'
contains "$ERR" 'could not reach the Firecrawl API' 'unreachable API named'
jcheck 'unreachable API envelope' "$OUT" "assert d['error']['retryable'] and d['error']['code']==2"
# The developer category needs no vendor binary; the local caps still apply.
fixture search-dev
api_control "{\"status\":200,\"body\":$(cat "$TMP/fixtures/search-dev.json")}"
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/no-vendor" FIRECRAWL_API_KEY="$API_KEY" FIRECRAWL_API_URL="http://127.0.0.1:$API_PORT" "$CLI" search 'example query' --categories developer --limit 2 --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
status_is 0 'developer search runs without the vendor binary'
jcheck 'no-vendor developer envelope' "$OUT" "assert d['ok'] and d['search_id']=='srch_dev_1' and d['credits_spent']==2 and d['credits_remaining'] is None; assert any('credit floor unchecked' in n for n in d['degraded'])"
no_calls 'no vendor invoked without a binary'
api_control '{"status":200,"sleep":3,"body":{}}'
run_api search 'example query' --categories developer --timeout 1 --json
status_is 1 'API timeout is a wrapper timeout'
contains "$ERR" 'wrapper request timeout' 'API timeout named'

# API-direct verbs. gov is free and keyless; developer is keyless
# and ledger-free, or 2 credits per 10 results with a key. Both need no vendor binary.
run_keyless() {
  ST=0
  (cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_API_URL="http://127.0.0.1:$API_PORT" "$CLI" "$@") >"$TMP/out" 2>"$TMP/err" || ST=$?
  OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
}
run_keyless_no_vendor() {
  ST=0
  (cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/no-vendor" FIRECRAWL_API_URL="http://127.0.0.1:$API_PORT" "$CLI" "$@") >"$TMP/out" 2>"$TMP/err" || ST=$?
  OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
}
api_requests() { python3 -c 'import os; print(sum(1 for _ in open(os.environ["FIRECRAWL_API_TEST_LOG"])))'; }
# The ledger baseline (the suite runs in unattended-day mode, so this is the day bucket);
# free calls leave it untouched and keyed developer calls draw their estimate from it.
configure '{}'
run_cli budget --json
BASE=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["budget_remaining"]))')
gov_body() { cat "$TMP/fixtures/gov.json"; }
dev_body() { cat "$TMP/fixtures/developer.json"; }

configure '{}'
api_control "{\"status\":200,\"body\":$(gov_body)}"
run_keyless gov 'California data breach notification statute' --jurisdiction US-CA --limit 2 --json
status_is 0 'gov answered keyless'
jcheck 'gov envelope' "$OUT" "assert d['ok'] and d['surface']=='gov' and d['verb']=='gov' and d['credits_spent']==0 and d['credits_remaining'] is None and d['budget_remaining']==$BASE and d['degraded'] is None and 'search_id' not in d; web=d['data']['data']['web']; assert len(web)==2 and web[0]['url'].startswith('https://leginfo') and web[0]['position']==1"
# Planted negative (#2070): a body carrying limit instead of k is the live 400 "Unrecognized key: limit".
api_request 'gov request shape' "assert d['path']=='/v2/search/gov' and d['body']=={'query':'California data breach notification statute','k':2,'jurisdiction':'us-ca'} and 'limit' not in d['body']; assert d['authorization'] is None and d['content_type']=='application/json' and d['user_agent'].startswith('firecrawl-cli/')"
no_calls 'gov never reads credit-usage'
omits "$ERR" 'hint: empty' 'gov hits are not empty'
# Keyed: the Bearer rides along for rate limits; the call stays free and ledger-free.
configure '{}'
api_control "{\"status\":200,\"body\":$(gov_body)}"
run_api gov 'qualified immunity excessive force' --court ca9 --court-type federal-appellate --cites '42 U.S.C. § 1983' --domain irs.gov --limit 100 --json
status_is 0 'gov keyed'
jcheck 'gov keyed stays free' "$OUT" "assert d['ok'] and d['credits_spent']==0 and d['budget_remaining']==$BASE and d['degraded'] is None"
api_request 'gov filters reach the body under API names' "assert d['authorization']=='Bearer $API_KEY'; assert d['body']=={'query':'qualified immunity excessive force','k':100,'court':'ca9','courtType':'federal-appellate','cites':'42 U.S.C. § 1983','domain':'irs.gov'}"
no_calls 'gov keyed never reads credit-usage'
omits "$OUT$ERR" "$API_KEY" 'gov key never printed'
# Bare output is the API payload; the vendor binary is not needed.
configure '{}'
api_control "{\"status\":200,\"body\":$(gov_body)}"
run_keyless_no_vendor gov 'allergen labeling' --jurisdiction us
status_is 0 'gov runs without the vendor binary and without --json'
jcheck 'gov bare output is the API payload' "$OUT" "assert 'ok' not in d and d['success'] is True and d['data']['web'][1]['position']==2"
api_request 'gov federal jurisdiction' "assert d['body']=={'query':'allergen labeling','jurisdiction':'us'}"
no_calls 'gov no-vendor never touches the vendor'
# Client-side validation exits 4 before any network or ledger contact.
gov_refused() {
  local label=$1; shift
  configure '{}'
  api_control '{"status":200,"body":{}}'
  run_keyless gov 'q' "$@" --json
  status_is 4 "gov refused: $label"
  no_api_calls "gov refused before the API: $label"
  no_calls "gov refused before the vendor: $label"
}
gov_refused 'court type' --court-type bogus
contains "$ERR" 'valid court types: federal-supreme' 'gov court types listed'
gov_refused 'jurisdiction shape' --jurisdiction ca
contains "$ERR" 'us- plus a two-letter' 'gov jurisdiction rule named'
gov_refused 'jurisdiction three letters' --jurisdiction us-cal
gov_refused 'limit 0' --limit 0
gov_refused 'limit 101' --limit 101
gov_refused 'blank court' --court ' '
gov_refused 'blank cites' --cites ''
gov_refused 'blank domain' --domain ''
configure '{}'
api_control '{"status":200,"body":{}}'
run_keyless gov '' --json
status_is 4 'gov empty query refused'
contains "$ERR" 'query must not be empty' 'gov empty query named'
no_api_calls 'gov empty query refused before the API'
# Free text the API validates: its 400 text is the error message, and the fix is a flag.
configure '{}'
api_control "{\"status\":400,\"body\":{\"success\":false,\"error\":\"invalid 'court' parameter: pass a CourtListener court id such as scotus, ca9, nh or calctapp\"}}"
run_keyless gov 'qualified immunity' --court bogus --json
status_is 1 'gov API 400 is a vendor error'
jcheck 'gov API 400 envelope' "$OUT" "e=d['error']; assert e['code']==1 and e['http_status']==400 and e['retryable'] is False; assert \"invalid 'court' parameter: pass a CourtListener court id\" in e['message']; assert 'firecrawl-cli gov --help' in e['next_action']; assert d['credits_spent']==0"
api_request 'gov bad court id reaches the API' "assert d['body']['court']=='bogus'"
configure '{}'
api_control '{"status":429,"headers":{"Retry-After":"7"},"body":{"success":false,"error":"Rate limit exceeded"}}'
run_keyless gov 'q' --json
status_is 2 'gov API 429 is retryable'
jcheck 'gov 429 envelope' "$OUT" "assert d['error']['code']=='rate_limited' and d['error']['retryable'] and d['credits_spent']==0"
contains "$ERR" 'retry after 7s' 'gov Retry-After honored'
api_control '{"status":503,"body":{"success":false,"error":"Service Unavailable"}}'
run_keyless gov 'q' --json
status_is 2 'gov API 503 is retryable'
jcheck 'gov 503 envelope' "$OUT" "assert d['error']['code']=='provider_failure'"
api_control '{"status":200,"body":{"success":true,"data":{"web":[]}}}'
run_keyless gov 'nothing here' --json
status_is 0 'gov empty result'
contains "$ERR" 'hint: empty result' 'gov empty hint'
api_control '{"status":302,"headers":{"Location":"http://127.0.0.1:1/elsewhere"},"body":{}}'
run_keyless gov 'q' --json
status_is 1 'gov redirect refused'
jcheck 'gov redirect never followed' "$(api_requests)" "assert d==1, d"
configure '{}'
api_control '{"status":200,"body":{}}'
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_API_URL="http://api.example.test" "$CLI" gov 'q' --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
status_is 4 'gov plain http to a non-loopback base refused'
no_api_calls 'gov bad base refused before the API'
# Statute excerpts are long; the body bound and --full behave as for every verb.
configure '{}'
api_control "$(python3 -c 'import json; print(json.dumps({"status":200,"body":{"success":True,"data":{"web":[{"url":"https://law.example/x","title":"t","description":"x"*30000,"position":1}]}}}))')"
run_keyless gov 'long statute' --json
status_is 0 'gov long excerpt bounded'
jcheck 'gov body bound' "$OUT" "assert len(d['data']['data']['web'][0]['description'])==24576; assert 'body truncated at 24576 chars; --full lifts the bound' in d['degraded']; assert any(n.startswith('next: firecrawl-cli gov') and n.endswith('--full') for n in d['degraded'])"
run_keyless gov 'long statute' --full --json
status_is 0 'gov --full lifts the bound'
jcheck 'gov full body' "$OUT" "assert len(d['data']['data']['web'][0]['description'])==30000 and d['degraded'] is None"
api_request 'gov --full never reaches the body' "assert d['body']=={'query':'long statute'}"

configure '{}'
api_control "{\"status\":200,\"body\":$(dev_body)}"
run_keyless developer 'tokio select cancellation safety' --types issue,doc --passages 1 --limit 2 --json
status_is 0 'developer answered keyless'
# Planted negative (#2070): a keyless developer call that reads credit-usage or
# reserves credits fails here (no_calls, credits_spent 0, budget untouched).
jcheck 'developer keyless envelope' "$OUT" "assert d['ok'] and d['surface']=='developer' and d['verb']=='developer' and d['credits_spent']==0 and d['credits_remaining'] is None and d['budget_remaining']==$BASE; assert d['degraded']==[\"keyless developer search: account floor unchecked; Firecrawl's keyless allowance applies\"]; r=d['data']['results']; assert r[0]['id']=='issue:tokio-rs/tokio#8175' and r[1]['id'].startswith('doc:') and 'title' not in r[1]; assert d['data']['coverage']['pull_request']=='skipped' and d['data']['partial'] is False"
api_request 'developer request shape' "assert d['path']=='/v2/search/developer' and d['body']=={'query':'tokio select cancellation safety','k':2,'types':['issue','doc'],'passages':1} and 'limit' not in d['body']; assert d['authorization'] is None"
no_calls 'keyless developer never reads credit-usage'
configure '{}'
api_control "{\"status\":200,\"body\":$(dev_body)}"
run_api developer 'tokio select cancellation safety' --limit 11 --json
status_is 0 'developer keyed'
jcheck 'developer keyed envelope' "$OUT" "assert d['ok'] and d['credits_spent']==4 and d['credits_remaining']==2856 and d['budget_remaining']==$BASE-4; assert 'cost estimated, not measured' in d['degraded'] and not any('keyless' in n for n in d['degraded'])"
api_request 'developer keyed sends the Bearer' "assert d['authorization']=='Bearer $API_KEY' and d['body']=={'query':'tokio select cancellation safety','k':11}"
all_argv_is 'developer keyed reads credit-usage before and after' "assert d==[['credit-usage','--json'],['credit-usage','--json']], d"
omits "$OUT$ERR" "$API_KEY" 'developer key never printed'
configure '{}'
api_control "{\"status\":200,\"body\":$(dev_body)}"
run_api developer 'axum middleware ordering' --limit 2 --json
status_is 0 'developer keyed limit 2'
jcheck 'developer keyed reserves 2 per 10 rounded up' "$OUT" "assert d['credits_spent']==2 and d['budget_remaining']==$BASE-2"
# Issue #2105: keyed developer on an overdrawn account is refused before the API,
# and the refusal names the keyless rerun, which the account balance cannot block.
configure '{"credit-usage":{"remaining":[-384]}}'
api_control "{\"status\":200,\"body\":$(dev_body)}"
run_api developer 'axum middleware ordering' --limit 2 --json
status_is 3 'developer keyed on an overdrawn account is refused'
no_api_calls 'overdrawn developer never reaches the API'
jcheck 'overdrawn developer names the keyless rerun' "$(error_json)" "e=d['error']; assert 'has -384 credits' in e['message'], e; assert \"env -u FIRECRAWL_API_KEY firecrawl-cli developer 'axum middleware ordering'\" in e['next_action'], e; assert 'top up Firecrawl credits' in e['next_action'], e"
configure '{}'
api_control "{\"status\":200,\"body\":$(dev_body)}"
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/no-vendor" FIRECRAWL_API_KEY="$API_KEY" FIRECRAWL_API_URL="http://127.0.0.1:$API_PORT" "$CLI" developer 'q' --limit 2 --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
status_is 0 'developer keyed without the vendor binary'
jcheck 'developer keyed no-vendor envelope' "$OUT" "assert d['ok'] and d['credits_spent']==2 and d['credits_remaining'] is None; assert any('credit floor unchecked: vendor firecrawl absent' in n for n in d['degraded'])"
no_calls 'no vendor invoked without a binary (developer)'
configure '{}'
api_control "{\"status\":200,\"body\":$(dev_body)}"
run_keyless_no_vendor developer 'q' --limit 2
status_is 0 'developer keyless without the vendor binary'
jcheck 'developer keyless no-vendor is wrapped by its degraded note' "$OUT" "assert d['ok'] and d['credits_spent']==0 and d['degraded']==[\"keyless developer search: account floor unchecked; Firecrawl's keyless allowance applies\"]"
configure '{}'
api_control "{\"status\":200,\"body\":$(dev_body)}"
run_keyless developer 'who else hit this' --repos tokio-rs/tokio,rust-lang/rust --sources a,b --skills-only --passages 5 --language Rust --topic async --license MIT --min-stars 100 --max-stars 5000 --archived FALSE --fork true --json
status_is 0 'developer every filter accepted'
api_request 'developer filters reach the body under API names' "assert d['body']=={'query':'who else hit this','repos':['tokio-rs/tokio','rust-lang/rust'],'sources':['a','b'],'skills':'only','passages':5,'language':'Rust','topic':'async','license':'MIT','min_stars':100,'max_stars':5000,'archived':False,'fork':True}"
dev_refused() {
  local label=$1; shift
  configure '{}'
  api_control '{"status":200,"body":{}}'
  run_keyless developer 'q' "$@" --json
  status_is 4 "developer refused: $label"
  no_api_calls "developer refused before the API: $label"
  no_calls "developer refused before the vendor: $label"
}
dev_refused 'types' --types bogus
contains "$ERR" 'valid types: doc, issue, pull_request, readme' 'developer types listed'
dev_refused 'duplicate types' --types issue,issue
dev_refused 'passages 6' --passages 6
dev_refused 'passages 0' --passages 0
dev_refused 'limit 0' --limit 0
dev_refused 'limit 101' --limit 101
dev_refused 'negative stars' --min-stars -1
dev_refused 'stars inverted' --min-stars 10 --max-stars 5
contains "$ERR" '--min-stars exceeds --max-stars' 'developer star order named'
dev_refused 'archived word' --archived maybe
contains "$ERR" 'use true or false' 'developer boolean rule named'
dev_refused 'fork word' --fork yes
dev_refused 'blank repo' --repos 'a/b,'
dev_refused 'too many sources' --sources "$(python3 -c 'print(",".join("s%d" % i for i in range(21)))')"
contains "$ERR" 'at most 20 ids' 'developer sources cap named'
dev_refused 'blank language' --language ''
configure '{}'
api_control '{"status":200,"body":{}}'
run_keyless developer '' --json
status_is 4 'developer empty query refused'
no_api_calls 'developer empty query refused before the API'
configure '{}'
api_control '{"status":400,"body":{"success":false,"code":"BAD_REQUEST","error":"unknown type: bogus (expected doc, issue, pull_request, readme)"}}'
run_keyless developer 'q' --json
status_is 1 'developer API 400 is a vendor error'
jcheck 'developer 400 envelope' "$OUT" "e=d['error']; assert e['code']==1 and e['http_status']==400 and 'unknown type: bogus' in e['message'] and 'firecrawl-cli developer --help' in e['next_action']"
configure '{}'
api_control '{"status":401,"body":{"success":false,"error":"Unauthorized: Invalid token"}}'
run_api developer 'q' --json
status_is 2 'developer keyed 401 is an auth failure'
jcheck 'developer 401 envelope' "$OUT" "assert d['error']['code']=='auth_failure' and d['credits_spent']==0"
contains "$ERR" 'credential source: env (FIRECRAWL_API_KEY)' 'developer 401 names the env source'
omits "$OUT$ERR" "$API_KEY" 'developer key never printed on failure'
configure '{}'
api_control '{"status":200,"body":{"success":true,"partial":true,"results":[],"coverage":{"doc":"unavailable"}}}'
run_keyless developer 'nothing' --json
status_is 0 'developer empty results'
contains "$ERR" 'hint: empty result' 'developer empty hint'
# The developer category keeps its key requirement; the refusal now names the keyless verb.
configure '{}'
api_control '{"status":200,"body":{}}'
run_cli search 'example query' --categories developer --json
status_is 4 'developer category still needs a key'
contains "$ERR" 'next: firecrawl-cli developer' 'developer category refusal names the verb'

run_cli capabilities --json
jcheck 'capabilities API-direct contract' "$OUT" "c=d['data']; assert c['api_direct_verbs']==['gov','developer'] and c['api_direct_paths']=={'gov':'/v2/search/gov','developer':'/v2/search/developer'}; assert c['gov_filters']['--court-type']=='courtType' and c['gov_filters']['--limit']=='k' and len(c['gov_court_types'])==11; assert c['developer_filters']['--min-stars']=='min_stars' and c['developer_filters']['--skills-only']=='skills' and c['developer_types']==['doc','issue','pull_request','readme']; assert c['verbs']['gov']['cost_class']=='free' and c['verbs']['developer']['cost_class']=='search'; assert {'--jurisdiction','--court','--court-type','--cites','--domain','--limit','--timeout','--full','-o'} <= set(c['verbs']['gov']['flags']); assert {'--types','--repos','--sources','--skills-only','--passages','--language','--topic','--license','--min-stars','--max-stars','--archived','--fork'} <= set(c['verbs']['developer']['flags']); assert any('API-direct' in w for w in c['warnings']) and not any('skills-only filter have no shaped' in w for w in c['warnings'])"
contains "$(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" COLUMNS=400 "$CLI" gov --help)" 'legal advice' 'gov help carries the legal caveat'
contains "$(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" COLUMNS=400 "$CLI" developer --help)" 'outside the ledger' 'developer help names the keyless rule'
# The gov value flags are vendor 1.26.x flags; a value must never stand in for login.
fixture scrape
run_cli raw --json -- --jurisdiction us-ca login
status_is 4 'raw denylist: gov value flag before login'
no_calls 'raw denylist: gov value flag before login'
contains "$ERR" 'account administration' 'raw denylist names the refusal after a gov flag'
# The developer filters take a value in the wrapper; that value must never stand in for login.
for flag in --types --repos --passages --language --topic --license --min-stars --max-stars --archived --fork; do
  fixture scrape
  run_cli raw --json -- "$flag" x login
  status_is 4 "raw denylist: $flag before login"
  no_calls "raw denylist: $flag before login"
done

# Free-first routing (#2118): a call whose keyed and keyless outputs were probed
# equivalent tries Firecrawl's free keyless tier first and runs keyed once when it
# refuses. FIRECRAWL_CLI_KEYLESS=1 turns the routing back on for these calls. The
# env log records which credentials each vendor call saw, never their values.
export FIRECRAWL_TEST_ENV_LOG="$TMP/env.jsonl"
COOLDOWN="$TMP/home/.claude/state/firecrawl-cli/keyless-cooldown.json"
# A placeholder claim link: the live refusal carries a per-install signup URL.
REFUSAL="Error: You've hit Firecrawl's keyless free tier rate limit. To continue now, create a free API key at https://firecrawl.dev/k/placeholder-claim-id"
REFUSED_RULE="{\"default\":{\"fixture\":\"scrape.json\",\"keyless\":{\"stderr_text\":\"$REFUSAL\",\"exit\":1}}}"
API_REFUSAL="{\"status\":429,\"headers\":{\"Retry-After\":\"13600\"},\"body\":{\"success\":false,\"error\":\"$REFUSAL\",\"reason\":\"credits\",\"retry_after_seconds\":13600}}"
kl_configure() { configure "$1"; : >"$FIRECRAWL_TEST_ENV_LOG"; }
run_kl() {  # no key, the vendor's default API URL
  ST=0
  (cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_CLI_KEYLESS=1 "$CLI" "$@") >"$TMP/out" 2>"$TMP/err" || ST=$?
  OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
}
run_kl_keyed() {  # a key, the vendor's default API URL
  ST=0
  (cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_CLI_KEYLESS=1 FIRECRAWL_API_KEY="$API_KEY" "$CLI" "$@") >"$TMP/out" 2>"$TMP/err" || ST=$?
  OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
}
run_kl_api() {  # a key and the loopback API
  ST=0
  (cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_CLI_KEYLESS=1 FIRECRAWL_API_KEY="$API_KEY" FIRECRAWL_API_URL="http://127.0.0.1:$API_PORT" "$CLI" "$@") >"$TMP/out" 2>"$TMP/err" || ST=$?
  OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
}
# [verb, saw a key, saw an API URL] per vendor call; credit-usage reads left out.
env_seen() { python3 -c 'import json,os; print(json.dumps([[e["argv"][0],e["key"],e["url"]] for e in map(json.loads,open(os.environ["FIRECRAWL_TEST_ENV_LOG"])) if e["argv"][0]!="credit-usage"]))'; }
api_auth() { python3 -c 'import json,os; print(json.dumps([json.loads(l)["authorization"] for l in open(os.environ["FIRECRAWL_API_TEST_LOG"])]))'; }
cooldown_left() { python3 -c 'import json,sys,time; print(round(json.load(open(sys.argv[1]))["until"]-time.time()))' "$COOLDOWN" 2>&1; }
no_cooldown() { [[ ! -e "$COOLDOWN" ]] && ok || bad "$1: cooldown armed"; }

# No key: an eligible call is answered keyless, outside the ledger.
kl_configure '{"default":{"fixture":"scrape.json"}}'
run_kl fetch https://x --json
status_is 0 'keyless fetch without a key'
jcheck 'keyless fetch envelope' "$OUT" "assert d['ok'] and d['credits_spent']==0 and d['credits_remaining'] is None and d['budget_remaining']==$BASE; g=d['degraded']; assert len(g)==1 and g[0].startswith('keyless: answered by'), g; assert d['data']['markdown']=='# Example'"
jcheck 'keyless fetch reads no credit-usage' "$(vendor_verbs)" "assert d==['scrape'], d"
jcheck 'keyless leg saw no credentials' "$(env_seen)" "assert d==[['scrape',False,False]], d"
run_kl fetch https://x
status_is 0 'keyless plain fetch'
jcheck 'keyless routing note keeps plain output bare' "$OUT" "assert 'ok' not in d and d['markdown']=='# Example'"
# A key: eligible calls still go keyless first, with the key and the default URL stripped.
kl_configure '{"default":{"fixture":"scrape.json"}}'
run_kl_keyed fetch https://x --json
status_is 0 'keyed eligible fetch runs keyless first'
jcheck 'keyless-first envelope spends nothing' "$OUT" "assert d['ok'] and d['credits_spent']==0 and d['credits_remaining'] is None and d['budget_remaining']==$BASE; g=d['degraded']; assert len(g)==1 and g[0].startswith('keyless: answered by'), g"
jcheck 'keyless-first reads no credit-usage' "$(vendor_verbs)" "assert d==['scrape'], d"
jcheck 'keyless-first leg saw no key' "$(env_seen)" "assert d==[['scrape',False,False]], d"
omits "$OUT$ERR" "$API_KEY" 'keyless-first never prints the key'
kl_configure '{"default":{"fixture":"scrape.json"}}'
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_CLI_KEYLESS=1 FIRECRAWL_API_KEY="$API_KEY" FIRECRAWL_API_URL=https://api.firecrawl.dev "$CLI" fetch https://x --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
status_is 0 'the default API URL stays keyless-eligible'
jcheck 'keyless leg strips the default API URL' "$(env_seen)" "assert d==[['scrape',False,False]], d"
# #805: a trailing slash or capitals used to turn keyless-first off silently.
for url in https://api.firecrawl.dev/ 'HTTPS://API.Firecrawl.dev//'; do
  kl_configure '{"default":{"fixture":"scrape.json"}}'
  ST=0
  (cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_CLI_KEYLESS=1 FIRECRAWL_API_KEY="$API_KEY" FIRECRAWL_API_URL="$url" "$CLI" fetch https://x --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
  status_is 0 "default API URL spelled $url stays keyless-eligible"
  jcheck "default API URL spelled $url runs the keyless leg" "$(env_seen)" "assert d==[['scrape',False,False]], d"
  jcheck "default API URL spelled $url spends nothing" "$(cat "$TMP/out")" "assert d['credits_spent']==0 and d['degraded'][0].startswith('keyless: answered by'), d"
done
kl_configure '{"default":{"fixture":"scrape-session.json"}}'
run_kl_keyed fetch https://x --json
jcheck 'keyless scrape id carries the interact caveat' "$OUT" "assert any(n.startswith('keyless: scrape_id comes from a keyless fetch') and 'FIRECRAWL_CLI_KEYLESS=0' in n for n in d['degraded']), d['degraded']"
kl_configure '{"default":{"fixture":"scrape-session.json"}}'
run_kl_keyed shot https://x --json
jcheck 'only fetch carries the interact caveat' "$OUT" "assert d['ok'] and not any(n.startswith('keyless: scrape_id') for n in d['degraded']), d['degraded']"

# Only the probed-equivalent shapes go keyless; everything else runs keyed as before.
kl_shape() {
  local label=$1 want=$2 fixture=$3; shift 3
  kl_configure "{\"default\":{\"fixture\":\"$fixture.json\"}}"
  run_kl_keyed "$@" --json
  status_is 0 "shape $label"
  jcheck "shape $label routed $want" "$(env_seen)" "assert d and d[0][1] is ('$want'=='keyed'), d"
}
kl_shape 'summary' keyless scrape fetch https://x
kl_shape 'full markdown' keyless scrape fetch https://x --full
kl_shape 'links,html' keyless scrape fetch https://x --format links,html
kl_shape 'max-age 0' keyless scrape fetch https://x --max-age 0
kl_shape 'rawHtml' keyed scrape fetch https://x --format rawHtml
kl_shape 'summary,changeTracking' keyed scrape fetch https://x --format summary,changeTracking
kl_shape 'shot' keyless scrape shot https://x
kl_shape 'map' keyed map map https://x
kl_shape 'schema' keyless scrape-json extract https://x --schema '{"type":"object"}'
kl_shape 'schema plus markdown' keyed scrape-json extract https://x --schema '{"type":"object"}' --format markdown
kl_shape 'question plus markdown' keyed scrape extract https://x -Q 'What is this page?' --format markdown
kl_shape 'schema plus question' keyed scrape-json extract https://x --schema '{"type":"object"}' -Q 'What is this page?'
kl_shape 'raw research help' keyed search-research raw -- research search-papers --help
kl_shape 'raw research -h' keyed search-research raw -- research search-papers -h
kl_shape 'PDF summary' keyless parse fetch report.pdf
kl_shape 'PDF markdown' keyless parse fetch report.pdf --full
touch "$TMP/work/page.docx"
kl_shape 'docx parse' keyed parse fetch page.docx
kl_shape 'search' keyless search-id search 'example query'
kl_shape 'search research web,images limit 10' keyless search-id search 'example query' --categories research --sources web,images --limit 10
kl_shape 'search limit 11' keyed search-id search 'example query' --limit 11
kl_shape 'search pdf category' keyed search-id search 'example query' --categories pdf
kl_shape 'search news source' keyed search-id search 'example query' --sources news
kl_shape 'search gov category' keyed search-id search 'example query' --categories gov
kl_shape 'search alexandria source' keyed search-id search 'example query' --sources alexandria
argv_is 'alexandria source forwarded' "assert d[d.index('--sources')+1]=='alexandria'"
kl_shape 'removed research search-github is never keyless' keyed search-research raw -- research search-github query
kl_configure '{"default":{"text":"Example Domain is a reserved page.\n","stderr_text":"Scrape ID: s-1\n"}}'
run_kl_keyed extract https://x -Q 'What is this page?' --json
status_is 0 'question alone keyless'
jcheck 'question alone went keyless' "$(env_seen)" "assert d==[['scrape',False,False]], d"
jcheck 'keyless question answer read as text' "$OUT" "assert d['data']=={'answer':'Example Domain is a reserved page.'} and d['credits_spent']==0"
kl_configure '{"default":{"text":"Example Domain is a reserved page.\n"}}'
run_kl_keyed extract report.pdf -Q 'What is this?' --json
jcheck 'PDF question stays keyed' "$(env_seen)" "assert d==[['parse',True,False]], d"
kl_configure '{"default":{"fixture":"search-id.json"}}'
run_kl_keyed search 'example query' --json
jcheck 'keyless search charges nothing' "$OUT" "assert d['ok'] and d['credits_spent']==0 and d['budget_remaining']==$BASE"
kl_configure '{"default":{"fixture":"search-research.json"}}'
run_kl_keyed raw --json -- research search-papers crispr
status_is 0 'raw research search keyless'
jcheck 'raw research keyless envelope' "$OUT" "assert d['ok'] and d['credits_spent']==0 and d['budget_remaining']==$BASE"
jcheck 'raw research went keyless without a credit read' "$(vendor_verbs)" "assert d==['research'], d"
kl_configure '{"default":{"fixture":"scrape.json"}}'
run_kl_keyed raw --json -- scrape https://x
status_is 0 'other raw stays keyed'
jcheck 'other raw keyed after a credit read' "$(vendor_verbs)" "assert d[0]=='credit-usage' and 'scrape' in d, d"
jcheck 'other raw keyed leg' "$(env_seen)" "assert d==[['scrape',True,False]], d"
# Keyed developer goes keyless first only at the probed limit; without a key it always was.
kl_configure '{}'
api_control "{\"status\":200,\"body\":$(dev_body)}"
run_kl_api developer 'tokio select cancellation safety' --limit 2 --json
status_is 0 'keyed developer at limit 2 runs keyless first'
jcheck 'keyless-first developer envelope' "$OUT" "assert d['credits_spent']==0 and d['budget_remaining']==$BASE and d['degraded']==[\"keyless developer search: account floor unchecked; Firecrawl's keyless allowance applies\"]"
jcheck 'keyless-first developer sent no Bearer' "$(api_auth)" "assert d==[None], d"
no_calls 'keyless-first developer never reads credit-usage'
kl_configure '{}'
api_control "{\"status\":200,\"body\":$(dev_body)}"
run_kl_api developer 'tokio select cancellation safety' --limit 11 --json
jcheck 'keyed developer past limit 10 stays keyed' "$(api_auth)" "assert d==['Bearer $API_KEY'], d"
kl_configure '{}'
api_control "{\"status\":200,\"body\":$(dev_body)}"
run_kl_api developer 'tokio select cancellation safety' --limit 10 --json
jcheck 'keyed developer at limit 10 runs keyless first' "$(api_auth)" "assert d==[None], d"
kl_configure '{}'
api_control "{\"status\":200,\"body\":$(cat "$TMP/fixtures/search-dev.json")}"
run_kl_api search 'example query' --categories developer --limit 2 --json
jcheck 'developer search category stays keyed' "$(api_auth)" "assert d==['Bearer $API_KEY'], d"

# The keyless refusal: fall back keyed once, then hold eligible calls keyed.
kl_configure "$REFUSED_RULE"
run_kl_keyed fetch https://x --json
status_is 0 'refused keyless leg falls back keyed'
jcheck 'fallback ran keyless then keyed' "$(env_seen)" "assert d==[['scrape',False,False],['scrape',True,False]], d"
jcheck 'keyless leg ran before the credit read' "$(vendor_verbs)" "assert d[:2]==['scrape','credit-usage'], d"
jcheck 'fallback envelope names the refusal' "$OUT" "g=d['degraded']; assert d['ok'] and d['credits_spent']>0, d; assert g[0].startswith('keyless: keyless_rate_limited: ') and g[0].endswith('; ran keyed instead'), g; assert g[1].startswith('keyless: eligible calls run keyed until '), g"
jcheck 'refusal arms the default hour' "$(cooldown_left)" "assert 3500<=d<=3600, d"
omits "$OUT$ERR" 'placeholder-claim-id' 'fallback redacts the claim link'
RESET_LEDGER=0
kl_configure "$REFUSED_RULE"
run_kl_keyed fetch https://x --json
status_is 0 'cooldown runs eligible calls keyed'
jcheck 'cooldown skips the keyless leg' "$(env_seen)" "assert d==[['scrape',True,False]], d"
jcheck 'cooldown note names when keyless resumes' "$OUT" "assert d['degraded'][0].startswith('keyless: skipped, ran keyed: the free tier refused a call recently; it is tried again after '), d['degraded']"
python3 -c 'import json,sys,time; json.dump({"until":time.time()-1},open(sys.argv[1],"w"))' "$COOLDOWN"
kl_configure '{"default":{"fixture":"scrape.json"}}'
run_kl_keyed fetch https://x --json
jcheck 'expired cooldown tries keyless again' "$(env_seen)" "assert d==[['scrape',False,False]], d"
printf '{"until": 1e18}' >"$COOLDOWN"
kl_configure '{"default":{"fixture":"scrape.json"}}'
run_kl_keyed fetch https://x --json
jcheck 'a planted marker holds calls keyed six hours at most' "$OUT" "import time; from datetime import datetime; n=d['degraded'][0]; assert n.startswith('keyless: skipped'), n; assert datetime.fromisoformat(n.rsplit('after ',1)[1]).timestamp()<=time.time()+6*3600+60, n"
printf '{"until": NaN}' >"$COOLDOWN"
kl_configure '{"default":{"fixture":"scrape.json"}}'
run_kl_keyed fetch https://x --json
jcheck 'a non-finite marker is no cooldown' "$(env_seen)" "assert d==[['scrape',False,False]], d"
RESET_LEDGER=1
# The second target of a refused call runs keyed under the cooldown the first armed.
kl_configure "$REFUSED_RULE"
run_kl_keyed fetch https://x https://y --json
status_is 0 'multi-target fallback'
jcheck 'one keyless attempt per call' "$(env_seen)" "assert d==[['scrape',False,False],['scrape',True,False],['scrape',True,False]], d"
# The API states its window: Retry-After and retry_after_seconds set the cooldown.
kl_configure '{}'
api_control "{\"status\":200,\"body\":$(dev_body),\"keyless\":$API_REFUSAL}"
run_kl_api developer 'tokio select cancellation safety' --limit 2 --json
status_is 0 'developer keyless 429 falls back keyed'
jcheck 'developer fallback sent the Bearer second' "$(api_auth)" "assert d==[None,'Bearer $API_KEY'], d"
jcheck 'developer fallback envelope' "$OUT" "g=d['degraded']; assert d['credits_spent']==2, d; assert g[0].startswith('keyless: keyless_rate_limited: ') and g[1].startswith('keyless: eligible calls run keyed until '), g; assert not any(n.startswith('keyless developer search') for n in g), g"
jcheck 'API-stated window sets the cooldown' "$(cooldown_left)" "assert 13500<=d<=13600, d"
omits "$OUT$ERR" 'placeholder-claim-id' 'API refusal redacts the claim link'
omits "$OUT$ERR" "$API_KEY" 'developer fallback never prints the key'
# A stated window past six hours is capped when armed, in the marker and the note.
kl_configure '{}'
api_control "{\"status\":200,\"body\":$(dev_body),\"keyless\":${API_REFUSAL//13600/1000000}}"
run_kl_api developer 'tokio select cancellation safety' --limit 2 --json
status_is 0 'long stated window falls back keyed'
jcheck 'long stated window armed at the cap' "$(cooldown_left)" "assert 21500<=d<=21600, d"
jcheck 'long stated window note names the capped time' "$OUT" "import time; from datetime import datetime; n=d['degraded'][1]; assert n.startswith('keyless: eligible calls run keyed until '), n; assert datetime.fromisoformat(n.rsplit('until ',1)[1]).timestamp()<=time.time()+6*3600+60, n"
# A key-shaped failure falls back without arming: it may be one combination's limit.
for status in 401 402 429; do
  case "$status" in
    401) tag=auth_failure body='{"success":false,"error":"Unauthorized: Invalid token"}' ;;
    402) tag=quota_exhausted body='{"success":false,"error":"Insufficient credits to perform this request."}' ;;
    429) tag=rate_limited body='{"success":false,"error":"Rate limit exceeded. Consumed (req/min): 61"}' ;;
  esac
  kl_configure '{}'
  api_control "{\"status\":200,\"body\":$(dev_body),\"keyless\":{\"status\":$status,\"body\":$body}}"
  run_kl_api developer 'tokio select cancellation safety' --limit 2 --json
  status_is 0 "keyless $status falls back keyed"
  jcheck "keyless $status then keyed" "$(api_auth)" "assert d==[None,'Bearer $API_KEY'], d"
  jcheck "keyless $status fallback note" "$OUT" "g=[n for n in d['degraded'] if n.startswith('keyless: ')]; assert len(g)==1 and g[0].startswith('keyless: $tag: '), g"
  no_cooldown "keyless $status"
done
kl_configure '{"default":{"fixture":"scrape.json","keyless":{"fixture":"login-menu.txt"}}}'
run_kl_keyed fetch https://x --json
status_is 0 'keyless login menu falls back keyed'
jcheck 'login menu fallback note' "$OUT" "assert d['degraded'][0].startswith('keyless: credentials_missing: '), d['degraded']"
no_cooldown 'keyless login menu'
# Anything else raises as-is; the keyed leg never runs.
kl_configure '{}'
api_control "{\"status\":200,\"body\":$(dev_body),\"keyless\":{\"status\":503,\"body\":{\"success\":false,\"error\":\"Service Unavailable\"}}}"
run_kl_api developer 'tokio select cancellation safety' --limit 2 --json
status_is 2 'keyless 503 raises'
jcheck 'keyless 503 envelope' "$OUT" "assert d['error']['code']=='provider_failure' and d['credits_spent']==0, d"
jcheck 'keyless 503 ran no keyed leg' "$(api_auth)" "assert d==[None], d"
no_calls 'keyless 503 read no credit-usage'
for name in injected unsupported malformed; do
  case "$name" in
    injected) want=1 tag=injection_blocked rule='{"fixture":"injected.json","stderr_text":"HTTP 403","exit":1}' ;;
    unsupported) want=1 tag=unsupported_site rule='{"stderr_text":"Error: We do not support this site","exit":1}' ;;
    malformed) want=2 tag=vendor_output_changed rule='{"text":"not json"}' ;;
  esac
  kl_configure "{\"default\":{\"fixture\":\"scrape.json\",\"keyless\":$rule}}"
  run_kl_keyed fetch https://x --json
  status_is "$want" "keyless $name raises"
  jcheck "keyless $name envelope" "$OUT" "assert d['error']['code']=='$tag', d['error']"
  jcheck "keyless $name ran no keyed leg" "$(vendor_verbs)" "assert d==['scrape'], d"
  no_cooldown "keyless $name"
done

# Without a key keyless is the only leg: its refusal exits 1 and names the key.
kl_configure "$REFUSED_RULE"
run_kl fetch https://x --json
status_is 1 'no-key keyless refusal exits 1'
jcheck 'no-key refusal envelope' "$OUT" "e=d['error']; assert e['code']=='keyless_rate_limited', e; assert 'FIRECRAWL_API_KEY' in e['next_action'] and 'retry keyless after about ' in e['next_action'], e"
contains "$ERR" 'keyless free tier refused the call' 'no-key refusal named'
omits "$OUT$ERR" 'placeholder-claim-id' 'no-key refusal redacts the claim link'
jcheck 'no-key refusal arms the cooldown' "$(cooldown_left)" "assert 3500<=d<=3600, d"
RESET_LEDGER=0
kl_configure "$REFUSED_RULE"
run_kl fetch https://x --json
status_is 1 'no-key call during the cooldown'
jcheck 'the cooldown never blocks a call with no key' "$(env_seen)" "assert d==[['scrape',False,False]], d"
RESET_LEDGER=1
kl_configure "$REFUSED_RULE"
run_kl fetch https://x https://y --json
jcheck 'a refused call sends no second keyless request' "$(env_seen)" "assert d==[['scrape',False,False]], d"
jcheck 'the later target names the earlier refusal' "$OUT" "i=d['data']['items']; assert [x['ok'] for x in i]==[False,False], i; assert i[1]['error']['code']=='keyless_rate_limited' and 'not sent' in i[1]['error']['message'], i"
# A marker that cannot be written costs a later refused attempt, never this call.
kl_configure "$REFUSED_RULE"
run_cli budget --json
mkdir "$COOLDOWN"
run_kl fetch https://x --json
status_is 1 'unrecorded cooldown still reports the refusal'
jcheck 'unrecorded cooldown is named' "$OUT" "assert any(n.startswith('keyless: cooldown not recorded: ') for n in d['degraded']), d['degraded']"
rmdir "$COOLDOWN"
# Unrecorded, the cooldown still holds the same call's later targets keyed.
kl_configure "$REFUSED_RULE"
run_cli budget --json
mkdir "$COOLDOWN"
run_kl_keyed fetch https://x https://y --json
status_is 0 'unrecorded cooldown multi-target fallback'
jcheck 'unrecorded cooldown sends one keyless request per call' "$(env_seen)" "assert d==[['scrape',False,False],['scrape',True,False],['scrape',True,False]], d"
rmdir "$COOLDOWN"

# Routing stays off for the opt-out, a stored vendor login, and a custom API URL.
kl_configure '{"default":{"fixture":"scrape.json"}}'
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_CLI_KEYLESS=OFF FIRECRAWL_API_KEY="$API_KEY" "$CLI" fetch https://x --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
status_is 0 'opt-out runs keyed'
jcheck 'opt-out skips the keyless leg' "$(env_seen)" "assert d==[['scrape',True,False]], d"
mkdir -p "$TMP/home/.config/firecrawl-cli"
printf '{}' >"$TMP/home/.config/firecrawl-cli/credentials.json"
kl_configure '{"default":{"fixture":"scrape.json"}}'
run_kl_keyed fetch https://x --json
jcheck 'a stored vendor login keeps vendor calls keyed' "$(env_seen)" "assert d==[['scrape',True,False]], d"
rm -r "$TMP/home/.config/firecrawl-cli"
kl_configure '{"default":{"fixture":"scrape.json"}}'
run_kl_api fetch https://x --json
jcheck 'a custom API URL keeps vendor calls keyed' "$(env_seen)" "assert d==[['scrape',True,True]], d"
# A keyed fallback the budget refuses says both legs failed, and keeps the cooldown.
kl_configure '{"credit-usage":{"remaining":[-384]}}'
api_control "{\"status\":200,\"body\":$(dev_body),\"keyless\":$API_REFUSAL}"
run_kl_api developer 'axum middleware ordering' --limit 2 --json
status_is 3 'refused keyless and refused keyed exits 3'
jcheck 'both legs named' "$(error_json)" "e=d['error']; assert e['message'].startswith('keyless leg unavailable, and the keyed fallback was refused: '), e; assert 'has -384 credits' in e['message'], e; assert 'env -u FIRECRAWL_API_KEY' not in e['next_action'], e; assert d['degraded'][0].startswith('keyless: keyless_rate_limited: '), d['degraded']"
jcheck 'cooldown survives the keyed refusal' "$(cooldown_left)" "assert 13500<=d<=13600, d"
jcheck 'the refused keyed leg never reached the API' "$(api_auth)" "assert d==[None], d"
# The contract names free-first routing, its opt-out, and the keyed developer limit.
run_cli capabilities --json
jcheck 'capabilities free-first contract' "$OUT" "w=[x for x in d['data']['warnings'] if x.startswith('free-first')]; assert len(w)==1, w; assert 'FIRECRAWL_CLI_KEYLESS=0' in w[0] and 'keyless_cooldown' in w[0] and 'scrape_id' in w[0], w; assert d['data']['budget_environment']['keyless_cooldown']=='FIRECRAWL_CLI_KEYLESS_COOLDOWN', d['data']['budget_environment']; assert any('limit 10 or less goes keyless first' in x for x in d['data']['warnings'])"
run_cli --help
contains "$OUT" 'FIRECRAWL_CLI_KEYLESS=0' 'root help names free-first and its opt-out'
unset FIRECRAWL_TEST_ENV_LOG

# #805: page content keeps its text. Inside page fields only exact secret values are
# redacted; the pattern rules stay on errors, stderr and argv echoes.
python3 - "$TMP/fixtures" "$API_KEY" <<'PY'
import json, pathlib, sys
page = ("Require bearer tokens for API endpoints. Pass -keep to retain files. "
        "Sample JWT eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl and the key "
        "fc-YOUR_API_KEY_HERE; run tool --api-key sample-value --token abc -k xyz.")
fixtures = pathlib.Path(sys.argv[1])
(fixtures / "content-805-page.txt").write_text(page)
(fixtures / "content-805.json").write_text(json.dumps({
    "markdown": page + " Echoed key: " + sys.argv[2] + ".",
    "metadata": {
        "title": "Bearer token guide", "description": "Use -keep and fc-YOUR_API_KEY_HERE",
        "sourceURL": "https://x", "statusCode": 200,
    },
    "links": ["https://x/docs?jwt=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"],
}))
# A failed call's payload is diagnostics: a key-shaped value in it stays caught.
(fixtures / "content-805-fail.json").write_text(json.dumps({
    "success": False, "error": "invalid request",
    "metadata": {"hint": "Authorization: Bearer patternONLYsecret99"},
}))
PY
PAGE_CHECK="p=open('$TMP/fixtures/content-805-page.txt').read(); assert x['markdown']==p+' Echoed key: [REDACTED].', x['markdown']; m=x['metadata']; assert m['title']=='Bearer token guide' and m['description']=='Use -keep and fc-YOUR_API_KEY_HERE', m; assert x['links']==['https://x/docs?jwt=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl'], x['links']"
run_keyed() {  # a key that is not fc- shaped, so only exact-value redaction can hide it
  ST=0
  (cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_API_KEY="$API_KEY" "$CLI" "$@") >"$TMP/out" 2>"$TMP/err" || ST=$?
  OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
}
fixture content-805
run_keyed fetch https://x --full --json
status_is 0 'content fetch --full --json'
jcheck 'page text survives --full --json' "$OUT" "x=d['data']; $PAGE_CHECK"
omits "$OUT$ERR" "$API_KEY" 'env key echoed in page text is redacted exactly'
fixture content-805
run_keyed fetch https://x --format markdown --json
jcheck 'page text survives a bounded --format fetch' "$OUT" "x=d['data']; $PAGE_CHECK"
fixture content-805
run_keyed fetch https://x --full
status_is 0 'content fetch default output'
jcheck 'page text survives the default output' "$OUT" "x=d['data'] if 'ok' in d else d; $PAGE_CHECK"
fixture content-805
run_keyed fetch https://x --full --json --output "$TMP/content-805-out.json"
jcheck 'page text survives the --output file' "$(cat "$TMP/content-805-out.json")" "x=d['data']; $PAGE_CHECK"
fixture content-805
run_keyed fetch https://x https://y --full --json
status_is 0 'content fetch of two URLs'
jcheck 'two fanned-out items' "$OUT" "assert len(d['data']['items'])==2, d['data']"
jcheck 'page text survives the first fanned-out item' "$OUT" "x=d['data']['items'][0]['data']; $PAGE_CHECK"
jcheck 'page text survives the second fanned-out item' "$OUT" "x=d['data']['items'][1]['data']; $PAGE_CHECK"
configure "{\"default\":{\"stderr_text\":\"HTTP 401 key $API_KEY rejected; Authorization: Bearer abcdefSECRET123 -kshortSECRET\",\"exit\":1}}"
run_keyed fetch https://x --full --json
[[ "$ST" -ne 0 ]] && ok || bad 'vendor error carrying the env key exited 0'
for secret in "$API_KEY" abcdefSECRET123 shortSECRET; do
  omits "$OUT$ERR" "$secret" 'error text keeps exact and pattern redaction'
done
configure '{"default":{"fixture":"content-805-fail.json","exit":1}}'
run_keyed fetch https://x --full --json
status_is 1 'failed call with a metadata hint'
omits "$OUT$ERR" 'patternONLYsecret99' 'a failed payload keeps every pattern, metadata included'
python3 - "$TMP/fixtures" <<'PY'
import json, pathlib, sys
fixtures = pathlib.Path(sys.argv[1])
page = (fixtures / "content-805-page.txt").read_text()
(fixtures / "content-805-partial.json").write_text(json.dumps({"items": [
    {"url": "https://x", "ok": True, "data": {"markdown": page}},
    {"url": "https://y", "ok": False, "error": {"code": 1, "message": "vendor failure"},
     "metadata": {"hint": "Authorization: Bearer patternONLYitem77"}, "data": None},
]}))
PY
fixture content-805-partial
run_keyed fetch https://x --full --json
status_is 6 'partial result with a failed item'
omits "$OUT$ERR" 'patternONLYitem77' 'a failed item keeps every pattern, metadata included'
jcheck 'the successful item keeps its page text' "$OUT" "p=open('$TMP/fixtures/content-805-page.txt').read(); assert d['data']['items'][0]['data']['markdown']==p, d['data']['items'][0]"
RESULT=$(HOME="$TMP/home" PYTHONDONTWRITEBYTECODE=1 python3 - "$MODULE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('firecrawl_cli', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.SECRETS.clear()
m.SECRETS.add('exact-secret-value-123')
page = 'Require bearer tokens; pass -keep; fc-YOUR_API_KEY_HERE; eyJa.eyJb.c2ln; exact-secret-value-123'
out = m.redact({
    'data': {'markdown': page, 'passages': [{'text': page}], 'metadata': {'error': 'Bearer abcdef123'}},
    'error': {'message': 'Bearer abcdef123 -kSECRET fc-abcdefgh12345678', 'metadata': 'Bearer abcdef123'},
    'text': 'raw stdout fc-abcdefgh12345678',
})
expected = page.replace('exact-secret-value-123', '[REDACTED]')
assert out['data']['markdown'] == expected, out
assert out['data']['passages'] == [{'text': expected}], out
assert out['data']['metadata']['error'] == 'Bearer [REDACTED]', out
for leaked in ('abcdef123', 'kSECRET', 'fc-abcdefgh'):
    assert leaked not in str(out['error']) and leaked not in out['text'], out
assert m.redact({'metadata': {'hint': 'Bearer abcdef123'}}, content_keys=frozenset()) == {'metadata': {'hint': 'Bearer [REDACTED]'}}
assert m.redact({'markdown': '\x1b[31mred\x1b[0m'}) == {'markdown': 'red'}
print('OK')
PY
)
[[ "$RESULT" == OK ]] && ok || bad "redact content and diagnostic fields: $RESULT"

# #805: a keyed vendor call never inherits a plain-http, non-loopback API URL.
run_url() {  # $1 the API URL; the rest is the command; a key is set
  local url=$1
  shift
  ST=0
  (cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_API_KEY="$API_KEY" FIRECRAWL_API_URL="$url" "$CLI" "$@") >"$TMP/out" 2>"$TMP/err" || ST=$?
  OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
}
fixture scrape
run_url http://10.255.255.1:8080 fetch https://example.com --format markdown --json
status_is 4 'plain-http API URL refuses a keyed fetch'
no_calls 'refused API URL: no credit read, no vendor process'
jcheck 'API URL refusal names the rule' "$OUT" "assert 'must be an https URL, or http to a loopback host' in d['error']['message'], d['error']"
fixture scrape
run_url http://10.255.255.1:8080 raw --json -- crawl https://example.com
status_is 4 'plain-http API URL refuses raw'
no_calls 'raw: refused API URL starts no vendor process'
fixture scrape
run_url ftp://api.firecrawl.dev fetch https://example.com --json
status_is 4 'non-http API URL refused'
no_calls 'non-http API URL starts no vendor process'
# Python reads these hosts as loopback; the vendor's Node URL parser does not.
fixture scrape
run_url 'http://evil.example\@127.0.0.1:8080' fetch https://example.com --json
status_is 4 'backslash API URL refused'
no_calls 'backslash API URL starts no vendor process'
fixture scrape
run_url 'http://user@127.0.0.1:8080' fetch https://example.com --json
status_is 4 'userinfo API URL refused'
no_calls 'userinfo API URL starts no vendor process'
# The refusal must not print what it refuses: a URL password is not a known secret (#825 review).
fixture scrape
run_url 'https://alice:proxy-password-825@203.0.113.7' fetch https://example.com --json
status_is 4 'https API URL with a password refused'
no_calls 'password API URL starts no vendor process'
omits "$OUT$ERR" 'proxy-password-825' 'refused https API URL: password in neither stream'
omits "$OUT$ERR" 'alice' 'refused https API URL: username in neither stream'
jcheck 'refusal shows only scheme and host' "$OUT" "m=d['error']['message']; assert \"'https://203.0.113.7'\" in m, m"
fixture scrape
run_url 'http://bob:lan-password-825@10.255.255.1:8080' fetch https://example.com --json
status_is 4 'plain-http API URL with a password refused'
omits "$OUT$ERR" 'lan-password-825' 'refused plain-http API URL: password in neither stream'
fixture scrape
run_url 'http://carol:slash-password-825\@127.0.0.1:8080' fetch https://example.com --json
status_is 4 'backslash API URL with a password refused'
omits "$OUT$ERR" 'slash-password-825' 'refused backslash API URL: password in neither stream'
fixture scrape
run_url 'https://dave:gov-password-825@203.0.113.7' gov 'minimum wage' --json
status_is 4 'API-direct verb refuses a password API URL'
no_calls 'API-direct password URL starts no vendor process'
omits "$OUT$ERR" 'gov-password-825' 'API-direct refusal: password in neither stream'
fixture scrape
run_url "$(printf 'http://127.0.0.1\t.evil.example:8080')" fetch https://example.com --json
status_is 4 'control-character API URL refused'
no_calls 'control-character API URL starts no vendor process'
fixture scrape
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" FIRECRAWL_API_URL=http://10.255.255.1:8080 "$CLI" fetch https://example.com --json) >"$TMP/out" 2>"$TMP/err" || ST=$?
status_is 4 'plain-http API URL refused with no env key, since a stored login would ride along'
no_calls 'no env key: refused API URL starts no vendor process'
fixture scrape
run_url http://127.0.0.1:9 fetch https://example.com --format markdown --json
status_is 0 'loopback http API URL still runs keyed'
fixture scrape
run_url https://firecrawl.example.test fetch https://example.com --format markdown --json
status_is 0 'another https API URL still runs keyed'
RESULT=$(HOME="$TMP/home" FIRECRAWL_API_URL=http://10.255.255.1:8080 PYTHONDONTWRITEBYTECODE=1 python3 - "$MODULE" <<'PY'
import importlib.util, sys
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('firecrawl_cli', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
done = m.subprocess.CompletedProcess([], 0, '{"success": true}', '')
with patch.object(m, 'vendor_binary', return_value='/bin/true'), \
        patch.object(m.subprocess, 'run', return_value=done) as run:
    try:
        m.invoke_vendor(['credit-usage', '--json'], 5)
    except m.CliError as exc:
        assert exc.code == 4 and 'must be an https URL' in str(exc), exc
    else:
        raise SystemExit('a keyed invoke_vendor ran with a plain-http API URL')
    assert not run.called
    m.invoke_vendor(['scrape', 'https://x'], 5, keyless=True)
    assert run.call_count == 1 and 'FIRECRAWL_API_URL' not in run.call_args.kwargs['env']
print('OK')
PY
)
[[ "$RESULT" == OK ]] && ok || bad "invoke_vendor refuses a keyed run with a plain-http API URL: $RESULT"

# settings.json allows only the index verbs, so sessions in a stricter permission
# mode (claude -p --permission-mode acceptEdits, plan-mode subagents) run them
# unprompted; metered verbs and raw still fall through to a prompt.
RESULT=$(python3 - "$REPO/settings.json" "$REPO/tests/permission_rules.py" <<'PY'
import importlib.util
import json
import sys
spec = importlib.util.spec_from_file_location("permission_rules", sys.argv[2])
rules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rules)
permissions = json.load(open(sys.argv[1]))["permissions"]
expect = {
    "firecrawl-cli gov 'food truck permit Texas' --limit 3 --json": "allow",
    "firecrawl-cli developer 'axum middleware ordering' --json": "allow",
    "firecrawl-cli fetch https://example.com --json": "prompt",
    "firecrawl-cli search 'axum' --categories developer --json": "prompt",
    "firecrawl-cli raw --json -- research search-papers 'crispr'": "prompt",
}
wrong = [f"{c!r} -> {rules.decide(c, permissions)}, want {w}"
         for c, w in expect.items() if rules.decide(c, permissions) != w]
print("; ".join(wrong) or "OK")
PY
)
[[ "$RESULT" == OK ]] && ok || bad "settings permission rules: $RESULT"

# #807: the Firecrawl Local tier. The stub replays output recorded from the pinned
# 0.1.1 binary and logs each run beside itself, since the wrapper hands the scraper
# an environment built from nothing.
LOCAL="$TMP/local"
SLOTS="$TMP/home/.claude/state/firecrawl-cli/local-browser"
mkdir -p "$LOCAL"
cp "$FIXTURES/fake-firecrawl-local.py" "$LOCAL/firecrawl-local"
cp "$FIXTURES/local-responses.json" "$LOCAL/local-responses.json"
chmod +x "$LOCAL/firecrawl-local"
local_control() {
  if [[ $# -gt 0 ]]; then printf '%s\n' "$1" >"$LOCAL/control.json"; else cat >"$LOCAL/control.json"; fi
  : >"$LOCAL/calls.jsonl"
  rm -f "$LOCAL/grandchild.pid"
}
local_check() {
  jcheck "$1" "$(python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in open(sys.argv[1])]))' "$LOCAL/calls.jsonl")" "r=d; $2"
}
local_none() { [[ ! -s "$LOCAL/calls.jsonl" ]] && ok || bad "$1: firecrawl-local ran"; }
slot_state() {
  python3 -c 'import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("free")
except OSError:
    print("held")' "$SLOTS/slot-0.lock"
}
SERVED='local: served by Firecrawl Local 0.1.1 (local-fetch); no credits spent'
export FIRECRAWL_CLI_LOCAL_BIN="$LOCAL/firecrawl-local"

# Served: the page is the scraper's data, no credit read, no vendor, no ledger entry,
# and nothing from the parent environment reaches the scraper (acceptance 2).
fixture scrape
local_control '{"first":"plain"}'
export FIRECRAWL_API_KEY=fc-local807parentkey FIRECRAWL_API_URL=https://api.firecrawl.dev \
  HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 ALL_PROXY=socks5://127.0.0.1:9 \
  NO_PROXY=example.com FIRECRAWL_CLOUD=auto FIRECRAWL_LOCAL_HOME=/nonexistent-807
run_cli fetch https://example.com/page --full --json
unset FIRECRAWL_API_KEY FIRECRAWL_API_URL HTTP_PROXY https_proxy ALL_PROXY NO_PROXY \
  FIRECRAWL_CLOUD FIRECRAWL_LOCAL_HOME
status_is 0 'local tier serves a plain page'
jcheck 'local page is the scraper data, ledger-free' "$OUT" "x=d['data']; assert 'PLAINMARKER' in x['markdown'] and x['metadata']['engine']=='local-fetch', x; assert d['credits_spent']==0, d; assert d['degraded']==['$SERVED'], d['degraded']"
no_calls 'a served page reads no credits and runs no vendor'
local_check 'version check, then one pass with Chrome hidden' "assert [x['pass'] for x in r]==['version','first'], r; assert r[1]['argv']==['scrape','https://example.com/page','--public-only','-f','markdown','--timeout','30000','-c','1'], r[1]['argv']"
# The stub's own Python adds LC_CTYPE=C.UTF-8 to a locale-less environment (PEP 538).
local_check 'scraper environment is built from nothing' "import os; e=r[1]['env']; assert e.pop('LC_CTYPE', 'C.UTF-8')=='C.UTF-8'; assert set(e)=={'PATH','HOME','TMPDIR','FIRECRAWL_CLOUD','FIRECRAWL_LOCAL_HOME','FIRECRAWL_CHROME_PATH'}, sorted(e); assert e['FIRECRAWL_CLOUD']=='off' and e['FIRECRAWL_CHROME_PATH'].endswith('/false'), e; assert e['HOME']==e['TMPDIR']==e['FIRECRAWL_LOCAL_HOME'] and os.path.dirname(e['HOME'])=='$TMP/home' and os.path.basename(e['HOME']).startswith('firecrawl-local-'), e; assert not os.path.exists(e['HOME']), 'scratch kept'"
run_cli budget --json
jcheck 'a served page leaves the ledger untouched' "$OUT" "assert not d['data']['reservations'] and d['data']['day_state']['spent']==0, d['data']"
local_control '{"first":"plain"}'
run_cli fetch https://example.com/page --full
status_is 0 'local plain output'
jcheck 'a local note keeps plain output plain' "$OUT" "assert 'PLAINMARKER' in d['markdown'] and 'ok' not in d, sorted(d)"

# Eligibility: URL, local formats only, no schema, question, userinfo, --cloud or off switch.
fixture scrape
local_control '{"first":"plain-all"}'
run_cli fetch https://example.com/page --format markdown,links,rawHtml,html --json
status_is 0 'every local format is eligible'
local_check 'requested formats pass through to -f' "assert r[1]['argv'][4]=='markdown,links,rawHtml,html', r[1]['argv']"
jcheck 'every requested format is in the served result' "$OUT" "x=d['data']; assert x['links']==[] and all(x[k] for k in ('markdown','rawHtml','html')), sorted(x); assert '$SERVED' in d['degraded'], d['degraded']"
no_calls 'local formats never reach the vendor'
fixture scrape
local_control '{"first":"plain"}'
run_cli fetch https://example.com/page --format markdown,links,rawHtml,html --json
status_is 0 'a result without rawHtml and html falls through'
jcheck 'missing formats are named in order' "$OUT" "assert d['degraded'][0]=='local: no rawHtml, html in the local result; ran on Firecrawl', d['degraded']"
for case in default summary cloud schema query userinfo off; do
  fixture scrape
  local_control '{"first":"plain"}'
  case "$case" in
    default) run_cli fetch https://example.com/page --json ;;
    summary) run_cli fetch https://example.com/page --format markdown,summary --json ;;
    cloud) run_cli fetch https://example.com/page --full --cloud --json ;;
    schema) run_cli fetch https://example.com/page --format json --schema '{"type":"object"}' --json ;;
    query) run_cli fetch https://example.com/page --full -Q title --json ;;
    userinfo) run_cli fetch https://user:pw@example.com/page --full --json ;;
    off)
      export FIRECRAWL_CLI_LOCAL=0
      run_cli fetch https://example.com/page --full --json
      unset FIRECRAWL_CLI_LOCAL ;;
  esac
  status_is 0 "ineligible $case fetch runs on the vendor"
  local_none "ineligible $case fetch"
  jcheck "ineligible $case carries no local note" "$OUT" "assert not any(n.startswith('local: ') for n in d['degraded'] or []), d['degraded']"
done

# A script-built page reruns in Chrome while a slot is free.
fixture scrape
local_control '{"first":"script-first","chrome":"script-chrome"}'
export FIRECRAWL_CHROME_PATH=/opt/chrome-807
run_cli fetch https://example.com/app --full --json
unset FIRECRAWL_CHROME_PATH
status_is 0 'script-built page served from Chrome'
jcheck 'chrome pass serves the built page' "$OUT" "assert 'SCRIPTMARKER' in d['data']['markdown'] and d['credits_spent']==0; assert d['degraded']==['local: served by Firecrawl Local 0.1.1 (local-browser); no credits spent'], d['degraded']"
no_calls 'a Chrome-served page never reaches the vendor'
local_check 'second pass forces the browser, with the operator Chrome only there' "assert [x['pass'] for x in r]==['version','first','chrome'], r; assert r[2]['argv']==r[1]['argv']+['--browser','always'], r[2]['argv']; assert r[1]['env']['FIRECRAWL_CHROME_PATH'].endswith('/false') and r[2]['env']['FIRECRAWL_CHROME_PATH']=='/opt/chrome-807', [r[1]['env'], r[2]['env']]"
run_cli budget --json
jcheck 'the slot lock file is all a Chrome pass leaves' "$OUT" "assert not d['data']['reservations'], d['data']"
[[ "$(slot_state)" == free ]] && ok || bad 'slot released after a Chrome pass'

# Acceptance 5: with the one slot held elsewhere, the script-built page goes to the
# ladder at once and a plain page is still served; a second slot lets Chrome run.
fixture scrape
mkdir -p "$SLOTS"
python3 - "$SLOTS/slot-0.lock" "$TMP/slot-held" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(120)
PY
HOLDER=$!
for _ in {1..200}; do [[ -e "$TMP/slot-held" ]] && break; sleep 0.05; done
local_control '{"first":"script-first","chrome":"script-chrome"}'
START=$SECONDS
run_cli fetch https://example.com/app --full --json
status_is 0 'busy slot falls through'
(( SECONDS - START < 10 )) && ok || bad 'busy slot waited for the holder'
jcheck 'busy slot runs on Firecrawl with a note' "$OUT" "assert d['data']['markdown']=='# Example', d['data']; assert d['degraded'][0]=='local: the page needs Chrome and all 1 local browser slot(s) are in use; ran on Firecrawl', d['degraded']; assert d['credits_spent']>=1, d"
local_check 'busy slot never starts Chrome' "assert [x['pass'] for x in r]==['version','first'], r"
argv_is 'busy slot ladder scrapes the same URL' "assert d[:2]==['scrape','https://example.com/app'], d"
local_control '{"first":"plain"}'
: >"$FIRECRAWL_TEST_LOG"
run_cli fetch https://example.com/page --full --json
jcheck 'plain page served while the slot is held' "$OUT" "assert d['degraded']==['$SERVED'], d['degraded']"
no_calls 'plain page with a held slot reaches no vendor'
export FIRECRAWL_CLI_LOCAL_BROWSER_SLOTS=2
local_control '{"first":"script-first","chrome":"script-chrome"}'
run_cli fetch https://example.com/app --full --json
unset FIRECRAWL_CLI_LOCAL_BROWSER_SLOTS
jcheck 'a second slot lets Chrome run' "$OUT" "assert 'SCRIPTMARKER' in d['data']['markdown'], d"
kill "$HOLDER"
wait "$HOLDER" 2>/dev/null

# Killing the wrapper mid-render does not free its slot while that render runs; the
# slot frees when the render exits.
fixture scrape
local_control '{"first":"script-first","chrome":{"case":"script-chrome","sleep":4}}'
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/bin" exec "$CLI" fetch https://example.com/app --full --json) >"$TMP/out" 2>"$TMP/err" &
WRAPPER=$!
for _ in {1..200}; do grep -q '"pass": "chrome"' "$LOCAL/calls.jsonl" 2>/dev/null && break; sleep 0.05; done
kill -9 "$WRAPPER"
wait "$WRAPPER" 2>/dev/null
RENDER=$(python3 -c 'import json,sys; print([json.loads(l) for l in open(sys.argv[1])][-1]["pid"])' "$LOCAL/calls.jsonl")
kill -0 "$RENDER" 2>/dev/null && ok || bad 'render ended with the wrapper (test cannot observe the slot)'
[[ "$(slot_state)" == held ]] && ok || bad 'slot freed while the killed wrapper render still runs'
for _ in {1..200}; do kill -0 "$RENDER" 2>/dev/null || break; sleep 0.05; done
[[ "$(slot_state)" == free ]] && ok || bad 'slot still held after the render exited'

# A pass past its timeout is killed with its whole group, stand-in browser included.
fixture scrape
local_control '{"first":{"case":"plain","sleep":60,"spawn":60}}'
run_cli fetch https://example.com/slow --full --timeout 1 --json
status_is 0 'timed-out local pass falls through'
jcheck 'timeout note' "$OUT" "assert d['degraded'][0]=='local: timed out after 1 s; ran on Firecrawl', d['degraded']; assert d['data']['markdown']=='# Example'"
local_check 'timeout pass asked the scraper for a 1 s timeout' "assert r[1]['argv'][5:7]==['--timeout','1000'], r[1]['argv']"
GRANDCHILD=$(cat "$LOCAL/grandchild.pid")
for _ in {1..100}; do kill -0 "$GRANDCHILD" 2>/dev/null || break; sleep 0.05; done
kill -0 "$GRANDCHILD" 2>/dev/null && bad 'timeout left the stand-in browser running' || ok

# Acceptance 1: each fall-through row runs the ladder keyed, charges it, and leads
# with its note.
while IFS='|' read -r spec note; do
  note=${note//LOCALBIN/$LOCAL/firecrawl-local}
  fixture scrape
  local_control "$spec"
  run_cli fetch https://example.com/page --full --json
  status_is 0 "fall-through $note"
  jcheck "fall-through note: $note" "$OUT" "n=d['degraded'][0]; assert n.startswith('local: $note') and n.endswith('; ran on Firecrawl'), d['degraded']; assert d['data']['markdown']=='# Example' and d['credits_spent']>=1 and 'cost estimated, not measured' in d['degraded'], d"
  argv_is "fall-through $note runs the vendor scrape" "assert d[:2]==['scrape','https://example.com/page'], d"
done <<'ROWS'
{"first":"blocked-403"}|the site did not serve the page to this machine (HTTP 403)
{"first":"notfound-404"}|the site answered HTTP 404
{"first":"empty-200"}|empty result
{"first":"redirect-loop"}|BLOCKED_TARGET: more than 10 redirects
{"first":"userinfo"}|BLOCKED_TARGET: URLs with embedded credentials are not fetched
{"first":"fetch-failed"}|FETCH_FAILED: error sending request for url
{"first":{"case":"plain","signal":9}}|stopped by signal 9
{"first":{"case":"plain","rc":3,"stdout":"not json"}}|unreadable output (exit 3)
{"first":{"case":"plain","stdout":"{\"success\":true,\"data\":{\"markdown\":\"x\",\"warning\":\"Something new.\",\"metadata\":{\"statusCode\":200}}}"}}|warning: Something new.
{"first":"script-first","chrome":"script-first"}|Chrome did not render it: This page builds its content with JavaScript
{"version":{"case":"version","stdout":"firecrawl-local 0.2.0\n"}}|LOCALBIN reports 0.2.0, the wrapper is pinned to 0.1.1
ROWS

# Private, local-name and metadata targets are refused, never sent to the cloud.
fixture scrape
local_control '{"first":"private"}'
run_cli fetch http://intranet.example/ --full --json
status_is 1 'private target refused'
jcheck 'private refusal names the guard and the --cloud rerun' "$OUT" "e=d['error']; assert e['code']=='local_blocked_target' and '127.0.0.1 is a private address' in e['message'] and 'never sent' in e['message'], e; assert '--cloud' in e['next_action'] and 'http://intranet.example/' in e['next_action'], e['next_action']"
no_calls 'a refused target reads no credits and runs no vendor'
fixture scrape
local_control '{"first":"plain","by_url":{"http://intranet.example/":"private"}}'
run_cli fetch http://intranet.example/ https://example.com/page --full --json
status_is 6 'private and public targets in one call'
jcheck 'the private item fails, the public item is served' "$OUT" "i=d['data']['items']; assert i[0]['ok'] is False and i[0]['error']['code']=='local_blocked_target' and i[0]['credits_spent']==0, i[0]; assert i[1]['ok'] and 'PLAINMARKER' in i[1]['data']['markdown'] and i[1]['credits_spent']==0, i[1]"
no_calls 'a mixed call reaches no vendor'

# Chrome's guard words a private name's refusal "'name' resolves to ..." (recorded in a
# network namespace): refused on the browser pass too, never sent to the cloud (#826 review).
for case in browser-private browser-metadata; do
  fixture scrape
  local_control "{\"first\":\"script-first\",\"chrome\":\"$case\"}"
  run_cli fetch https://example.com/page --full --json
  status_is 1 "$case: the browser pass's refusal is final"
  jcheck "$case: refused as a private target" "$OUT" "e=d['error']; assert e['code']=='local_blocked_target' and 'resolves to a' in e['message'] and 'never sent' in e['message'], e"
  no_calls "$case: no credit read, no vendor"
  local_check "$case: the refusal came from the Chrome pass" "assert [x['pass'] for x in r]==['version','first','chrome'], [x['pass'] for x in r]"
done
# Any other BLOCKED_TARGET is refused too unless it is one of the four whole messages
# that say nothing about where the target is; the host name in a refusal never counts.
while IFS='|' read -r label error; do
  fixture scrape
  local_control "$(python3 -c 'import json, sys
out = json.dumps({"success": False, "code": "BLOCKED_TARGET", "error": sys.argv[1]})
print(json.dumps({"first": {"case": "private", "stdout": out}}))' "$error")"
  run_cli fetch https://example.com/page --full --json
  status_is 1 "$label refused"
  jcheck "$label: local_blocked_target" "$OUT" "assert d['error']['code']=='local_blocked_target', d['error']"
  no_calls "$label: no vendor"
done <<'ROWS'
a host named like a passable refusal|'more-than-10-redirects.example' resolves to a private address; private targets are off
a refusal worded in a way the pin never printed|'intranet.example' is refused for a new reason
a passable refusal with more after it|URL has no host; 'db.example' resolves to a private address; private targets are off
ROWS
while IFS='|' read -r error; do
  fixture scrape
  local_control "$(python3 -c 'import json, sys
out = json.dumps({"success": False, "code": "BLOCKED_TARGET", "error": sys.argv[1]})
print(json.dumps({"first": {"case": "private", "stdout": out}}))' "$error")"
  run_cli fetch https://example.com/page --full --json
  status_is 0 "passable refusal falls through: $error"
  LOCAL_ERROR=$error jcheck "passable refusal note: $error" "$OUT" "import os; n=d['degraded'][0]; assert n=='local: BLOCKED_TARGET: '+os.environ['LOCAL_ERROR']+'; ran on Firecrawl', d['degraded']"
done <<'ROWS'
unsupported URL scheme 'ftp': only http and https are fetched
URL has no host
URLs with embedded credentials are not fetched
more than 10 redirects
ROWS

# An HTTP-200 bot check is flagged only from markdown, so an html-only fetch asks the
# scraper for markdown too and falls through on the flag (#826 review).
fixture scrape
local_control '{"first":"botcheck-200"}'
run_cli fetch https://example.com/page --format html --json
status_is 0 'html-only bot check runs on the cloud'
jcheck 'html-only bot check note' "$OUT" "assert d['degraded'][0]=='local: the site did not serve the page to this machine (HTTP 200); ran on Firecrawl', d['degraded']"
local_check 'html-only fetch asks the scraper for markdown as well' "assert r[1]['argv'][3:5]==['-f','html,markdown'], r[1]['argv']"
fixture scrape
local_control '{"first":"plain-html"}'
run_cli fetch https://example.com/page --format html --json
status_is 0 'html-only page served'
jcheck 'html-only page: html served, the extra markdown dropped' "$OUT" "x=d['data']; assert 'ALPHAMARKER' in x['html'] and 'markdown' not in x, sorted(x); assert '$SERVED' in d['degraded'] and d['credits_spent']==0, d"
no_calls 'html-only page served without a vendor call'
fixture scrape
local_control '{"first":"plain"}'
run_cli fetch https://example.com/page --full --json
local_check 'a markdown fetch asks only for markdown' "assert r[1]['argv'][3:5]==['-f','markdown'], r[1]['argv']"

# A result missing a requested format (a JSON page has no html, a PDF only markdown)
# runs on the cloud, which produces them all (#826 review).
fixture scrape
local_control '{"first":"json-markdown-html"}'
run_cli fetch https://example.com/page --format markdown,html --json
status_is 0 'missing html falls through'
jcheck 'missing html note' "$OUT" "assert d['degraded'][0]=='local: no html in the local result; ran on Firecrawl', d['degraded']; assert d['credits_spent']>=1, d"
argv_is 'missing html runs the vendor scrape' "assert d[:2]==['scrape','https://example.com/page'], d"
fixture scrape
local_control '{"first":"json-markdown-html"}'
run_cli fetch https://example.com/page --full --json
status_is 0 'the same page served when only markdown was asked for'
jcheck 'markdown-only JSON page served' "$OUT" "assert 'JSONMARKER' in d['data']['markdown'] and '$SERVED' in d['degraded'], d['degraded']"
no_calls 'markdown-only JSON page reaches no vendor'

# In a fan-out, a failed item's fall-through note still reaches the envelope (#807).
configure '{"default":{"fixture":"scrape.json"},"targets":{"https://example.com/refused":{"text":"{\"success\":false,\"error\":\"unsupported site\"}","exit":1}}}'
local_control '{"first":"plain","by_url":{"https://example.com/refused":"blocked-403"}}'
run_cli fetch https://example.com/page https://example.com/refused --full --json
status_is 6 'served item and a fall-through that fails on the cloud'
jcheck 'the failed item keeps its local note' "$OUT" "i=d['data']['items']; assert [v['ok'] for v in i]==[True,False], i; assert 'unsupported site' in i[1]['error']['message']; g=d['degraded']; assert '$SERVED' in g and 'local: the site did not serve the page to this machine (HTTP 403); ran on Firecrawl' in g, g"

# A ladder failure after a fall-through still carries the local note; keyless follows it.
configure '{"default":{"fixture":"quota.json","stderr_text":"HTTP 402","exit":1}}'
local_control '{"first":"blocked-403"}'
run_cli fetch https://example.com/page --full --json
status_is 1 'ladder failure after a local fall-through'
jcheck 'ladder error keeps the local note first' "$OUT" "assert d['error']['code']=='quota_exhausted' and d['degraded'][0].startswith('local: the site did not serve'), d"
export FIRECRAWL_CLI_KEYLESS=1
fixture scrape
local_control '{"first":"blocked-403"}'
run_cli fetch https://example.com/page --full --json
export FIRECRAWL_CLI_KEYLESS=0
status_is 0 'keyless leg after a local fall-through'
jcheck 'local note, then the keyless note' "$OUT" "g=d['degraded']; assert g[0].startswith('local: the site did not serve') and g[1].startswith('keyless: answered'), g; assert d['credits_spent']==0, d"

# The binary: a named path that is unusable is a note; not installed is silent;
# PATH and the cargo root are found.
fixture scrape
local_control '{"first":"plain"}'
export FIRECRAWL_CLI_LOCAL_BIN="$TMP/no-such-firecrawl-local"
run_cli fetch https://example.com/page --full --json
jcheck 'unusable named binary is a note' "$OUT" "assert d['degraded'][0]==\"local: FIRECRAWL_CLI_LOCAL_BIN '$TMP/no-such-firecrawl-local' is not an executable file; ran on Firecrawl\", d['degraded']"
unset FIRECRAWL_CLI_LOCAL_BIN
fixture scrape
run_cli fetch https://example.com/page --full --json
status_is 0 'no firecrawl-local installed'
local_none 'not installed'
jcheck 'not installed is silent' "$OUT" "assert d['degraded']==['cost estimated, not measured'], d['degraded']"
run_cli capabilities --json
jcheck 'capabilities: absent' "$OUT" "l=d['data']['local']; assert l['state']=='absent' and l['binary'] is None and l['pinned_version']=='0.1.1' and l['pinned_rev'].startswith('dc37f52f') and 'cargo install --locked --root ~/.local/share/firecrawl-local' in l['install'], l"
ln -s "$LOCAL/firecrawl-local" "$TMP/bin/firecrawl-local"
fixture scrape
local_control '{"first":"plain"}'
run_cli fetch https://example.com/page --full --json
jcheck 'found on PATH' "$OUT" "assert d['degraded']==['$SERVED'], d['degraded']"
rm "$TMP/bin/firecrawl-local"
mkdir -p "$TMP/home/.local/share/firecrawl-local/bin"
ln -s "$LOCAL/firecrawl-local" "$TMP/home/.local/share/firecrawl-local/bin/firecrawl-local"
fixture scrape
local_control '{"first":"plain"}'
run_cli fetch https://example.com/page --full --json
jcheck 'found in the cargo root' "$OUT" "assert d['degraded']==['$SERVED'], d['degraded']"
run_cli capabilities --json
jcheck 'capabilities: ready' "$OUT" "l=d['data']['local']; assert l['state']=='ready' and l['version']=='0.1.1' and l['binary']=='$TMP/home/.local/share/firecrawl-local/bin/firecrawl-local' and l['browser_slots']==1, l"
local_control '{"version":{"case":"version","stdout":"firecrawl-local 0.2.0\n"}}'
run_cli capabilities --json
jcheck 'capabilities: wrong version' "$OUT" "l=d['data']['local']; assert l['state']=='wrong_version' and l['version']=='0.2.0', l"
export FIRECRAWL_CLI_LOCAL=off
run_cli capabilities --json
unset FIRECRAWL_CLI_LOCAL
jcheck 'capabilities: off' "$OUT" "assert d['data']['local']['state']=='off', d['data']['local']"
rm -r "$TMP/home/.local"
run_cli fetch --help
contains "$OUT" '--cloud' 'fetch help names --cloud'
contains "$OUT" 'Firecrawl Local' 'fetch help names the local tier'
unset FIRECRAWL_CLI_LOCAL_BIN

printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
