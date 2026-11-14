#!/usr/bin/env bash
# launch-seq.sh <root> <order-file> - run the run dirs named in <order-file>
# (one id per line, each under <root>/runs/) one at a time, in file order,
# 25 minutes each at most. A run that already has a result.json is skipped.
#
# Used for the warm-cache batch (warm-cache-batch.md): each run starts after
# the previous one finished, so every run but the first of a model reads that
# model's cached prompt prefix instead of writing it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:?usage: launch-seq.sh <root> <order-file>}"
ORDER="${2:?usage: launch-seq.sh <root> <order-file>}"
[ -f "$ORDER" ] || { echo "launch-seq: no order file $ORDER" >&2; exit 1; }
while read -r id; do
  [ -n "$id" ] || continue
  run="$ROOT/runs/$id"
  [ -d "$run" ] || { echo "launch-seq: no run dir $run" >&2; continue; }
  [ -s "$run/result.json" ] && continue
  timeout 25m bash "$HERE/run_arm.sh" "$run" < /dev/null
  echo "launch-seq: $id rc=$?"
done < "$ORDER"
echo "launch-seq: done"
