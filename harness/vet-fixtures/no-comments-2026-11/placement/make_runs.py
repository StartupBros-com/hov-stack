#!/usr/bin/env python3
"""make_runs.py <root> <map.tsv> <model> <reps> <tasks.json> <arm,arm,...> <task,task,...>

Creates blinded run dirs under <root>/runs/<random id>/ (repo/, prompt.txt, model.txt, task.txt) from
<root>/bases/<arm>, and appends "id<TAB>arm<TAB>task<TAB>rep<TAB>model" to <map.tsv>, which lives outside
<root> so a run never sees which arm it is. The fixture's run_arm.sh and launch.sh run them unchanged.
"""
import json
import secrets
import shutil
import sys
from pathlib import Path

root, map_path, model, reps, tasks_json, arms, tasks = sys.argv[1:8]
runs_root = Path(sys.argv[8]) if len(sys.argv) > 8 else Path(root)
root = Path(root)
SUFFIX = " Keep `make check` passing. I won't be around to answer questions, so finish it and tell me what you did."
texts = json.load(open(tasks_json))
(runs_root / "runs").mkdir(parents=True, exist_ok=True)
n = 0
with open(map_path, "a", encoding="utf-8") as mp:
    for arm in arms.split(","):
        base = root / "bases" / arm
        if not (base / ".git").is_dir():
            sys.exit(f"no base for arm {arm}")
        for task in tasks.split(","):
            for rep in range(1, int(reps) + 1):
                rid = secrets.token_hex(4)
                run = runs_root / "runs" / rid
                (run / "config").mkdir(parents=True)
                shutil.copytree(base, run / "repo", symlinks=True)
                (run / "prompt.txt").write_text(texts[task].strip() + SUFFIX, encoding="utf-8")
                (run / "model.txt").write_text(model + "\n", encoding="utf-8")
                (run / "task.txt").write_text(task + "\n", encoding="utf-8")
                mp.write(f"{rid}\t{arm}\t{task}\t{rep}\t{model}\n")
                n += 1
print(f"made {n} runs for model {model}")
