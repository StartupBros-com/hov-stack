#!/usr/bin/env bash
# Tests for bin/exa.py: grammar, credentials, and the two verbs.
#
# Grammar/credentials coverage: --json accepted before or after the subcommand and resolving
# to the same parsed state (the gsc.py:267/271 defect class, KTD2); --timeout
# as a parent-only flag; the dfs-order credential chain (env -> bws ->
# ~/.secrets) bounded at EXA_BWS_TIMEOUT_SECONDS (a test-only override of the
# live 30s bound, R18); --where never leaking any part of the resolved key
# (R8); --version/--help resolving no credential at all (R17, AE7); and the
# argparse usage-error shapes for a missing subcommand or a missing query.
#
# Verb coverage: request-body assembly for both verbs, asserted from what the
# stub RECORDED, not from the CLI's own output -- the defect this guards is a
# misplaced field Exa would accept silently; the --json envelope and the
# contents `items[]`/exit-3 contract; the KTD5 error contract across HTTP,
# transport, and EXA_API_BASE-loopback failures.
#
# Hermetic: a scratch HOME per scenario, a fake `bws` on a private PATH that
# records its own invocations, a loopback HTTP stub serving fixtures under
# tests/fixtures/exa/, and EXA_API_KEY explicitly unset in the parent
# shell so nothing here reads the operator's real ~/.secrets, ~/.claude.json,
# or Bitwarden vault, and no real network call is ever made.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXA_PY="$REPO/bin/exa.py"
FIXTURES_DIR="$REPO/tests/fixtures/exa"
TMP=$(mktemp -d /tmp/exa-cli-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
unset EXA_API_KEY
unset EXA_API_BASE

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
contains() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) ok ;; *) bad "$label: missing '$needle'" ;; esac
}
omits() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) bad "$label: unexpectedly contained '$needle'" ;; *) ok ;; esac
}
status_is() {
  local actual=$1 expected=$2 label=$3
  [ "$actual" -eq "$expected" ] && ok || bad "$label: expected exit $expected, got $actual"
}
equals() {
  local actual=$1 expected=$2 label=$3
  [ "$actual" = "$expected" ] && ok || bad "$label: expected '$expected', got '$actual'"
}
# jcheck runs a python3 snippet against a JSON text over stdin; the snippet
# must print exactly OK on success (structural asserts read better in python
# than as chained bash substring checks, and this keeps every envelope assertion
# falsifiable against the actual parsed shape, not a lucky substring).
jcheck() {
  local label=$1 text=$2 code=$3
  local result
  result=$(printf '%s' "$text" | python3 -c "$code" 2>&1)
  [ "$result" = "OK" ] && ok || bad "$label: $result"
}

HOMEDIR=$TMP/home
FAKEBIN=$TMP/bin
CALLS=$TMP/bws-calls.log
mkdir -p "$HOMEDIR" "$FAKEBIN"
: >"$CALLS"

PY_DIR=$(dirname "$(command -v python3)")
NO_BWS_PATH="$PY_DIR:/usr/bin:/bin"
WITH_BWS_PATH="$FAKEBIN:$PY_DIR:/usr/bin:/bin"

reset_home() {
  rm -rf "$HOMEDIR"
  mkdir -p "$HOMEDIR"
  : >"$CALLS"
}

configure_bws_files() {
  mkdir -p "$HOMEDIR/.config/bws"
  printf 'fixture-token\n' >"$HOMEDIR/.config/bws/token"
  printf 'fixture-project\n' >"$HOMEDIR/.config/bws/sb-project-id"
}

write_secrets() {
  printf 'export EXA_API_KEY=%s\n' "$1" >"$HOMEDIR/.secrets"
}

make_bws_empty() {
  cat >"$FAKEBIN/bws" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
echo '[]'
EOF
  chmod +x "$FAKEBIN/bws"
}

make_bws_with_key() {
  local key=$1
  cat >"$FAKEBIN/bws" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
cat <<JSON
[{"key": "EXA_API_KEY", "value": "$key"}]
JSON
EOF
  chmod +x "$FAKEBIN/bws"
}

make_bws_sleep() {
  local seconds=$1
  cat >"$FAKEBIN/bws" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
sleep $seconds
echo '[]'
EOF
  chmod +x "$FAKEBIN/bws"
}

run_cli() {
  # $1 = PATH value; remaining = argv for exa.py. Sets $OUT (stdout+stderr), $ST.
  local pathval=$1
  shift
  OUT=$(HOME="$HOMEDIR" PATH="$pathval" timeout 10 python3 "$EXA_PY" "$@" 2>&1)
  ST=$?
}

run_cli_split() {
  # Same as run_cli but keeps stdout ($SOUT) and stderr ($SERR) separate.
  local pathval=$1
  shift
  SOUT=$(HOME="$HOMEDIR" PATH="$pathval" timeout 10 python3 "$EXA_PY" "$@" 2>"$TMP/stderr.txt")
  ST=$?
  SERR=$(cat "$TMP/stderr.txt")
}

# ── Loopback Exa stub: serves fixtures, records the request body, counts
# requests, and can sleep past a caller's --timeout. A one-line CONTROL file
# is re-read on every request so one long-lived background server can be
# steered scenario-to-scenario without a restart. ──────────────────────────
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
CONTROL="$STUB_DIR/control"
REQLOG="$STUB_DIR/request.json"
COUNTFILE="$STUB_DIR/count"
PORTFILE="$STUB_DIR/port"
echo 0 >"$COUNTFILE"
: >"$REQLOG"

