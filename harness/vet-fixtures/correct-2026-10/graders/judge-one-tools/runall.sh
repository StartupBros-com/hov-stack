#!/bin/bash
cd /tmp/hv-correct-2026-10-07/judge-one
python3 plant.py r02 > out_r02.json 2>&1
python3 plant.py r03 > out_r03.json 2>&1
python3 plant.py r04 > out_r04.json 2>&1
python3 plant.py r05 > out_r05.json 2>&1
python3 plant.py r06 > out_r06.json 2>&1
python3 plant.py r07 > out_r07.json 2>&1
python3 plant.py r08 > out_r08.json 2>&1
python3 plant.py r09 > out_r09.json 2>&1
python3 plant.py r01 > out_r01.json 2>&1
python3 - <<'EOF'
import json
for r in ["r01","r02","r03","r04","r05","r06","r07","r08","r09"]:
    d=json.load(open(f"/tmp/hv-correct-2026-10-07/judge-one/out_{r}.json"))[r]
    print(r,"base",d["base_rc"])
    for p in ["P1","P2","P3","P4","P5"]:
        v=d[p]
        if isinstance(v,str): print(" ",p,v); continue
        if "err" in v: print(" ",p,v); continue
        print(" ",p,"rc",v["rc"], v["out"].splitlines()[-2] if v["rc"] else "")
EOF
