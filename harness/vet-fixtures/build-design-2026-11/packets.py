"""Write one blinded grading packet per run for the report-item judges.

usage: python3 -I packets.py <runs-root> <packet-dir> [--scores scores.json]

A packet carries the run number only, never the arm. Skill names and their
slash commands are redacted from the replies. Each packet lists the report items
that apply to its task (answer-key.md, "Items"); J5 is listed only for a t1 run
whose added code dropped `text-gray-300` (score_runs.py left D5 to the judges).
"""

import argparse
import json
import os
import re
import subprocess

REDACT = re.compile(r"/?\bhov-stack:[\w-]+|/?\b(build-design|design-to-code-fidelity|design-to-code)\b"
                    r"|Design-to-Code Fidelity|\bBloc [123]\b", re.I)
TASK_TEXT = {
    "t1": "Add the Team members card from design/team-members.png to the settings page, below the Profile card.",
    "t2": "Build this into the settings page, below the Profile card: <a Figma link>. (No arm had any Figma or "
          "web tool.)",
    "t3": "Add the Delete workspace card from design/danger-zone.png to the bottom of the settings page.",
    "t4": "Build the billing page from design/billing.png as a new page component in src/pages/Billing.tsx. "
          "Don't wire it into the app yet.",
}
ITEMS = {"t1": ["R1", "R2", "R3", "R5"], "t2": ["R4"], "t3": ["R3"], "t4": ["R1", "R2", "R3", "R5"]}
CAP = 24000


def reply(path):
    try:
        return json.load(open(path, encoding="utf-8")).get("result") or "(empty)"
    except (OSError, ValueError):
        return None


def diff(repo):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GIT_CONFIG_NOSYSTEM": "1", "HOME": repo}
    run = lambda *a: subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, check=True,
                                    env=env).stdout
    run("add", "-A", "-N")
    base = run("rev-list", "--max-parents=0", "HEAD").split()[0]
    return run("diff", base)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("dest")
    ap.add_argument("--scores")
    ap.add_argument("--key", help="skip the invocation probe's plain-form runs (the key never enters a packet)")
    a = ap.parse_args()
    d5, void = {}, set()
    if a.scores:
        for s in json.load(open(a.scores)):
            d5[s["rid"]] = s["items"].get("D5_email_colour_as_drawn_or_named", "n/a")
            if s.get("void"):
                void.add(s["rid"])
    plain = set()
    if a.key:
        plain = {rid for rid, meta in json.load(open(a.key)).items() if meta.get("form", "slash") != "slash"}
    os.makedirs(a.dest, exist_ok=True)
    index = {}
    for rid in sorted(os.listdir(a.root)):
        run = os.path.join(a.root, rid)
        out = os.path.join(run, "out")
        if rid in void or rid in plain or not os.path.isfile(os.path.join(out, "result-t1.json")):
            continue
        task = open(os.path.join(run, "task.txt")).read().strip()
        if task not in ITEMS:
            continue
        items = list(ITEMS[task])
        if task == "t1" and d5.get(rid, "n/a") is None:
            items.append("J5")
        r1 = reply(os.path.join(out, "result-t1.json"))
        r2 = reply(os.path.join(out, "result-t2.json"))
        parts = ["# Run %s" % rid, "Task (%s): %s" % (task, TASK_TEXT[task]),
                 "Items to grade: %s" % ", ".join(items),
                 "## Reply after turn 1", r1.strip()]
        if r2 is not None:
            said = open(os.path.join(run, "turn2.txt"), encoding="utf-8").read().strip()
            parts += ["## The user then said", said, "## Reply after turn 2 (the final reply)", r2.strip()]
        parts += ["## Final diff of the working copy (against the starting commit)",
                  "```diff\n%s\n```" % (diff(os.path.join(run, "user", "code", "acme-console"))[:CAP] or "(no change)")]
        body = REDACT.sub("[skill]", "\n\n".join(parts) + "\n")
        with open(os.path.join(a.dest, rid + ".md"), "w", encoding="utf-8") as fh:
            fh.write(body)
        index[rid] = {"task": task, "items": items}
    with open(os.path.join(a.dest, "index.json"), "w", encoding="utf-8") as fh:
        json.dump(index, fh, indent=1, sort_keys=True)
    print("%d packets" % len(index))


if __name__ == "__main__":
    main()
