#!/usr/bin/env bash
# batch4.sh <root> <map.tsv> - the warm-cache batch (warm-cache-batch.md): build the
# base, create the 32 blinded runs, order them, run them one at a time, then write
# <root>/runs.tsv (runlog.py) and <root>/grade.json (grade.py). <map.tsv> must live
# outside <root>. Spends real model calls: about $2.50 on the recorded run.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
R="${1:?usage: batch4.sh <root> <map.tsv>}"
MAP="${2:?usage: batch4.sh <root> <map.tsv>}"
if [ -e "$R" ] || [ -e "$MAP" ]; then echo "batch4: $R or $MAP already exists" >&2; exit 1; fi
bash "$HERE/build-base.sh" "$R"
MODEL=opus bash "$HERE/make-runs.sh" "$R" "$MAP" a1-bare 1 t3
MODEL=opus bash "$HERE/make-runs.sh" "$R" "$MAP" a3-incumbent 3 t2 t3
MODEL=opus bash "$HERE/make-runs.sh" "$R" "$MAP" a9-trimmed 3 t2 t3
bash "$HERE/make-runs.sh" "$R" "$MAP" a1-bare 1 t3
bash "$HERE/make-runs.sh" "$R" "$MAP" a3-incumbent 3 t1 t2 t3
bash "$HERE/make-runs.sh" "$R" "$MAP" a9-trimmed 3 t1 t2 t3
python3 -I "$HERE/order-warm.py" "$MAP" > "$MAP.order"
bash "$HERE/launch-seq.sh" "$R" "$MAP.order"
python3 -I "$HERE/runlog.py" "$R" "$MAP" > "$R/runs.tsv"
python3 "$HERE/grade.py" "$R" "$R/grade.json"
python3 -I "$HERE/eval-warm.py" "$R/runs.tsv" "$R/grade.json"
