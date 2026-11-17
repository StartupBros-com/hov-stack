"""Build blinded run directories for the learn-taste-2026-11 fixture.

usage: python3 -I make_runs.py --out <runs-root> --key <key-file> --reps N
         [--arm NAME ...] [--src NAME=<skill dir> ...] [--order-seed N]

Each run dir rNN gets prompt.txt, turn2.txt, model.txt, planted.txt and a HOME
built by sessions.build. Arm names appear only in the key file, which must live
outside <runs-root>; the arm sees a run number, its prompt, and (for a skill
arm) one skill under ~/.claude/skills. Third-party skills are not vendored: pass
each arm's skill directory with --src, fetched at the pin named in README.md.
"""

import argparse
import json
import os
import random
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sessions  # noqa: E402

ASK = ("Go through my previous session in this repo and turn the design corrections I made into rules "
       "future sessions will follow. Show me what you'd add before writing anything.")
# Exploratory, outside the adoption rule (README, "Exploratory: the all-history ask").
ASK_WIDE = ("Go through all my past sessions, in every project, not just this one, and turn the design "
            "corrections I made into rules future sessions in this repo will follow. Show me what you'd add "
            "before writing anything.")
ARMS = {
    "bare": {"prompt": ASK, "skill": None},
    "learn-taste": {"prompt": "/learn-taste " + ASK, "skill": "learn-taste"},
    "ce-retro": {"prompt": "/ce-retro " + ASK, "skill": "ce-retro"},
    "retro": {"prompt": "/retro " + ASK, "skill": "retro"},
    "bare-wide": {"prompt": ASK_WIDE, "skill": None},
    "learn-taste-wide": {"prompt": "/learn-taste " + ASK_WIDE, "skill": "learn-taste"},
    # Added after the scored matrix (README, "Added arm: claude-reflect"). A plugin, not a
    # skill: --src points at the plugin root, copied into the run dir and loaded with
    # --plugin-dir. --scan-history is its documented cold-start form; with no hook-captured
    # queue, plain /reflect only asks whether to scan. A --plugin-dir command is namespaced:
    # bare /reflect did not resolve (r19, README).
    "claude-reflect": {"prompt": "/claude-reflect:reflect --scan-history " + ASK, "skill": None,
                       "plugin": "claude-reflect"},
}
TURN2 = "write all"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--arm", action="append", default=[])
    ap.add_argument("--src", action="append", default=[])
    ap.add_argument("--order-seed", type=int, default=20261116)
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--first", type=int, default=1, help="number of the first run dir")
    a = ap.parse_args()

    out, key = os.path.abspath(a.out), os.path.abspath(a.key)
    if key.startswith(out + os.sep):
        raise SystemExit("make_runs: the key file must live outside --out")
    srcs = dict(s.split("=", 1) for s in a.src)
    arms = a.arm or ["bare", "learn-taste", "ce-retro", "retro"]
    for arm in arms:
        skill = ARMS[arm]["skill"]
        if skill and not os.path.isfile(os.path.join(srcs.get(skill, ""), "SKILL.md")):
            raise SystemExit("make_runs: arm %s needs --src %s=<dir holding SKILL.md>" % (arm, skill))
        plugin = ARMS[arm].get("plugin")
        if plugin and not os.path.isfile(os.path.join(srcs.get(plugin, ""), ".claude-plugin", "plugin.json")):
            raise SystemExit("make_runs: arm %s needs --src %s=<plugin root>" % (arm, plugin))

    jobs = [arm for arm in arms for _ in range(a.reps)]
    random.Random(a.order_seed).shuffle(jobs)
    mapping = {}
    if os.path.exists(key):
        mapping = json.load(open(key))
    for i, arm in enumerate(jobs, start=a.first):
        rid = "r%02d" % i
        if rid in mapping:
            raise SystemExit("make_runs: %s already in %s" % (rid, key))
        run = os.path.join(out, rid)
        if os.path.exists(run):
            raise SystemExit("make_runs: %s exists" % run)
        home = os.path.join(run, "user")
        sessions.build(home)
        skill = ARMS[arm]["skill"]
        if skill:
            shutil.copytree(srcs[skill], os.path.join(home, ".claude", "skills", skill))
        plugin = ARMS[arm].get("plugin")
        if plugin:
            dest = os.path.join(run, "plugins", plugin)
            shutil.copytree(srcs[plugin], dest, ignore=shutil.ignore_patterns(".git"))
            with open(os.path.join(run, "plugin-dir.txt"), "w", encoding="utf-8") as fh:
                fh.write(dest + "\n")
        for name, text in (("prompt.txt", ARMS[arm]["prompt"]), ("turn2.txt", TURN2), ("model.txt", a.model),
                           ("planted.txt", "\n".join(sessions.PLANTED_IDS))):
            with open(os.path.join(run, name), "w", encoding="utf-8") as fh:
                fh.write(text + "\n")
        mapping[rid] = arm
        print(rid)
    os.makedirs(os.path.dirname(key), exist_ok=True)
    with open(key, "w", encoding="utf-8") as fh:
        json.dump(mapping, fh, indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