STUB_SCRIPT="$TMP/exa-stub.py"
cat >"$STUB_SCRIPT" <<'PYEOF'
"""Loopback stub for exa-cli.test.sh (started by the test script; not run
standalone). Reads a one-line directive from CONTROL before each response:

  FIXTURE <filename>   serve the named fixture under FIXTURES_DIR; the
                        filename's leading digits, up to the first '-', are
                        the HTTP status to send.
  SLEEP <seconds>       sleep past the caller's timeout, then answer 200.
  REDIRECT <status> <location>   answer with a 3xx, a Location header, and
                        body {} -- proves the client does not chase it.

Records the last request body verbatim and a running request count so the
test script can assert on assembly and on "no second request was made".
"""
import http.server
import os
import sys
import time

FIXTURES_DIR, CONTROL, REQLOG, COUNTFILE, PORTFILE = sys.argv[1:6]


def load_fixture(name):
    status = int(name.split("-", 1)[0])
    with open(os.path.join(FIXTURES_DIR, name), "rb") as fh:
        return status, fh.read()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        with open(REQLOG, "wb") as fh:
            fh.write(body)
        count = int((open(COUNTFILE, encoding="utf-8").read() or "0").strip()) + 1
        with open(COUNTFILE, "w", encoding="utf-8") as fh:
            fh.write(str(count))

        directive = open(CONTROL, encoding="utf-8").read().strip()
        kind, _, rest = directive.partition(" ")
        location = None
        if kind == "SLEEP":
            time.sleep(float(rest))
            status, resp_body = 200, b"{}"
        elif kind == "REDIRECT":
            status_str, _, location = rest.partition(" ")
            status, resp_body = int(status_str), b"{}"
        else:
            status, resp_body = load_fixture(rest)

        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            if location:
                self.send_header("Location", location)
            self.end_headers()
            self.wfile.write(resp_body)
        except (BrokenPipeError, ConnectionResetError):
            # The SLEEP directive outlives the caller's --timeout on purpose;
            # the client has hung up by the time we answer. Not an error here.
            pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(PORTFILE, "w", encoding="utf-8") as fh:
    fh.write(str(server.server_port))
server.serve_forever()
PYEOF

python3 "$STUB_SCRIPT" "$FIXTURES_DIR" "$CONTROL" "$REQLOG" "$COUNTFILE" "$PORTFILE" &
STUB_PID=$!
trap 'kill "$STUB_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

for _ in $(seq 1 50); do
  [ -s "$PORTFILE" ] && break
  sleep 0.1
done
if [ ! -s "$PORTFILE" ]; then
  echo "FAIL: loopback stub did not start" >&2
  exit 1
fi
STUB_PORT=$(cat "$PORTFILE")
EXA_BASE="http://127.0.0.1:$STUB_PORT"
VERB_KEY="EXA_FIXTURE_verb_test_key"

set_fixture() { printf 'FIXTURE %s\n' "$1" >"$CONTROL"; }
set_sleep() { printf 'SLEEP %s\n' "$1" >"$CONTROL"; }
set_redirect() { printf 'REDIRECT %s %s\n' "$1" "$2" >"$CONTROL"; }
request_count() { cat "$COUNTFILE"; }

set_fixture 200-search-ok.json

run_verb() {
  # Same shape as run_cli, pointed at the stub with a fixture credential in
  # the environment so no bws/secrets path runs during verb tests.
  OUT=$(HOME="$HOMEDIR" PATH="$NO_BWS_PATH" EXA_API_BASE="$EXA_BASE" EXA_API_KEY="$VERB_KEY" timeout 10 python3 "$EXA_PY" "$@" 2>&1)
  ST=$?
}

run_verb_split() {
  SOUT=$(HOME="$HOMEDIR" PATH="$NO_BWS_PATH" EXA_API_BASE="$EXA_BASE" EXA_API_KEY="$VERB_KEY" timeout 10 python3 "$EXA_PY" "$@" 2>"$TMP/stderr.txt")
  ST=$?
  SERR=$(cat "$TMP/stderr.txt")
}

# ── --json before/after the subcommand: same parsed state (KTD2). Both
# positions must produce identical, valid envelope JSON from the real search
# handler. ───────────────────────────────────────────────────────────────────
reset_home
run_verb --json search foo
status_is "$ST" 0 "json-before: exits 0"
jcheck "json-before: parses as JSON with via" "$OUT" '
import json, sys
d = json.load(sys.stdin)
assert d["via"] == "exa/search", d
print("OK")'
BEFORE=$OUT

run_verb search foo --json
status_is "$ST" 0 "json-after: exits 0"
jcheck "json-after: parses as JSON with via" "$OUT" '
import json, sys
d = json.load(sys.stdin)
assert d["via"] == "exa/search", d
print("OK")'
equals "$OUT" "$BEFORE" "json before and after the subcommand yield the same parsed state"

# ── --timeout: parent-only, accepted before the subcommand and rejected
# after it (grammar only -- no credentials configured here, so a before-only
# acceptance is provable by reaching credential resolution instead of an
# argparse usage error, without needing the network stub) ───────────────────
reset_home
run_cli "$NO_BWS_PATH" --timeout 5 search foo
status_is "$ST" 1 "timeout-before: parses fine, fails only on missing credentials"
contains "$OUT" "No Exa credentials found" "timeout-before: reached credential resolution, not a usage error"

