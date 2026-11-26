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

echo "== 6: reads the renamed default ledger under scratch HOME =="
python3 - "$TMP/home" <<'PYDB'
import pathlib, sqlite3, sys, time
root = pathlib.Path(sys.argv[1]) / ".config" / "hov-router"
root.mkdir(parents=True)
with sqlite3.connect(root / "hov-router.db") as db:
    db.execute("CREATE TABLE requests (timestamp INTEGER, cost_usd REAL, total_tokens INTEGER, model TEXT)")
    db.execute("INSERT INTO requests VALUES (?, 42, 1000000, 'fixture-model')", (int(time.time() * 1000) - 1000,))
PYDB
run_report ledger; RC=$?
[ "$RC" = 0 ] && ok || bad "ledger run: exit $RC"
grep -qF 'fixture-model' "$TMP/out-ledger.log" && ok || bad "renamed ledger not read: $(cat "$TMP/out-ledger.log")"
! grep -qF 'DB missing' "$TMP/out-ledger.log" && ok || bad "renamed ledger reported missing"

echo
echo "spend-report: $pass passed, $fail failed"
[ "$fail" = 0 ]
