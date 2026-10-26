#!/usr/bin/env bash
# Hermetic tests for scripts/spend-report.py's ccusage rollup.
#
# The ccusage version is the CCUSAGE_PIN module constant (an exact npm
# version). A flaky npx fetch stays an informational line by design (an
# offline Monday must not page). Runs the REAL script under a PATH-stubbed
# npx and a scratch HOME (so the ccflare ledger is absent).
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel)
SCRIPT="$ROOT/scripts/spend-report.py"
TMP=$(mktemp -d)
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
printf '%s' '{"daily":[{"date":"2026-09-10","totalCost":1.5,"metadata":{"agents":["claude"]}}]}'
STUB
chmod +x "$TMP/bin/npx"

# run_report <label> [npx-exit-code]: runs the real script under the stubs;
# stdout/stderr land in $TMP/out-<label>.log and err-<label>.log.
run_report() {
  local label=$1 npx_rc=${2:-0} rc
  NPX_CALLS="$TMP/npx-$label.log"; : > "$NPX_CALLS"
  (
    export PATH="$TMP/bin:$PATH" HOME="$TMP/home" NPX_CALLS NPX_RC="$npx_rc"
    python3 -I "$SCRIPT" > "$TMP/out-$label.log" 2> "$TMP/err-$label.log"
  ); rc=$?
  return $rc
}

PIN=$(grep -E '^CCUSAGE_PIN = "' "$SCRIPT" | head -1 | cut -d'"' -f2)
echo "== 0: CCUSAGE_PIN is an exact npm version, not a mutable selector =="
grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$PIN" && ok || bad "CCUSAGE_PIN is not an exact version (got: '$PIN')"

echo "== 4: the pin reaches npx and produces the rollup line =="
run_report good; RC=$?
[ "$RC" = 0 ] && ok || bad "good pin: exit $RC, want 0"
grep -qF "ccusage@$PIN daily --json" "$TMP/npx-good.log" && ok || bad "good pin: npx not invoked with ccusage@$PIN: $(cat "$TMP/npx-good.log")"
grep -qF 'cross-tool 8d plan-equivalent' "$TMP/out-good.log" && ok || bad "good pin: rollup line missing: $(cat "$TMP/out-good.log")"
grep -qF 'spend-flagged:' "$TMP/out-good.log" && ok || bad "good pin: the spend-flagged trailer is missing, so the report did not finish: $(cat "$TMP/out-good.log")"

echo "== 5: a failing npx fetch stays informational (documented: an offline Monday must not page) =="
run_report flaky 7; RC=$?
[ "$RC" = 0 ] && ok || bad "flaky npx: exit $RC, want 0"
grep -qF 'ccusage rollup unavailable' "$TMP/out-flaky.log" && ok || bad "flaky npx: informational line missing: $(cat "$TMP/out-flaky.log")"
grep -qE '^WARN spend report: ccusage' "$TMP/out-flaky.log" && bad "flaky npx: a WARN fired on a fetch failure" || ok

echo
echo "spend-report: $pass passed, $fail failed"
[ "$fail" = 0 ]