run_cli "$NO_BWS_PATH" search foo --timeout 5
status_is "$ST" 2 "timeout-after: parent-only flag exits 2"
contains "$OUT" "unrecognized arguments" "timeout-after: names the unrecognized flag"

# ── --timeout 0 / --timeout -1: rejected before any request (finding #3g) ───
reset_home
COUNT_BEFORE=$(request_count)
run_cli "$NO_BWS_PATH" --timeout 0 search foo
status_is "$ST" 2 "timeout-zero: exits 2"
contains "$OUT" "at least 1" "timeout-zero: names the minimum"
equals "$(request_count)" "$COUNT_BEFORE" "timeout-zero: no request sent"

COUNT_BEFORE=$(request_count)
run_cli "$NO_BWS_PATH" --timeout -1 search foo
status_is "$ST" 2 "timeout-negative: exits 2"
contains "$OUT" "at least 1" "timeout-negative: names the minimum"
equals "$(request_count)" "$COUNT_BEFORE" "timeout-negative: no request sent"

# ── AE1: env unset, bws empty, ~/.secrets carries the key -> --where prints ~/.secrets
reset_home
configure_bws_files
make_bws_empty
write_secrets "EXA_FIXTURE_zQ7mK9xP_TOKEN"
run_cli "$WITH_BWS_PATH" --where
status_is "$ST" 0 "AE1: --where exits 0"
# shellcheck disable=SC2088  # literal label exa.py prints, not a path to expand
equals "$OUT" "~/.secrets" "AE1: --where prints ~/.secrets"

# ── env set: --where prints env, fake bws never invoked ─────────────────────
reset_home
configure_bws_files
make_bws_with_key "EXA_FIXTURE_should_not_be_reached"
OUT=$(HOME="$HOMEDIR" PATH="$WITH_BWS_PATH" EXA_API_KEY="EXA_FIXTURE_env_key" timeout 10 python3 "$EXA_PY" --where 2>&1)
ST=$?
status_is "$ST" 0 "env-set: --where exits 0"
equals "$OUT" "env" "env-set: --where prints env"
CALLS_AFTER=$(cat "$CALLS")
equals "$CALLS_AFTER" "" "env-set: fake bws was never invoked"

# ── fake bws returns a secret: --where prints the bws source ────────────────
reset_home
configure_bws_files
make_bws_with_key "EXA_FIXTURE_bws_key"
run_cli "$WITH_BWS_PATH" --where
status_is "$ST" 0 "bws-source: --where exits 0"
equals "$OUT" "bws (EXA_API_KEY)" "bws-source: --where prints the bws source name"

# ── precedence: bws wins over ~/.secrets when BOTH resolve a key (finding #3b) ──
reset_home
configure_bws_files
make_bws_with_key "EXA_FIXTURE_precedence_bws"
write_secrets "EXA_FIXTURE_precedence_secrets"
run_cli "$WITH_BWS_PATH" --where
status_is "$ST" 0 "bws-precedence: --where exits 0"
equals "$OUT" "bws (EXA_API_KEY)" "bws-precedence: bws wins over ~/.secrets when both resolve"

# ── bws config files present but no bws binary on PATH: falls through to
# ~/.secrets (finding #3f) ───────────────────────────────────────────────────
reset_home
configure_bws_files
write_secrets "EXA_FIXTURE_fallback_no_binary"
run_cli "$NO_BWS_PATH" --where
status_is "$ST" 0 "bws-config-no-binary: --where exits 0"
# shellcheck disable=SC2088  # literal label exa.py prints, not a path to expand
equals "$OUT" "~/.secrets" "bws-config-no-binary: falls through when bws files exist but the binary is absent"

# ── quoted ~/.secrets values resolve (finding #3c) ───────────────────────────
reset_home
printf 'export EXA_API_KEY="EXA_FIXTURE_double_quoted"\n' >"$HOMEDIR/.secrets"
run_cli "$NO_BWS_PATH" --where
status_is "$ST" 0 "secrets-double-quoted: --where exits 0"
# shellcheck disable=SC2088  # literal label exa.py prints, not a path to expand
equals "$OUT" "~/.secrets" "secrets-double-quoted: resolves"

reset_home
printf "export EXA_API_KEY='EXA_FIXTURE_single_quoted'\n" >"$HOMEDIR/.secrets"
run_cli "$NO_BWS_PATH" --where
status_is "$ST" 0 "secrets-single-quoted: --where exits 0"
# shellcheck disable=SC2088  # literal label exa.py prints, not a path to expand
equals "$OUT" "~/.secrets" "secrets-single-quoted: resolves"

# ── no substring of the resolved key, from any source, longer than a couple chars ──
FIXTURE_KEY="EXA_FIXTURE_zQ7mK9xP_TOKEN"
FIXTURE_CHUNK="zQ7mK9xP"

reset_home
configure_bws_files
make_bws_empty
write_secrets "$FIXTURE_KEY"
run_cli "$WITH_BWS_PATH" --where
omits "$OUT" "$FIXTURE_KEY" "secrets-source: --where leaks no full key"
omits "$OUT" "$FIXTURE_CHUNK" "secrets-source: --where leaks no key chunk"

reset_home
configure_bws_files
make_bws_with_key "$FIXTURE_KEY"
run_cli "$WITH_BWS_PATH" --where
omits "$OUT" "$FIXTURE_KEY" "bws-source: --where leaks no full key"
omits "$OUT" "$FIXTURE_CHUNK" "bws-source: --where leaks no key chunk"

