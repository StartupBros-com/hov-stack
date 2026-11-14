#!/usr/bin/env bash
# supabase-migration-list.test.sh: the remote-history parse both remote reads in
# migration-apply.sh share (scripts/lib/supabase-migration-list.sh).
#
# WHY THIS EXISTS: Supabase CLI v2.122.0 changed `supabase migration list
# --linked` under the script. Its table now wraps every cell in backticks, so
# the old awk parse read zero versions from a valid listing, and it prints JSON
# instead whenever CLAUDECODE or AI_AGENT is set. migration-apply.sh stopped at
# preflight for every app (#366). It now asks for --output-format json and
# parses it through this helper.
#
# The helper runs over the vendor's real bytes
# (fixtures/supabase-migration-list/, captured from v2.122.0) and edge rows.
# migration-apply-prewrite-gates.test.sh covers the two call sites.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB="$HERE/scripts/lib/supabase-migration-list.sh"
FIX="$HERE/tests/fixtures/supabase-migration-list"
TMP=$(mktemp -d) || exit 1
[ -n "$TMP" ] && [ -d "$TMP" ] || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0 failed=0
ck_eq() {
  if [ "$2" = "$3" ]; then pass=$((pass + 1))
  else failed=$((failed + 1)); printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$1" "$2" "$3"; fi
}
ck_has() {
  if grep -qF -- "$3" <<<"$2"; then pass=$((pass + 1))
  else failed=$((failed + 1)); printf 'FAIL: %s\n  wanted: %s\n  in: %s\n' "$1" "$3" "$2"; fi
}
ck_not() {
  if grep -qF -- "$3" <<<"$2"; then failed=$((failed + 1)); printf 'FAIL: %s\n  did not want: %s\n  in: %s\n' "$1" "$3" "$2"
  else pass=$((pass + 1)); fi
}

for f in "$LIB" "$FIX/v2.122.0.json" "$FIX/v2.122.0-table.txt" "$FIX/v2.122.0-error.json"; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done
# shellcheck source=../scripts/lib/supabase-migration-list.sh
. "$LIB"

# parse INPUT -> sets OUT, ERR, RC.
parse() {
  RC=0
  OUT=$(printf '%s' "$1" | supabase_remote_versions 2>"$TMP/parse.err") || RC=$?
  ERR=$(<"$TMP/parse.err")
}

parse "$(<"$FIX/v2.122.0.json")"
ck_eq "vendor JSON: exit 0" "$RC" 0
ck_eq "vendor JSON: every remote version, sorted" "$OUT" $'20250721000000\n20250801000000\n20250801000001'

parse "$(<"$FIX/v2.122.0-table.txt")"
ck_eq "vendor backticked table: refused, not read as an empty history" "$RC" 1
ck_eq "vendor backticked table: no versions printed" "$OUT" ""
ck_has "vendor backticked table: the refusal says why" "$ERR" "not migration-list JSON"

parse ""
ck_eq "empty output: refused" "$RC" 1
parse '{"migrations":['
ck_eq "malformed JSON: refused" "$RC" 1
parse '{"message":"Migrations listed"}'
ck_eq "JSON without a migrations array: refused" "$RC" 1
parse '[]'
ck_eq "a bare array: refused" "$RC" 1
parse '{"migrations":[]} trailing'
ck_eq "JSON followed by other text: refused" "$RC" 1

parse '{"migrations":[],"message":"Migrations listed"}'
ck_eq "an empty history is valid JSON: exit 0" "$RC" 0
ck_eq "an empty history prints nothing" "$OUT" ""

edge='{"migrations":[
  {"local":"20250101000000","remote":"","time":""},
  {"local":"20250101000001","remote":null,"time":""},
  {"local":"20250101000002","time":""},
  {"local":"","remote":"20250102","time":"t"},
  {"local":"","remote":"2025010","time":"t"},
  {"local":"","remote":"202501010000001","time":"t"},
  {"local":"","remote":"2025010a","time":"t"},
  {"local":"","remote":" 20250103000000","time":"t"},
  {"local":"","remote":"20250104000000\nx","time":"t"},
  {"local":"","remote":20250105000000,"time":"t"},
  {"local":"","remote":"20250106000000","time":"t"},
  {"local":"","remote":"20250106000000","time":"t"},
  "not-an-object"
]}'
parse "$edge"
ck_eq "edge rows: exit 0" "$RC" 0
ck_eq "edge rows: only 8-14 digit strings, deduplicated" "$OUT" $'20250102\n20250106000000'

RC=0
OUT=$(printf '%s' "$(<"$FIX/v2.122.0.json")" | JQ_BIN='' supabase_remote_versions 2>"$TMP/parse.err") || RC=$?
ck_eq "JQ_BIN set but empty means no jq: refused" "$RC" 1
ck_has "JQ_BIN empty: the refusal names jq" "$(<"$TMP/parse.err")" "jq not found"

# The CLI's JSON-mode failure. v2.122.0 writes it to stdout (vendor bytes in
# v2.122.0-error.json, captured with a fake project ref and token), so it must
# be refused as a listing and read as the reason the call failed.
parse "$(<"$FIX/v2.122.0-error.json")"
ck_eq "vendor error JSON: refused as a listing" "$RC" 1

# cli_error INPUT -> sets OUT, RC.
cli_error() {
  RC=0
  OUT=$(printf '%s' "$1" | supabase_cli_error) || RC=$?
}
cli_error "$(<"$FIX/v2.122.0-error.json")"
ck_eq "vendor error JSON: read" "$RC" 0
ck_eq "vendor error JSON: code, message and suggestion on one line" "$OUT" \
  "DbConfigIpv6Error; IPv6 is not supported on your current network; Run supabase link --project-ref abcdefghijklmnopqrst to setup IPv4 connection."
cli_error "$(<"$FIX/v2.122.0.json")"
ck_eq "a listing is not an error" "$RC" 1
ck_eq "a listing prints no error" "$OUT" ""
cli_error "$(<"$FIX/v2.122.0-table.txt")"
ck_eq "the table is not an error" "$RC" 1
cli_error ""
ck_eq "empty stdout is not an error" "$RC" 1
cli_error '{"_tag":"Error","error":{}}'
ck_eq "an error object with no text is not a reason" "$RC" 1
cli_error '{"_tag":"Error","error":{"code":"ConnectError","message":"failed to connect to postgresql://postgres.ref:hunter2@db.example:5432/postgres","detail":"with sbp_abcdefghijklmnopqrstuvwxyz012345\nand eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.c2lnbmF0dXJl password=hunter3"}}'
ck_eq "secret-bearing error: read" "$RC" 0
ck_has "secret-bearing error: the redaction is visible" "$OUT" "ConnectError; failed to connect to postgresql://[redacted]@db.example"
ck_not "secret-bearing error: URL password redacted" "$OUT" "hunter2"
ck_not "secret-bearing error: access token redacted" "$OUT" "sbp_abcdefghij"
ck_not "secret-bearing error: JWT redacted" "$OUT" "eyJyb2xl"
ck_not "secret-bearing error: password= value redacted" "$OUT" "hunter3"
ck_eq "secret-bearing error: one line" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1

echo
if [ "$failed" -eq 0 ]; then
  echo "ok — supabase migration list: $pass/$pass assertions passed"
  exit 0
fi
echo "FAILED — supabase migration list: $failed failed, $pass passed"
exit 1
