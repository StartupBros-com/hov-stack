#!/usr/bin/env bash
# launch.sh <root> [parallel] - run every run dir under <root>/runs that has no
# result.json yet, <parallel> at a time (default 3), 25 minutes each at most.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$1"; PAR="${2:-3}"
find "$ROOT/runs" -mindepth 1 -maxdepth 1 -type d | sort | while read -r run; do
  [ -s "$run/result.json" ] || echo "$run"
done | xargs -P "$PAR" -I{} timeout 25m bash "$HERE/run_arm.sh" {}
echo "launch: done"