reset_home
configure_bws_files
make_bws_empty
OUT=$(HOME="$HOMEDIR" PATH="$WITH_BWS_PATH" EXA_API_KEY="$FIXTURE_KEY" timeout 10 python3 "$EXA_PY" --where 2>&1)
ST=$?
omits "$OUT" "$FIXTURE_KEY" "env-source: --where leaks no full key"
omits "$OUT" "$FIXTURE_CHUNK" "env-source: --where leaks no key chunk"

# ── no credential anywhere: exit 1, one line, names the three sources ───────
reset_home
configure_bws_files
make_bws_empty
run_cli "$WITH_BWS_PATH" --where
status_is "$ST" 1 "no-creds: --where exits 1"
contains "$OUT" "env" "no-creds: names env"
contains "$OUT" "bws" "no-creds: names bws"
# shellcheck disable=SC2088  # literal label exa.py prints, not a path to expand
contains "$OUT" "~/.secrets" "no-creds: names ~/.secrets"
LINES=$(printf '%s\n' "$OUT" | wc -l)
status_is "$LINES" 1 "no-creds: message is one line"

# ── same contract for the actual verbs, not just --where: no credential
# anywhere -> exit 1, empty stdout, one stderr line naming the three sources,
# no traceback (finding #3e) ─────────────────────────────────────────────────
reset_home
run_cli_split "$NO_BWS_PATH" search foo --json
status_is "$ST" 1 "no-creds-verb-search: exits 1"
equals "$SOUT" "" "no-creds-verb-search: stdout empty"
LINES=$(printf '%s\n' "$SERR" | wc -l)
status_is "$LINES" 1 "no-creds-verb-search: one stderr line"
contains "$SERR" "env" "no-creds-verb-search: names env"
contains "$SERR" "bws" "no-creds-verb-search: names bws"
# shellcheck disable=SC2088  # literal label exa.py prints, not a path to expand
contains "$SERR" "~/.secrets" "no-creds-verb-search: names ~/.secrets"
omits "$SERR" "Traceback" "no-creds-verb-search: no traceback"

reset_home
run_cli_split "$NO_BWS_PATH" contents https://x.example --json
status_is "$ST" 1 "no-creds-verb-contents: exits 1"
equals "$SOUT" "" "no-creds-verb-contents: stdout empty"
LINES=$(printf '%s\n' "$SERR" | wc -l)
status_is "$LINES" 1 "no-creds-verb-contents: one stderr line"
contains "$SERR" "env" "no-creds-verb-contents: names env"
contains "$SERR" "bws" "no-creds-verb-contents: names bws"
# shellcheck disable=SC2088  # literal label exa.py prints, not a path to expand
contains "$SERR" "~/.secrets" "no-creds-verb-contents: names ~/.secrets"
omits "$SERR" "Traceback" "no-creds-verb-contents: no traceback"

# ── fake bws sleeps past the bound: exit 1, names the timeout, bounded ──────
reset_home
configure_bws_files
BOUND=2
make_bws_sleep $((BOUND + 15))
START=$(date +%s)
OUT=$(HOME="$HOMEDIR" PATH="$WITH_BWS_PATH" EXA_BWS_TIMEOUT_SECONDS=$BOUND timeout 10 python3 "$EXA_PY" --where 2>&1)
ST=$?
END=$(date +%s)
ELAPSED=$((END - START))
status_is "$ST" 1 "bws-timeout: --where exits 1"
contains "$OUT" "bws" "bws-timeout: names bws"
contains "$OUT" "did not respond" "bws-timeout: names the timeout, not a plain not-found"
# date has 1s granularity; allow one extra second of slack on top of "bound + 1s".
[ "$ELAPSED" -le $((BOUND + 2)) ] && ok || bad "bws-timeout: took ${ELAPSED}s, expected within $((BOUND + 2))s of a ${BOUND}s bound"

# ── --where must never leak a traceback out of credential resolution
# (finding #2): a non-UTF-8 ~/.secrets file raises UnicodeDecodeError from
# _from_secrets_file's read() unless caught ─────────────────────────────────
reset_home
printf '\xff\xfe' >"$HOMEDIR/.secrets"
run_cli "$NO_BWS_PATH" --where
status_is "$ST" 1 "where-bad-utf8-secrets: exits 1"
omits "$OUT" "Traceback" "where-bad-utf8-secrets: no traceback"
contains "$OUT" "No Exa credentials found" "where-bad-utf8-secrets: falls through to the no-creds message"

# ── a non-UTF-8 bws token file raises from _from_bws's open().read() unless
# caught; falls through to ~/.secrets (finding #2) ──────────────────────────
reset_home
mkdir -p "$HOMEDIR/.config/bws"
printf '\xff\xfe' >"$HOMEDIR/.config/bws/token"
printf 'fixture-project\n' >"$HOMEDIR/.config/bws/sb-project-id"
write_secrets "EXA_FIXTURE_zQ7mK9xP_TOKEN"
run_cli "$NO_BWS_PATH" --where
status_is "$ST" 0 "where-bad-utf8-token-file: falls through to ~/.secrets"
# shellcheck disable=SC2088  # literal label exa.py prints, not a path to expand
equals "$OUT" "~/.secrets" "where-bad-utf8-token-file: --where prints ~/.secrets"
omits "$OUT" "Traceback" "where-bad-utf8-token-file: no traceback"

