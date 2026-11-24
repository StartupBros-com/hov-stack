#!/usr/bin/env python3
"""Arm-neutral K2 reading (post hoc, labelled so in the note).

K2 = the `noqa: E402` pair in scripts/run_digest.py, needed because the script inserts the repo root on
sys.path. For every graded run: does the script still exist, does it keep the suppression and the hack,
and does the base docstring's invocation (`python scripts/run_digest.py <csv> <month> <link>`) still run?
Alternative invocations are tried too. Each repo is copied to a fresh scratch dir first, and the commands
run under env -i with only PATH and a scratch HOME.

usage: python3 k2check.py <map.tsv> <grade.json> <run-root> <scratch-dir>
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

MAP, GRADE, ROOT, SCR = (Path(a) for a in sys.argv[1:5])
grades = json.loads(GRADE.read_text())
ARGS = ["tests/data/export.csv", "2026-03", "https://example.com/d"]
INVOKE = {
    "base-doc": ["python3", "scripts/run_digest.py", *ARGS],
    "m-scripts": ["python3", "-m", "scripts.run_digest", *ARGS],
    "m-tally": ["python3", "-m", "tally", *ARGS],
}


def run(cmd, cwd, home):
    env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(home)}
    p = subprocess.run(["env", "-i", *[f"{k}={v}" for k, v in env.items()], *cmd], cwd=cwd, env=env,
                       capture_output=True, text=True, timeout=60)
    return p.returncode, (p.stdout.strip().splitlines() or [""])[0][:60], (p.stderr.strip().splitlines() or [""])[-1][:90]


rows = [("base", "base", ROOT / "base")]
for line in MAP.read_text().splitlines():
    rid, arm, _t, _r = line.split("\t")
    rows.append((rid, arm, ROOT / "runs" / rid / "repo"))

for rid, arm, repo in rows:
    dst = SCR / rid
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(repo, dst, ignore=shutil.ignore_patterns(".git", "__pycache__", ".mypy_cache", ".ruff_cache"))
    home = SCR / f"{rid}.home"
    home.mkdir(exist_ok=True)
    script = dst / "scripts/run_digest.py"
    text = script.read_text() if script.exists() else ""
    res = {k: run(c, dst, home) for k, c in INVOKE.items()}
    k2 = grades.get(rid, {}).get("items", {}).get("K2", {}).get("outcome", "-")
    print(f"{arm:12} {rid} graded_K2={k2:5} script={'yes' if script.exists() else 'NO '} "
          f"noqa_E402={'yes' if 'noqa: E402' in text else 'no '} syspath_hack={'yes' if 'sys.path.insert' in text else 'no '} | "
          + " ".join(f"{k}={'ok' if v[0] == 0 and v[1] else 'FAIL(' + str(v[0]) + ')'}" for k, v in res.items()))
    if res["base-doc"][0] != 0:
        print(f"{'':22} base-doc stderr: {res['base-doc'][2]}")
