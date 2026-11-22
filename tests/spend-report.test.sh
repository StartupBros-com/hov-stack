#!/usr/bin/env bash
# Hermetic tests for scripts/spend-report.py's ccusage rollup.
#
# The ccusage package spec is the CCUSAGE_SPEC module constant, which
# follows the latest release. A flaky npx fetch stays an informational
# line by design (an offline Monday must not page). Runs the REAL script
# under a PATH-stubbed npx and a scratch HOME (so the ccflare ledger is
# absent).
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel)
SCRIPT="$ROOT/scripts/spend-report.py"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/bin/npx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NPX_CALLS:?}"
if [ "${NPX_RC:-0}" != 0 ]; then
  echo "npx-stub: failing on purpose" >&2
  exit "$NPX_RC"
fi
printf '%s' "${NPX_JSON?}"
STUB
chmod +x "$TMP/bin/npx"

DEFAULT_JSON='{"daily":[{"date":"2026-09-10","totalCost":1.5,"metadata":{"agents":["claude"]}}]}'
# run_report <label> [npx-exit-code] [json]: runs the real script under the stubs;
# stdout/stderr land in $TMP/out-<label>.log and err-<label>.log.
run_report() {
  local label=$1 npx_rc=${2:-0} npx_json=${3-$DEFAULT_JSON} rc
  NPX_CALLS="$TMP/npx-$label.log"; : > "$NPX_CALLS"
  (
    export PATH="$TMP/bin:$PATH" HOME="$TMP/home" NPX_CALLS NPX_RC="$npx_rc" NPX_JSON="$npx_json"
    python3 -I "$SCRIPT" > "$TMP/out-$label.log" 2> "$TMP/err-$label.log"
  ); rc=$?
  return $rc
}

SPEC=$(grep -E '^CCUSAGE_SPEC = "' "$SCRIPT" | head -1 | cut -d'"' -f2)
echo "== 0: CCUSAGE_SPEC follows the latest ccusage release =="
[ "$SPEC" = ccusage@latest ] && ok || bad "CCUSAGE_SPEC is not ccusage@latest (got: '$SPEC')"

echo "== 4: the spec reaches npx and produces the rollup line =="
run_report good; RC=$?
[ "$RC" = 0 ] && ok || bad "good run: exit $RC, want 0"
grep -qF "$SPEC daily --json" "$TMP/npx-good.log" && ok || bad "good run: npx not invoked with $SPEC: $(cat "$TMP/npx-good.log")"
grep -qF 'cross-tool 8d plan-equivalent' "$TMP/out-good.log" && ok || bad "good run: rollup line missing: $(cat "$TMP/out-good.log")"
grep -qF 'spend-flagged:' "$TMP/out-good.log" && ok || bad "good run: the spend-flagged trailer is missing, so the report did not finish: $(cat "$TMP/out-good.log")"

echo "== 5: a failing npx fetch stays informational (documented: an offline Monday must not page) =="
run_report flaky 7; RC=$?
[ "$RC" = 0 ] && ok || bad "flaky npx: exit $RC, want 0"
grep -qF 'ccusage rollup unavailable' "$TMP/out-flaky.log" && ok || bad "flaky npx: informational line missing: $(cat "$TMP/out-flaky.log")"
grep -qE '^WARN spend report: ccusage' "$TMP/out-flaky.log" && bad "flaky npx: a WARN fired on a fetch failure" || ok

echo "== 6: only an actual empty daily list reports zero days; numbers keep their format =="
run_report empty 0 '{"daily":[]}'; RC=$?
[ "$RC" = 0 ] && grep -qF '$0 across 0 day(s)' "$TMP/out-empty.log" && ok || bad "empty daily: expected successful zero-day rollup"
run_report numbers 0 '{"daily":[{"totalCost":0},{"totalCost":-1},{"totalCost":3.25,"metadata":null}]}'; RC=$?
[ "$RC" = 0 ] && grep -qF '$2 across 3 day(s)' "$TMP/out-numbers.log" && ok || bad "finite costs: expected the signed/fractional rollup"

echo "== 7: malformed usage stays informational and never masquerades as zero =="
while IFS='|' read -r label payload; do
  run_report "$label" 0 "$payload"; RC=$?
  if [ "$RC" = 0 ] &&
    grep -qF 'spend: ccusage rollup unavailable' "$TMP/out-$label.log" &&
    grep -qx 'spend-flagged:0' "$TMP/out-$label.log" &&
    ! grep -qE '^WARN spend report: ccusage|cross-tool 8d plan-equivalent' "$TMP/out-$label.log"; then
    ok
  else
    bad "$label: expected only the informational ccusage fallback and unchanged flags"
  fi
done <<'FIXTURES'
missing-daily|{}
renamed-daily|{"data":[{"totalCost":23}]}
daily-null|{"daily":null}
daily-object|{"daily":{}}
daily-string|{"daily":""}
row-null|{"daily":[null]}
missing-cost|{"daily":[{"period":"2026-09-10"}]}
string-cost|{"daily":[{"totalCost":"0"}]}
null-cost|{"daily":[{"totalCost":null}]}
boolean-cost|{"daily":[{"totalCost":false}]}
nonfinite-cost|{"daily":[{"totalCost":1e309}]}
nonfinite-sum|{"daily":[{"totalCost":1e308},{"totalCost":1e308}]}
FIXTURES

echo
echo "spend-report: $pass passed, $fail failed"
[ "$fail" = 0 ]