# ── a fake bws printing non-UTF-8 stdout must not raise out of
# subprocess.run(text=True) (finding #2); never a traceback, never leaks
# the fallback key ───────────────────────────────────────────────────────────
reset_home
configure_bws_files
cat >"$FAKEBIN/bws" <<'BEOF'
#!/usr/bin/env bash
printf '\xff\xfe garbled, not valid utf8'
BEOF
chmod +x "$FAKEBIN/bws"
write_secrets "EXA_FIXTURE_zQ7mK9xP_TOKEN"
run_cli "$WITH_BWS_PATH" --where
omits "$OUT" "Traceback" "where-bad-utf8-bws: no traceback"
omits "$OUT" "EXA_FIXTURE_zQ7mK9xP_TOKEN" "where-bad-utf8-bws: no full key leak"
omits "$OUT" "zQ7mK9xP" "where-bad-utf8-bws: no key chunk leak"
if [ "$ST" -eq 0 ] || [ "$ST" -eq 1 ]; then ok; else bad "where-bad-utf8-bws: expected exit 0 or 1 (never a crash), got $ST"; fi

# ── --version / --help: no credential resolution, no EXA_API_KEY, no bws, no ~/.secrets ──
reset_home
run_cli "$NO_BWS_PATH" --version
status_is "$ST" 0 "version: exits 0"
[[ "$OUT" =~ ^exa-cli\ [0-9]+\.[0-9]+\.[0-9]+$ ]] && ok || bad "version: '$OUT' does not match ^exa-cli N.N.N$"

run_cli "$NO_BWS_PATH" --help
status_is "$ST" 0 "help: exits 0"
contains "$OUT" "search" "help: lists the search subcommand"
contains "$OUT" "contents" "help: lists the contents subcommand"
contains "$OUT" "--where" "help: lists --where"
contains "$OUT" "--timeout" "help: lists --timeout"
contains "$OUT" "--json" "help: lists --json"

run_cli "$NO_BWS_PATH" search --help
status_is "$ST" 0 "search help: exits 0"
contains "$OUT" "--type" "search help: lists --type"
contains "$OUT" "--limit" "search help: lists --limit"
contains "$OUT" "--max-chars" "search help: lists --max-chars"

run_cli "$NO_BWS_PATH" contents --help
status_is "$ST" 0 "contents help: exits 0"
contains "$OUT" "--ids" "contents help: lists --ids"
contains "$OUT" "--max-age-hours" "contents help: lists --max-age-hours"

# ── no subcommand: exit 2, usage on stderr ───────────────────────────────────
run_cli_split "$NO_BWS_PATH"
status_is "$ST" 2 "no-subcommand: exits 2"
contains "$SERR" "usage" "no-subcommand: usage on stderr"
equals "$SOUT" "" "no-subcommand: stdout is empty"

# ── search with no query: exit 2 ─────────────────────────────────────────────
run_cli "$NO_BWS_PATH" search
status_is "$ST" 2 "search-no-query: exits 2"

# ══════════════════════════════════════════════════════════════════════════
# search/contents verbs, envelope, and error contract
# ══════════════════════════════════════════════════════════════════════════

# ── search default body assembly + envelope (KTD3, KTD4) ────────────────────
reset_home
set_fixture 200-search-ok.json
run_verb search foo --json
status_is "$ST" 0 "search-default: exits 0"
jcheck "search-default: recorded body shape" "$(cat "$REQLOG")" '
import json, sys
b = json.load(sys.stdin)
assert b == {"query": "foo", "type": "auto", "numResults": 10, "contents": {"highlights": True}}, b
print("OK")'
jcheck "search-default: envelope via/cost_usd/data" "$OUT" '
import json, sys
d = json.load(sys.stdin)
assert d["via"] == "exa/search", d
assert d["cost_usd"] == 0.005, d["cost_usd"]
assert isinstance(d["data"]["results"], list) and d["data"]["results"], d
print("OK")'

# ── --text --type fast --limit 3 --max-chars 500 (KTD3, R3, R20, R21) ───────
reset_home
set_fixture 200-search-ok.json
run_verb search foo --text --type fast --limit 3 --max-chars 500 --json
status_is "$ST" 0 "search-text: exits 0"
jcheck "search-text: recorded body shape" "$(cat "$REQLOG")" '
import json, sys
b = json.load(sys.stdin)
assert b == {"query": "foo", "type": "fast", "numResults": 3, "contents": {"text": {"maxCharacters": 500}}}, b
print("OK")'

# ── --limit 1 and --limit 100: both accepted at the boundary, recorded
# numResults matches exactly (finding #3d) ──────────────────────────────────
reset_home
set_fixture 200-search-ok.json
run_verb search foo --limit 1 --json
status_is "$ST" 0 "search-limit-1: exits 0"
jcheck "search-limit-1: recorded numResults 1" "$(cat "$REQLOG")" '
import json, sys
b = json.load(sys.stdin)
assert b["numResults"] == 1, b
print("OK")'

reset_home
set_fixture 200-search-ok.json
run_verb search foo --limit 100 --json
status_is "$ST" 0 "search-limit-100: exits 0"
jcheck "search-limit-100: recorded numResults 100" "$(cat "$REQLOG")" '
import json, sys
b = json.load(sys.stdin)
assert b["numResults"] == 100, b
print("OK")'

