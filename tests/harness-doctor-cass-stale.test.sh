#!/usr/bin/env bash
# Contract: harness-doctor section 8b treats ROUTINE cass staleness as ok, and
# still warns on every other way cass can be unhealthy.
#
# WHY THIS EXISTS
# cass marks its index stale as soon as one new session lands after the last
# lexical checkpoint, and the daily cass-index run is what catches it up. So
# `.healthy` read false about 23 hours a day, and section 8b warned on every
# doctor run (measured 2026-11-20). The fix tolerates two stale reasons under a
# 48 h age bound, with the rest of cass's own healthy AND still holding. A
# tolerance like that is exactly where a real fault can hide, so most of the
# cases below are the faults that must still warn.
#
# Runs the REAL section, extracted from harness-doctor.sh, against a stub `cass`
# that prints a fixture. The base fixture is the shape `cass status --json`
# (cass 0.11.0) returned on 2026-11-20, trimmed to the fields the section reads.
#
# PLANTED NEGATIVES, measured against a copied harness-doctor.sh:
#   tolerance branch removed             -> cases 1, 2 fail (routine stale warns again)
#   age bound removed from the predicate -> case 4 fails (a dead timer reads as ok)
#   reason list removed                  -> case 5 fails (a fault reason reads as ok)
#   repair-deferral guard removed        -> case 12 fails (a deferral streak reads as ok)
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=${DOCTOR:-$REPO/scripts/harness-doctor.sh}
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok_() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

sed -n '/^echo "== 8b\. /,/^echo "== 8c\. /p' "$DOCTOR" | sed '$d' > "$TMP/s8b.sh"
grep -qF 'cass_routine_stale=' "$TMP/s8b.sh" \
  || { echo "FAIL: could not extract section 8b with its routine-stale predicate" >&2; exit 1; }

# Stubs: cass prints the fixture named by CASS_FIXTURE; systemctl reports the
# jsm timer green so only the cass half of the section can warn.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cass" <<'EOF'
#!/usr/bin/env bash
[ -s "$CASS_FIXTURE" ] && cat "$CASS_FIXTURE"
exit 0
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *is-active*) echo active ;;
  *show*) echo success ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/cass" "$TMP/bin/systemctl"

BASE='{
  "healthy": false, "health_level": "unhealthy", "status": "unhealthy",
  "warnings": [],
  "database": {"exists": true, "opened": true, "open_retryable": false, "open_error": null},
  "index": {"exists": true, "status": "stale",
            "reason": "database fingerprint changed since the last lexical checkpoint",
            "fresh": false, "stale": true, "partial": false, "hollow": false,
            "stalled": false, "rebuilding": false, "engine_incompatible": false,
            "empty_with_messages": false, "age_seconds": 43744,
            "checkpoint": {"completed": true}}
}'

# run_8b <jq edit applied to BASE, or "EMPTY"> -> the section's output
run_8b() {
  if [ "$1" = EMPTY ]; then : > "$TMP/fixture.json"
  else printf '%s' "$BASE" | jq "$1" > "$TMP/fixture.json"; fi
  ( export CASS_FIXTURE=$TMP/fixture.json PATH="$TMP/bin:$PATH"
    WARNS=0
    # shellcheck disable=SC2329  # called by the sourced section
    warn() { echo "WARN: $*"; WARNS=$((WARNS + 1)); }
    # shellcheck disable=SC2329
    ok() { echo "  ok: $*"; }
    # shellcheck disable=SC1091
    . "$TMP/s8b.sh" 2>&1 )
}
# expect <label> <jq edit> <warn|quiet> [text the output must contain]
expect() {
  local label=$1 edit=$2 want=$3 needle=${4:-} out got
  out=$(run_8b "$edit")
  case "$out" in *"WARN: "*) got=warn ;; *) got=quiet ;; esac
  if [ "$got" != "$want" ]; then bad "$label: wanted $want, got $got: $out"; return; fi
  if [ -n "$needle" ]; then
    case "$out" in *"$needle"*) ;; *) bad "$label: output lacks '$needle': $out"; return ;; esac
  fi
  ok_
}

# 1. The noise this fixes: new sessions since the last checkpoint, 12 h old.
expect "1 routine stale (new sessions, 12h)" '.' quiet \
  "ok: cass index 12h behind new sessions"
# 2. The other routine reason, age past the 30 min threshold.
expect "2 routine stale (age threshold)" \
  '.index.reason = "lexical index is older than the stale threshold"' quiet "behind new sessions"
# 3. Stale plus a rotting checkpoint: the rot check still fires, tolerance or not.
expect "3 stale + partial" '.index.partial = true' warn "cass lexical index rotting"
# 4. The daily timer stopped: stale past 48 h must warn, and say how old.
expect "4 stale past 48h" '.index.age_seconds = 200000' warn "age=55h"
# 5. A stale reason that IS a fault.
expect "5 fault reason" \
  '.index.reason = "lexical rebuild checkpoint points at a different database"' warn "cass index unhealthy"
# 6. An integrity warning rides in .warnings; tolerance must not hide it.
expect "6 integrity warning" \
  '.warnings = ["the canonical archive'"'"'s stored pages are malformed"]' warn "cass index unhealthy"
# 7. Unhealthy without stale: critical ingest quarantine on a fresh index.
expect "7 unhealthy, not stale" \
  '.health_level = "critical" | .index.status = "ready" | .index.stale = false | .index.fresh = true | .index.reason = null' \
  warn "cass index unhealthy (level=critical"
# 8. A wedged indexer: status stalled outranks stale in cass.
expect "8 stalled" '.index.status = "stalled" | .index.stalled = true' warn "cass index unhealthy"
# 9. The DB will not open.
expect "9 db unavailable" '.database.opened = false' warn "cass index unhealthy"
# 10. Zero-run-green guard: a healthy index is quiet and says so.
expect "10 healthy" '.healthy = true | .health_level = "healthy" | .index.status = "ready" | .index.stale = false' \
  quiet "ok: cass healthy + jsm auto-update timer green"
# 11. No JSON at all still warns.
expect "11 no JSON" EMPTY warn "cass status timed out or returned no JSON"
# 12. Daily runs that defer the lexical repair: each resets last_indexed_at, so
#     the age bound stays green while the index falls behind for good. cass
#     publishes the streak as index.lexical_repair_deferred; it must warn.
expect "12 repair deferral streak" \
  '.index.lexical_repair_deferred = {"consecutive_runs": 3, "reason": "db over the deferred-repair size gate"}' \
  warn "cass index unhealthy"

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
  echo "ok — harness-doctor cass staleness: $pass/$total assertions passed"
  exit 0
fi
echo "FAIL — harness-doctor cass staleness: $fail of $total assertions failed" >&2
exit 1
