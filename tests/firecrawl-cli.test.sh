#!/usr/bin/env bash
# U1/U2/U3/U4/U5 contract tests. Private PATH contains only the fake vendor and shim tools.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$REPO/bin/firecrawl-cli"
MODULE="$REPO/bin/firecrawl_cli.py"
FIXTURES="$REPO/tests/fixtures/firecrawl-cli"
TMP=$(mktemp -d /tmp/firecrawl-cli-test.XXXXXX)
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
export PYTHONDONTWRITEBYTECODE=1
python3 - "$FIXTURES/responses.json" "$TMP/fixtures" <<'PY'
import json, pathlib, sys
for name, data in json.loads(pathlib.Path(sys.argv[1]).read_text()).items():
    pathlib.Path(sys.argv[2], name + '.json').write_text(json.dumps(data))
PY
cp "$FIXTURES/usage.txt" "$TMP/fixtures/usage.txt"

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

# Date-valued Retry-After and shell quoting are deterministic without a provider.
RESULT=$(PYTHONDONTWRITEBYTECODE=1 python3 - "$MODULE" "$TMP/bin" "$TMP/work" <<'PY'
import importlib.util, subprocess, sys
from email.utils import formatdate
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('firecrawl_cli', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
with patch.object(m.time, 'time', return_value=1000):
    assert m.error_metadata({'details': {'headers': {'Retry-After': formatdate(1090, usegmt=True)}}}, '') == (None, 90)
for value in ('nonsense', 'NaN', '-2', 'Infinity'):
    assert m.error_metadata({'headers': {'Retry-After': value}}, '') == (None, 5)
assert m.error_metadata({'error': 'Request failed with status code 402'}, '') == (402, 5)
assert m.error_metadata({'data': {'markdown': 'HTTP 402'}}, '') == (None, 5)
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
jcheck 'capabilities verbs and exits' "$OUT" "c=d['data']; assert set(c['verbs'])=={'fetch','extract','shot','act','agent','interact','search','map','raw','capabilities','budget'}; assert set(c['exit_codes'])==set(map(str,range(7))); assert all(isinstance(v['retryable'],bool) for v in c['exit_codes'].values()); assert c['exit_codes']['2']['retryable']; assert all('flags' in v and 'cost_class' in v for v in c['verbs'].values()); assert '--schema' in c['verbs']['fetch']['flags']; assert 'limits' in c; assert 'monitor' in str(c['warnings']) and 'crawl' in str(c['warnings'])"
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
RO_HOME=$(mktemp -d "$TMP/ro-home.XXXXXX")
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
contains "$OUT" 'after the verb' 'canonical JSON placement'
contains "$OUT" 'cron callers must alert' 'AE16 unattended budget advice'
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

# No vendor on PATH: offline still works; paid verb teaches mise location.
ST=0
HOME="$TMP/home" PATH="$TMP/no-vendor" "$CLI" fetch https://x --json >"$TMP/out" 2>"$TMP/err" || ST=$?
status_is 4 'missing vendor'
# shellcheck disable=SC2088 # The CLI deliberately names the portable mise path.
contains "$(cat "$TMP/err")" '~/.local/share/mise/installs/node/<version>/bin/firecrawl' 'mise remedy'

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
fixture scrape-json
run_cli extract https://x -Q 'What is the title?' --json
status_is 0 'extract prompt'
argv_is 'extract prompt argv' "assert d==['scrape','https://x','--only-main-content','--query','What is the title?','--json']"
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
contains "$ERR" 'firecrawl-cli raw -- crawl' 'raw-only remedy'

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
jcheck 'injection limitation' "$OUT" "assert d['data']['injection_check']=='unavailable through the vendor CLI v1.19.26; the API json-format option is not exposed'"
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

configure '{"default":{"text":"research local help\n"}}'
ST=0
(cd "$TMP/work" && HOME="$TMP/home" PATH="$TMP/no-vendor" "$CLI" raw --json -- research --help) >"$TMP/out" 2>"$TMP/err" || ST=$?
OUT=$(cat "$TMP/out") ERR=$(cat "$TMP/err")
status_is 4 'research help without vendor is a normal missing-vendor error'
jcheck 'missing research vendor envelope' "$OUT" "assert not d['ok'] and d['error']['code']==4 and d['credits_spent']==0 and d['credits_remaining'] is None"
contains "$ERR" 'vendor firecrawl is missing from PATH' 'research help missing vendor detail'
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
for candidate in question prompt extra-command extra-flag unknown short-help equals-help reordered-help redundant-separator ordinary; do
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
jcheck 'AE13 documented estimate' "$OUT" "assert d['credits_spent']==1; assert d['credits_remaining']==1000; assert d['budget_remaining']==299; assert 'cost estimated, not measured' in d['degraded']"
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
jcheck 'floor reads remaining rather than period total' "$(error_json)" "assert d['credits_remaining']==1000 and d['budget_remaining']==300 and d['credits_spent']==0"
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
jcheck 'refusal accounting envelope' "$(error_json)" "assert d['credits_spent']==0 and d['credits_remaining']==1000 and d['budget_remaining']==1"
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
jcheck 'capabilities contract additions' "$OUT" "c=d['data']; assert {'.pdf','.docx','.xlsx'} <= set(c['parse_extensions']); assert c['verbs']['interact']['cost_class']=='interact_per_minute' and c['verbs']['extract']['cost_class']=='json_extraction'; assert 'json_extraction' in c['verbs']['fetch']['cost_classes']; assert all(v['cost_class'] in c['budget'] or v['cost_class'] in {'offline','raw-unknown','scrape','map','search'} for v in c['verbs'].values()); assert any('error.code' in w for w in c['warnings'])"
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
run_cli search 'example query' --categories github,pdf --sources web,news --tbs qdr:w --limit 3 --json
status_is 0 'search filters accepted'
argv_is 'search filters forwarded' "assert d==['search','example query','--limit','3','--categories','github,pdf','--sources','web,news','--tbs','qdr:w','--json'], d"
jcheck 'search_id and measured cost' "$OUT" "assert d['ok'] and d['search_id']=='srch_fixture_1' and d['credits_spent']==2 and d['degraded'] is None"
fixture search-id
run_cli search 'example query' --location Germany --json
status_is 0 'search location accepted'
argv_is 'location forwarded to the vendor' "assert d[d.index('--location')+1]=='Germany', d"
fixture search
run_cli search 'example query' --json
jcheck 'no search_id without a vendor id' "$OUT" "assert 'search_id' not in d and d['ok']"
for bad in '--categories github,bogus' '--categories github,github' '--sources rss' '--tbs qdr:x' '--tbs yesterday'; do
  fixture search-id
  # shellcheck disable=SC2086
  run_cli search 'example query' $bad --json
  status_is 4 "search filter refused: $bad"
  no_calls "search filter refused before the vendor: $bad"
done
run_cli search 'example query' --categories '' --json
status_is 4 'empty categories refused'
contains "$ERR" 'valid categories: github, research, pdf, developer' 'category list named'
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
jcheck 'capabilities search and format contract' "$OUT" "c=d['data']; assert c['search_categories']==['github','research','pdf','developer'] and c['api_only_categories']==['developer']; assert c['search_sources']==['web','images','news'] and c['search_tbs'][0]=='qdr:h'; assert 'site:host' in c['search_operators']; assert 'changeTracking' in c['fetch_formats']['scrape'] and 'changeTracking' not in c['fetch_formats']['parse']; assert {'--categories','--sources','--tbs'} <= set(c['verbs']['search']['flags']); assert {'--max-age','--format'} <= set(c['verbs']['fetch']['flags']); assert any('search_id' in w for w in c['warnings']) and any('--max-age 0' in w for w in c['warnings'])"
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
API_KEY='diagnostic-marker-not-fc-shaped-99182736'
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
run_api search 'example query' --categories github,developer --sources news --tbs qdr:d
status_is 0 'mixed categories go to the API without --json'
api_request 'mixed request carries every filter' "assert d['body']=={'query':'example query','categories':['github','developer'],'sources':[{'type':'news'}],'tbs':'qdr:d'}"
jcheck 'bare developer output is the vendor payload' "$OUT" "assert d['id']=='srch_dev_1' and 'ok' not in d"
fixture search-dev
api_control "{\"status\":200,\"body\":$(cat "$TMP/fixtures/search-dev.json")}"
run_api search 'example query' --categories github,developer --location Germany --json
status_is 0 'mixed categories with --json'
jcheck 'mixed categories envelope' "$OUT" "assert d['ok'] and d['surface']=='search' and d['search_id']=='srch_dev_1' and d['credits_spent']==2"
api_request 'location reaches the API body' "assert d['body']['location']=='Germany' and d['body']['categories']==['github','developer']"
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
contains "$ERR" 'research search-github' 'missing key alternative named'
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
run_api search 'example query' --categories github --json
status_is 0 'github category stays on the vendor CLI'
argv_is 'github category forwarded to the vendor' "assert d[:2]==['search','example query'] and d[d.index('--categories')+1]=='github'"
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

printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