# ── non-JSON search output: the numbered title/url/snippet lines
# _print_search_summary prints (finding #3a) ─────────────────────────────────
reset_home
set_fixture 200-search-ok.json
run_verb search foo
status_is "$ST" 0 "search-summary-text: exits 0"
contains "$OUT" "1. Example Result One" "search-summary-text: first title line"
contains "$OUT" "https://one.example/page" "search-summary-text: first url line"
contains "$OUT" "First highlight snippet." "search-summary-text: first snippet line"
contains "$OUT" "2. Example Result Two" "search-summary-text: second title line"

# ── non-JSON contents output: the [ok|FAIL] id (cached|crawled) -- TAG lines
# _print_contents_summary prints (finding #3a) ───────────────────────────────
reset_home
set_fixture 200-contents-mixed.json
run_verb contents https://a.example https://b.example https://c.example
status_is "$ST" 0 "contents-summary-text: exits 0 (at least one success)"
contains "$OUT" "[ok] https://a.example (crawled)" "contents-summary-text: crawled success line"
contains "$OUT" "[ok] https://b.example (cached)" "contents-summary-text: cached success line"
contains "$OUT" "[FAIL] https://c.example (crawled) -- CRAWL_NOT_FOUND" "contents-summary-text: error line with tag"

# ── zero-result search prints "No results." (finding #3a) ───────────────────
reset_home
set_fixture 200-search-zero-results.json
run_verb search foo
status_is "$ST" 0 "search-summary-zero: exits 0"
equals "$OUT" "No results." "search-summary-zero: prints No results."

# ── all-error batch without --json: [FAIL] lines on stdout, exit 3 (finding #3a) ──
reset_home
set_fixture 200-contents-all-error.json
run_verb contents https://a.example https://b.example
status_is "$ST" 3 "contents-summary-all-error: exits 3"
contains "$OUT" "[FAIL] https://a.example" "contents-summary-all-error: first FAIL line"
contains "$OUT" "[FAIL] https://b.example" "contents-summary-all-error: second FAIL line"
set_fixture 200-search-ok.json

# ── --type neural: exit 2 before any request, names the six accepted values ──
reset_home
COUNT_BEFORE=$(request_count)
run_verb search foo --type neural
status_is "$ST" 2 "search-bad-type: exits 2"
contains "$OUT" "instant" "search-bad-type: names instant"
contains "$OUT" "deep-reasoning" "search-bad-type: names deep-reasoning"
equals "$(request_count)" "$COUNT_BEFORE" "search-bad-type: no request sent"

# ── --limit 0 / --limit 101: exit 2 before any request, naming the range ────
reset_home
COUNT_BEFORE=$(request_count)
run_verb search foo --limit 0
status_is "$ST" 2 "search-limit-0: exits 2"
contains "$OUT" "between 1 and 100" "search-limit-0: names the 1-100 range"
equals "$(request_count)" "$COUNT_BEFORE" "search-limit-0: no request sent"

COUNT_BEFORE=$(request_count)
run_verb search foo --limit 101
status_is "$ST" 2 "search-limit-101: exits 2"
contains "$OUT" "between 1 and 100" "search-limit-101: names the 1-100 range"
equals "$(request_count)" "$COUNT_BEFORE" "search-limit-101: no request sent"

# ── contents flat body: urls[], maxAgeHours at root, no "contents" key ──────
reset_home
set_fixture 200-contents-basic.json
run_verb contents https://a.example https://b.example --max-age-hours -1 --json
status_is "$ST" 0 "contents-flat: exits 0"
jcheck "contents-flat: recorded body shape" "$(cat "$REQLOG")" '
import json, sys
b = json.load(sys.stdin)
assert b == {"urls": ["https://a.example", "https://b.example"], "highlights": True, "maxAgeHours": -1}, b
print("OK")'

# ── contents --ids: ids[] not urls[] (KTD3 -- shape never sniffed) ──────────
reset_home
set_fixture 200-contents-basic.json
run_verb contents --ids abc123 def456 --json
status_is "$ST" 0 "contents-ids: exits 0"
jcheck "contents-ids: recorded body has ids not urls" "$(cat "$REQLOG")" '
import json, sys
b = json.load(sys.stdin)
assert b == {"ids": ["abc123", "def456"], "highlights": True}, b
print("OK")'

# ── AE2 mixed batch: crawled success, cached success, error 404 -> three
# items in request order, exit 0 (at least one succeeded) ───────────────────
reset_home
set_fixture 200-contents-mixed.json
run_verb contents https://a.example https://b.example https://c.example --json
status_is "$ST" 0 "contents-mixed: exits 0 (at least one success)"
jcheck "contents-mixed: three items in order" "$OUT" '
import json, sys
d = json.load(sys.stdin)
items = d["items"]
assert len(items) == 3, items
assert items[0]["status"] == "success" and items[0]["cached"] is False, items[0]
assert items[0]["tag"] is None and items[0]["http_status"] is None, items[0]
assert items[1]["status"] == "success" and items[1]["cached"] is True, items[1]
assert items[1]["tag"] is None and items[1]["http_status"] is None, items[1]
assert items[2]["status"] == "error" and items[2]["cached"] is False, items[2]
assert items[2]["tag"] == "CRAWL_NOT_FOUND" and items[2]["http_status"] == 404, items[2]
print("OK")'

