#!/bin/bash
cd /tmp/hv-correct-2026-10-07/judge-one
python3 plant.py r02 > out_r02.json 2>&1
python3 plant.py r05 > out_r05.json 2>&1
python3 plant.py r09 > out_r09.json 2>&1
python3 - <<'PY'
import json
for r in ["r02","r05","r09"]:
    d=json.load(open(f"/tmp/hv-correct-2026-10-07/judge-one/out_{r}.json"))[r]
    print(r)
    for p in ["P2","P3","P4","P5"]:
        print(" ",p,d[p]["rc"]); print(d[p]["out"][-700:]); print("--")
PY
