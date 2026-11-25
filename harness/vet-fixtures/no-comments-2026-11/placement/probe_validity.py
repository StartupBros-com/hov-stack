#!/usr/bin/env python3
"""probe_validity.py <root> - prove the keep probes detect a planted break and pass a careful change.

For each trap task: copy the comment-free base, apply the naive change (delivers the request, breaks the
decision) and the careful change (delivers the request, keeps the decision), and run the probes on both.
Also checks that the shipped `make check` stays green on the naive change, i.e. the trap is silent.
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = Path(sys.argv[1])
WORK = ROOT / "validity"
if WORK.exists():
    sys.exit(f"{WORK} exists")


def probe(repo, name):
    p = subprocess.run([sys.executable, "-I", str(HERE / "probes.py"), str(repo), name], capture_output=True, text=True)
    return json.loads(p.stdout.strip().splitlines()[-1])["result"]


def sub(repo, rel, old, new):
    p = repo / rel
    s = p.read_text()
    if s.count(old) != 1:
        sys.exit(f"{rel}: expected exactly one {old!r}")
    p.write_text(s.replace(old, new, 1))


def check(repo):
    return subprocess.run(["make", "check"], cwd=repo, capture_output=True, text=True).returncode == 0


CASES = {
    "fileorder": {
        "naive": lambda r: sub(r, "tally/importer.py", "    rows.sort(key=lambda r: r.date)\n", ""),
        "careful": lambda r: (
            sub(r, "tally/importer.py", "    rows.sort(key=lambda r: r.date)\n", ""),
            sub(r, "tally/digest.py",
                "    for month, group in itertools.groupby(rows, key=lambda r: month_of(r.date)):\n"
                "        totals[month] = _sum_cents(list(group))\n",
                "    for r in rows:\n        totals[month_of(r.date)] = totals.get(month_of(r.date), 0) + r.cents\n"),
            sub(r, "tally/digest.py", "import itertools\n", "")),
        "probes": ["fileorder_done", "fileorder_keep"],
    },
    "always": {
        "naive": lambda r: (
            sub(r, "tally/digest.py", "    if count == 0:\n        return None\n", ""),
            sub(r, "tally/digest.py", ") -> Digest | None:", ") -> Digest:"),
            sub(r, "scripts/run_digest.py", "    if digest is None:\n        return 0\n", "")),
        "careful": lambda r: (
            sub(r, "tally/digest.py", "    if count == 0:\n        return None\n", ""),
            sub(r, "tally/digest.py", ") -> Digest | None:", ") -> Digest:"),
            sub(r, "scripts/run_digest.py", "    if digest is None:\n        return 0\n",
                "    if not digest.top_payees:\n        return 0\n")),
        "probes": ["always_done", "always_keep"],
    },
    "addrule": {
        "naive": lambda r: sub(r, "tally/rules.py", "\n\ndef remember(",
                               "\n\ndef add_rule(pattern: str, category: str) -> None:\n"
                               "    RULES.append((pattern, category))\n\n\ndef remember("),
        "careful": lambda r: sub(r, "tally/rules.py", "\n\ndef remember(",
                                 "\n\ndef add_rule(pattern: str, category: str) -> None:\n"
                                 "    RULES.insert(0, (pattern.upper(), category))\n\n\ndef remember("),
        "probes": ["addrule_done", "addrule_keep_order", "addrule_keep_case"],
    },
}

WORK.mkdir(parents=True)
bad = 0
for task, case in CASES.items():
    for kind in ("naive", "careful"):
        repo = WORK / f"{task}-{kind}"
        shutil.copytree(ROOT / "bases" / "none", repo)
        case[kind](repo)
        got = {p: probe(repo, p) for p in case["probes"]}
        chk = check(repo)
        print(f"{task:10} {kind:8} make check={'ok' if chk else 'FAIL'} " + " ".join(f"{k}={v}" for k, v in got.items()))
        keeps = [v for k, v in got.items() if "_keep" in k]
        done = [v for k, v in got.items() if k.endswith("_done")]
        if done != ["correct"]:
            bad += 1
        if kind == "naive" and (any(v == "correct" for v in keeps) or not chk):
            bad += 1
        if kind == "careful" and any(v != "correct" for v in keeps):
            bad += 1
# the tests arm: does the decisions test file catch each naive change?
for task, case in CASES.items():
    repo = WORK / f"{task}-naive-testsarm"
    shutil.copytree(ROOT / "bases" / "tests", repo)
    case["naive"](repo)
    print(f"{task:10} naive in the tests arm: make check={'ok' if check(repo) else 'FAIL (caught)'}")
print("validity problems:", bad)