# ── AE2 cache-only single uncached page: item error, exit 3, no second request ──
reset_home
set_fixture 200-contents-cache-miss.json
COUNT_BEFORE=$(request_count)
run_verb contents https://uncached.example --max-age-hours -1 --json
status_is "$ST" 3 "contents-cache-miss: exits 3 (no item succeeded)"
jcheck "contents-cache-miss: single error item" "$OUT" '
import json, sys
d = json.load(sys.stdin)
assert len(d["items"]) == 1, d["items"]
assert d["items"][0]["status"] == "error", d["items"][0]
print("OK")'
equals "$(request_count)" "$((COUNT_BEFORE + 1))" "contents-cache-miss: exactly one request, no retry"

# ── all-error two-URL batch: exit 3, one JSON object, both items error ──────
reset_home
set_fixture 200-contents-all-error.json
run_verb contents https://a.example https://b.example --json
status_is "$ST" 3 "contents-all-error: exits 3"
jcheck "contents-all-error: two error items" "$OUT" '
import json, sys
d = json.load(sys.stdin)
assert len(d["items"]) == 2, d["items"]
assert all(i["status"] == "error" for i in d["items"]), d["items"]
assert isinstance(d["data"], dict), d
print("OK")'

# ── AE6: 402 for each tag -> distinct error text, http_status 402, request_id
# from the body, exit 1, stderr empty under --json ──────────────────────────
MSGS=()
TAGS=(NO_MORE_CREDITS API_KEY_BUDGET_EXCEEDED TEAM_BUDGET_EXCEEDED)
FILES=(402-no-more-credits.json 402-api-key-budget.json 402-team-budget.json)
for i in 0 1 2; do
  reset_home
  set_fixture "${FILES[$i]}"
  run_verb_split search foo --json
  status_is "$ST" 1 "402-${TAGS[$i]}: exits 1"
  equals "$SERR" "" "402-${TAGS[$i]}: stderr empty under --json"
  jcheck "402-${TAGS[$i]}: json error shape" "$SOUT" "
import json, sys
d = json.load(sys.stdin)
assert d['http_status'] == 402, d
assert d['tag'] == '${TAGS[$i]}', d
assert d['request_id'], d
assert d['error'], d
print('OK')"
  MSGS+=("$(printf '%s' "$SOUT" | python3 -c 'import json, sys; print(json.load(sys.stdin)["error"])')")
done
if [ "${MSGS[0]}" != "${MSGS[1]}" ] && [ "${MSGS[1]}" != "${MSGS[2]}" ] && [ "${MSGS[0]}" != "${MSGS[2]}" ]; then
  ok
else
  bad "402: remediation text must differ per tag, got: ${MSGS[*]}"
fi

# ── AE6: 429 with a body carrying no tag -> tag/request_id null, no traceback ──
reset_home
set_fixture 429-rate-limited.json
run_verb_split search foo --json
status_is "$ST" 1 "429: exits 1"
equals "$SERR" "" "429: stderr empty under --json"
jcheck "429: tag and request_id null" "$SOUT" '
import json, sys
d = json.load(sys.stdin)
assert d["http_status"] == 429, d
assert d["tag"] is None, d
assert d["request_id"] is None, d
assert d["error"], d
print("OK")'

# ── 502 HTML gateway body and 500 truncated JSON body: each yields a JSON
# error with the status, tag null, no traceback ──────────────────────────────
for name in 502-gateway.html 500-truncated.json; do
  reset_home
  set_fixture "$name"
  run_verb_split search foo --json
  status_is "$ST" 1 "$name: exits 1"
  equals "$SERR" "" "$name: stderr empty under --json"
  jcheck "$name: tag null, http_status carried" "$SOUT" "
import json, sys
d = json.load(sys.stdin)
assert d['tag'] is None, d
assert d['http_status'] in (502, 500), d
assert d['error'], d
print('OK')"
done

# ── 2xx with an unparseable body: no HTTPError was raised (status is fine),
# so this is a distinct branch from the HTTP/transport error paths (finding
# #5) -- must not be swallowed as a generic transport failure ──────────────
reset_home
set_fixture 200-search-garbled.txt
run_verb_split search foo --json
status_is "$ST" 1 "garbled-200: exits 1"
equals "$SERR" "" "garbled-200: stderr empty under --json"
jcheck "garbled-200: unparseable-body error, http_status 200, tag null" "$SOUT" '
import json, sys
d = json.load(sys.stdin)
assert d["http_status"] == 200, d
assert d["tag"] is None, d
assert "unparseable" in d["error"].lower(), d["error"]
print("OK")'

# ── 2xx body that parses but is not an object (a bare array): same contract
# (finding #5) -- closes the gap where _cost_usd/.get would otherwise see a
# list ───────────────────────────────────────────────────────────────────────
reset_home
set_fixture 200-search-non-object.json
run_verb_split search foo --json
status_is "$ST" 1 "non-object-200: exits 1"
equals "$SERR" "" "non-object-200: stderr empty under --json"
jcheck "non-object-200: non-object-body error, http_status 200, tag null" "$SOUT" '
import json, sys
d = json.load(sys.stdin)
assert d["http_status"] == 200, d
assert d["tag"] is None, d
assert "non-object" in d["error"].lower(), d["error"]
print("OK")'

