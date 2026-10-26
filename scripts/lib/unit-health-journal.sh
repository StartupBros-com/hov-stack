#!/usr/bin/env bash
# One read-only journal query; unit-health.sh runs at most eight concurrently.
set -euo pipefail
since=$1
unit=$2
if ! count=$(journalctl --user -u "$unit" --since "$since" --no-pager -o cat \
    | awk 'index($0, "Failed with result") { n++ } END { print n+0 }'); then
  echo "unit-health: could not read journal for $unit; refusing an incomplete report" >&2
  exit 2
fi
printf '%s\t%s\n' "$unit" "$count"
