"""Build blinded run directories for the ui-design-2026-11 fixture.

usage: python3 -I make_runs.py --out <runs-root> --key <key-file> --reps N
         --src base=<plugins/hov-stack at the base> --src branch=<plugins/hov-stack on this branch>
         [--arm NAME ...] [--task NAME ...] [--order-seed N] [--first N]

Reuses ../build-design-2026-11: its seed repo, its t1 and t4 prompts and turn-2
line, and (in run_arm.sh) its isolated runner. Every arm gets the same plain
prompt; the arms differ only in which copy of the pack --plugin-dir loads. The
review task also gets ../jakubkrehel-skills/fixture.html as prototypes/account.html.
Arm names appear only in the key file, which must live outside <runs-root>.
"""

import argparse
import json
import os
import random
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BD = os.path.join(HERE, "..", "build-design-2026-11")
SEED = os.path.join(BD, "seed", "acme-console")
REVIEW_PAGE = os.path.join(HERE, "..", "jakubkrehel-skills", "fixture.html")
sys.path.insert(0, BD)
import make_runs as bd  # noqa: E402  (the build-design fixture's prompts, turn 2 and git identity)

TASKS = {
    "t1": bd.TASKS["t1"],
    "t4": bd.TASKS["t4"],
    "rv": "Review the account page prototype in prototypes/account.html for UI problems before we build it. "
          "Don't change any files.",
    "p1": "The spacing and colours on the settings page feel inconsistent. Tidy them up.",
    "c1": bd.TASKS["c1"],
    "c2": "Add a typecheck script to package.json that runs tsc with --noEmit.",
    "c3": "Add a CONTRIBUTING.md that explains how to run the app locally and how to open a pull request.",
}
TURN2_TASKS = ("t1", "t4")
ARMS = {"pack": "base", "pack+ui-design": "branch"}
# The pre-registered matrix (README, "Runs"): the pack runs only the tasks the quality rules compare.
MATRIX = {"pack": ("t1", "t4", "rv"), "pack+ui-design": ("t1", "t4", "rv", "p1", "c1", "c2", "c3")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--reps", type=int, default=4)
    ap.add_argument("--arm", action="append", default=[])
    ap.add_argument("--task", action="append", default=[])
    ap.add_argument("--src", action="append", default=[])
    ap.add_argument("--order-seed", type=int, default=20261119)
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--first", type=int, default=1)
    a = ap.parse_args()

    out, key = os.path.abspath(a.out), os.path.abspath(a.key)
    if key.startswith(out + os.sep):
        raise SystemExit("make_runs: the key file must live outside --out")
    srcs = dict(s.split("=", 1) for s in a.src)
    for name in set(ARMS[arm] for arm in (a.arm or ARMS)):
        if not os.path.isfile(os.path.join(srcs.get(name, ""), ".claude-plugin", "plugin.json")):
            raise SystemExit("make_runs: needs --src %s=<a plugins/hov-stack copy>" % name)

    jobs = [(arm, task) for arm in (a.arm or ARMS) for task in MATRIX[arm]
            if not a.task or task in a.task for _ in range(a.reps)]
    random.Random(a.order_seed).shuffle(jobs)
    mapping = json.load(open(key)) if os.path.exists(key) else {}
    for i, (arm, task) in enumerate(jobs, start=a.first):
        rid = "r%02d" % i
        run = os.path.join(out, rid)
        if rid in mapping or os.path.exists(run):
            raise SystemExit("make_runs: %s already exists" % rid)
        home = os.path.join(run, "user")
        repo = os.path.join(home, "code", "acme-console")
        shutil.copytree(SEED, repo)
        if task == "rv":
            os.makedirs(os.path.join(repo, "prototypes"))
            shutil.copy(REVIEW_PAGE, os.path.join(repo, "prototypes", "account.html"))
        bd.git(repo, "init", "-q", "-b", "main")
        bd.git(repo, "add", "-A")
        bd.git(repo, "commit", "-q", "-m", "Settings page with profile and notification cards")
        os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
        pack = os.path.join(run, "plugins", "hov-stack")
        shutil.copytree(srcs[ARMS[arm]], pack, ignore=shutil.ignore_patterns(".git"))
        files = {"plugin-dir.txt": pack, "prompt.txt": TASKS[task], "task.txt": task, "model.txt": a.model}
        if task in TURN2_TASKS:
            files["turn2.txt"] = bd.TURN2
        for name, text in files.items():
            with open(os.path.join(run, name), "w", encoding="utf-8") as fh:
                fh.write(text + "\n")
        mapping[rid] = {"arm": arm, "task": task, "form": "plain"}
        print(rid, task)
    os.makedirs(os.path.dirname(key), exist_ok=True)
    with open(key, "w", encoding="utf-8") as fh:
        json.dump(mapping, fh, indent=1, sort_keys=True)


if __name__ == "__main__":
    sys.exit(main())