# ── contents 2xx with results but no statuses[]: empty items, exit 3, one
# JSON object (finding #5) ───────────────────────────────────────────────────
reset_home
set_fixture 200-contents-no-statuses.json
run_verb contents https://a.example --json
status_is "$ST" 3 "contents-no-statuses: exits 3"
jcheck "contents-no-statuses: empty items array" "$OUT" '
import json, sys
d = json.load(sys.stdin)
assert d["items"] == [], d["items"]
assert isinstance(d["data"], dict), d
print("OK")'
set_fixture 200-search-ok.json

# ── 401: names an invalid key and the resolved source, never the key ────────
reset_home
set_fixture 401-invalid-key.json
run_verb search foo --json
status_is "$ST" 1 "401: exits 1"
jcheck "401: names the resolved source" "$OUT" '
import json, sys
d = json.load(sys.stdin)
assert d["http_status"] == 401, d
assert "env" in d["error"], d["error"]
print("OK")'
omits "$OUT" "$VERB_KEY" "401: never leaks the resolved key"

# ── redirect: a 3xx with a Location off the stub must NOT be followed with
# credentials (finding #1) -- renders as a JSON error naming the refusal
# instead of a transport error from chasing the Location ───────────────────
reset_home
set_redirect 302 "http://127.0.0.1:1/elsewhere"
COUNT_BEFORE=$(request_count)
run_verb_split search foo --json
status_is "$ST" 1 "redirect-302: exits 1"
equals "$SERR" "" "redirect-302: stderr empty under --json"
jcheck "redirect-302: json error shape, names the refusal" "$SOUT" '
import json, sys
d = json.load(sys.stdin)
assert d["http_status"] == 302, d
assert d["tag"] is None, d
assert "redirect" in d["error"].lower(), d["error"]
print("OK")'
equals "$(request_count)" "$((COUNT_BEFORE + 1))" "redirect-302: stub recorded exactly one request, no follow"
set_fixture 200-search-ok.json

# ── same 402 case WITHOUT --json: one stderr line, empty stdout, exit 1 ─────
reset_home
set_fixture 402-no-more-credits.json
run_verb_split search foo
status_is "$ST" 1 "402-no-json: exits 1"
equals "$SOUT" "" "402-no-json: stdout empty"
LINES=$(printf '%s\n' "$SERR" | wc -l)
status_is "$LINES" 1 "402-no-json: one stderr line"

# ── stub sleeping past --timeout 1: JSON error, http_status null, within ~2s ──
reset_home
set_sleep 5
START=$(date +%s)
run_verb_split --timeout 1 search foo --json
END=$(date +%s)
status_is "$ST" 1 "timeout: exits 1"
[ "$((END - START))" -le 2 ] && ok || bad "timeout: took $((END - START))s, expected within ~2s"
jcheck "timeout: http_status null, names the timeout" "$SOUT" '
import json, sys
d = json.load(sys.stdin)
assert d["http_status"] is None, d
assert "time" in d["error"].lower(), d["error"]
print("OK")'
set_fixture 200-search-ok.json

# ── EXA_API_BASE non-loopback: exit 1 before any credential is read (bws
# records zero calls) and before any request (KTD11) ────────────────────────
reset_home
configure_bws_files
make_bws_with_key "EXA_FIXTURE_should_not_be_reached_either"
COUNT_BEFORE=$(request_count)
OUT=$(HOME="$HOMEDIR" PATH="$WITH_BWS_PATH" EXA_API_BASE="http://example.com" timeout 10 python3 "$EXA_PY" search foo --json 2>&1)
ST=$?
status_is "$ST" 1 "base-non-loopback: exits 1"
contains "$OUT" "loopback" "base-non-loopback: names the loopback rule"
CALLS_AFTER=$(cat "$CALLS")
equals "$CALLS_AFTER" "" "base-non-loopback: bws never invoked"
equals "$(request_count)" "$COUNT_BEFORE" "base-non-loopback: stub never contacted"

# ── EXA_API_BASE lookalike host (127.0.0.1.evil.com): exact hostname match
# rejects it, not a substring match ──────────────────────────────────────────
reset_home
COUNT_BEFORE=$(request_count)
OUT=$(HOME="$HOMEDIR" PATH="$NO_BWS_PATH" EXA_API_BASE="http://127.0.0.1.evil.com:1/" timeout 10 python3 "$EXA_PY" search foo --json 2>&1)
ST=$?
status_is "$ST" 1 "base-lookalike: exits 1"
contains "$OUT" "loopback" "base-lookalike: names the loopback rule"
equals "$(request_count)" "$COUNT_BEFORE" "base-lookalike: stub never contacted"

# ── 200 without costDollars: cost_usd null, exit 0 ───────────────────────────
reset_home
set_fixture 200-search-no-cost.json
run_verb search foo --json
status_is "$ST" 0 "no-cost: exits 0"
jcheck "no-cost: cost_usd null" "$OUT" '
import json, sys
d = json.load(sys.stdin)
assert d["cost_usd"] is None, d
print("OK")'

# ── resolvedSearchType / highlightScores: ignored, no failure ───────────────
reset_home
set_fixture 200-search-extra-fields.json
run_verb search foo --json
status_is "$ST" 0 "extra-fields: exits 0 despite unrecognized response fields"

# ── zero-result search: exit 0, empty results array ──────────────────────────
reset_home
set_fixture 200-search-zero-results.json
run_verb search foo --json
status_is "$ST" 0 "zero-results: exits 0"
jcheck "zero-results: empty results array" "$OUT" '
import json, sys
d = json.load(sys.stdin)
assert d["data"]["results"] == [], d["data"]["results"]
print("OK")'

echo "exa-cli: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
