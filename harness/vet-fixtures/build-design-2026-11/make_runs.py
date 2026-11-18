"""Build blinded run directories for the build-design-2026-11 fixture.

usage: python3 -I make_runs.py --out <runs-root> --key <key-file> --reps N
         [--arm NAME ...] [--task t1|t2|t3|t4|c1 ...] [--form slash|plain]
         --src pack=<plugins/hov-stack> [--src NAME=<skill dir> ...]
         [--order-seed N] [--first N]

Each run dir rNN gets prompt.txt, turn2.txt (sent only when turn 1 leaves the
working copy unchanged; run_arm.sh decides), task.txt, model.txt and a HOME whose
code/acme-console is a fresh git copy of seed/acme-console. Arm names appear only
in the key file, which must live outside <runs-root>.

A pack arm gets a copy of the hov-stack plugin under <run>/plugins/hov-stack,
loaded with --plugin-dir (plugin-dir.txt), as members install it; a pack+skill
arm gets the one extra skill added to that copy's skills/. Third-party skills
are not vendored: pass each skill directory with --src, fetched at the pin named
in README.md.

--form slash (the scored matrix) starts a pack+skill arm's prompt with its
namespaced slash command; --form plain sends every arm the same words, which
measures whether the model reaches for the skill on its own (README,
"Invocation probe").
"""

import argparse
import json
import os
import random
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from fixture_seed import copy_seed  # noqa: E402  (seed manifests are stored as <name>.fixture)

SEED = os.path.join(HERE, "seed", "acme-console")

TASKS = {
    "t1": "Add the Team members card from design/team-members.png to the settings page, below the Profile card.",
    "t2": ("Build this into the settings page, below the Profile card: "
           "https://www.figma.com/design/Qm7xT2vLp9cA4dR8sK1wYz/Acme-Console?node-id=42-1337"),
    "t3": "Add the Delete workspace card from design/danger-zone.png to the bottom of the settings page.",
    "t4": ("Build the billing page from design/billing.png as a new page component in src/pages/Billing.tsx. "
           "Don't wire it into the app yet."),
    # Invocation probe only (README): an unrelated edit the skill should not be reached for.
    "c1": "Fix the typo in the Notifications card title.",
}
BUILD_TASKS = ("t1", "t3", "t4")
# Identical for every arm, sent only when turn 1 left the working copy unchanged on a build task. Neutral
# on reporting: the pilot's wording ended "and tell me anything you had to approximate", which handed
# the report items to the arms that ask first and never to the ones that build on turn 1 (README).
TURN2 = "I don't have anything beyond the image right now. Go ahead and build it with what the project already has."
ARMS = {
    "bare": {"pack": False, "skill": None},
    "pack": {"pack": True, "skill": None},
    "pack+build-design": {"pack": True, "skill": "build-design"},
    "pack+design-to-code-fidelity": {"pack": True, "skill": "design-to-code-fidelity"},
}
GIT_ENV = {
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Maya Chen", "GIT_AUTHOR_EMAIL": "maya@acme.example",
    "GIT_COMMITTER_NAME": "Maya Chen", "GIT_COMMITTER_EMAIL": "maya@acme.example",
    "GIT_AUTHOR_DATE": "2026-11-10T09:00:00Z", "GIT_COMMITTER_DATE": "2026-11-10T09:00:00Z",
}


def git(repo, *args):
    env = dict(GIT_ENV, PATH=os.environ.get("PATH", "/usr/bin:/bin"), HOME=repo)
    subprocess.run(["git", "-C", repo, *args], check=True, env=env, capture_output=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--arm", action="append", default=[])
    ap.add_argument("--task", action="append", default=[])
    ap.add_argument("--form", choices=("slash", "plain"), default="slash")
    ap.add_argument("--src", action="append", default=[])
    ap.add_argument("--order-seed", type=int, default=20261117)
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--first", type=int, default=1, help="number of the first run dir")
    a = ap.parse_args()

    out, key = os.path.abspath(a.out), os.path.abspath(a.key)
    if key.startswith(out + os.sep):
        raise SystemExit("make_runs: the key file must live outside --out")
    srcs = dict(s.split("=", 1) for s in a.src)
    arms = a.arm or list(ARMS)
    tasks = a.task or ["t1", "t2", "t3", "t4"]
    for arm in arms:
        skill = ARMS[arm]["skill"]
        if skill and not os.path.isfile(os.path.join(srcs.get(skill, ""), "SKILL.md")):
            raise SystemExit("make_runs: arm %s needs --src %s=<dir holding SKILL.md>" % (arm, skill))
        if ARMS[arm]["pack"] and not os.path.isfile(
                os.path.join(srcs.get("pack", ""), ".claude-plugin", "plugin.json")):
            raise SystemExit("make_runs: arm %s needs --src pack=<plugins/hov-stack>" % arm)

    jobs = [(arm, task) for arm in arms for task in tasks for _ in range(a.reps)]
    random.Random(a.order_seed).shuffle(jobs)
    mapping = json.load(open(key)) if os.path.exists(key) else {}
    for i, (arm, task) in enumerate(jobs, start=a.first):
        rid = "r%02d" % i
        if rid in mapping:
            raise SystemExit("make_runs: %s already in %s" % (rid, key))
        run = os.path.join(out, rid)
        if os.path.exists(run):
            raise SystemExit("make_runs: %s exists" % run)
        home = os.path.join(run, "user")
        repo = os.path.join(home, "code", "acme-console")
        copy_seed(SEED, repo, ("package.json",))
        git(repo, "init", "-q", "-b", "main")
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "Settings page with profile and notification cards")
        os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
        skill = ARMS[arm]["skill"]
        files = {}
        if ARMS[arm]["pack"]:
            pack = os.path.join(run, "plugins", "hov-stack")
            shutil.copytree(srcs["pack"], pack, ignore=shutil.ignore_patterns(".git"))
            if skill:
                if os.path.exists(os.path.join(pack, "skills", skill)):
                    raise SystemExit("make_runs: the pack already has a skill named %s" % skill)
                shutil.copytree(srcs[skill], os.path.join(pack, "skills", skill),
                                ignore=shutil.ignore_patterns(".git"))
            files["plugin-dir.txt"] = pack
        prompt = TASKS[task]
        if skill and a.form == "slash":
            prompt = "/hov-stack:%s %s" % (skill, prompt)
        files.update({"prompt.txt": prompt, "task.txt": task, "model.txt": a.model})
        if task in BUILD_TASKS:
            files["turn2.txt"] = TURN2
        for name, text in files.items():
            with open(os.path.join(run, name), "w", encoding="utf-8") as fh:
                fh.write(text + "\n")
        mapping[rid] = {"arm": arm, "task": task, "form": a.form}
        print(rid, task)
    os.makedirs(os.path.dirname(key), exist_ok=True)
    with open(key, "w", encoding="utf-8") as fh:
        json.dump(mapping, fh, indent=1, sort_keys=True)


if __name__ == "__main__":
    sys.exit(main())
