#!/usr/bin/env bash
# onwatch-usage.sh <provider> — read a provider's credit/quota utilization from onwatch,
# the (power-user) balance oracle for reserve floors and reset-aware scheduling (R10).
#
# Sources (onwatch exposes grok only in its DB, anthropic/codex in open /metrics):
#   grok               -> ~/.onwatch/data/onwatch.db  table grok_quota_values  (util %, resets_at)
#   anthropic | codex  -> http://localhost:9211/metrics  (seven_day window)
#   claude maps to the anthropic provider.
#
# Emits one JSON object on stdout. Exit codes:
#   0  ok
#   3  onwatch / oracle not available  -> caller falls back to spend-tracking / drain
#   2  error (onwatch present but read failed)
#
# Members typically have NO onwatch: this exits 3 and the harvest loop stays conservative.
# Replicating onwatch's own no-onwatch grok poll (gRPC GetGrokCredits) is a tracked enhancement.
set -euo pipefail

PROV="${1:?provider required: grok|codex|claude|anthropic}"
case "$PROV" in claude) OWP=anthropic ;; *) OWP="$PROV" ;; esac
DB="${ONWATCH_DB:-$HOME/.onwatch/data/onwatch.db}"
METRICS="${ONWATCH_METRICS:-http://localhost:9211/metrics}"

if [ "$OWP" = grok ]; then
  [ -f "$DB" ] || exit 3
  command -v python3 >/dev/null || exit 2
  python3 -c '
import sqlite3, sys, json
db = sys.argv[1]
try:
    c = sqlite3.connect("file:%s?mode=ro" % db, uri=True); c.row_factory = sqlite3.Row
    r = c.execute("select quota_name, utilization, resets_at, status "
                  "from grok_quota_values order by id desc limit 1").fetchone()
except Exception:
    sys.exit(2)
if not r:
    sys.exit(3)
print(json.dumps({"provider": "grok", "quota": r["quota_name"], "util_percent": r["utilization"],
                  "resets_at": r["resets_at"], "status": r["status"], "source": "onwatch-db"}))
' "$DB"
  exit $?
fi

# anthropic / codex: onwatch open Prometheus /metrics, seven_day window
M="$(curl -s --max-time 4 "$METRICS" 2>/dev/null || true)"
[ -n "$M" ] || exit 3
util="$(printf '%s\n' "$M" | awk -v p="$OWP" 'index($0,"onwatch_quota_utilization_percent{") && index($0,"provider=\""p"\"") && index($0,"quota_type=\"seven_day\""){print $2; exit}')"
reset="$(printf '%s\n' "$M" | awk -v p="$OWP" 'index($0,"onwatch_quota_reset_timestamp_seconds{") && index($0,"provider=\""p"\"") && index($0,"quota_type=\"seven_day\""){print $2; exit}')"
[ -n "$util" ] || exit 3
printf '{"provider":"%s","quota":"seven_day","util_percent":%s,"resets_at_unix":%s,"source":"onwatch-metrics"}\n' "$PROV" "$util" "${reset:-null}"
