"""Write blinded grading packets for the ui-design-2026-11 judges.

usage: python3 -I packets.py <runs-root> <packet-dir> [--void rNN ...]

Two sets: <packet-dir>/build (t1, t4; graded with ../build-design-2026-11/judge-brief.md) and
<packet-dir>/review (rv; graded with judge-brief-review.md). A packet carries the run number only.
Skill names and slash commands are redacted from replies. J5 is listed for a t1 run whose added
code dropped `text-gray-300`, as in the build-design fixture.
"""

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BD = os.path.join(HERE, "..", "build-design-2026-11")
sys.path.insert(0, BD)
import packets as bdp  # noqa: E402  (reply(), diff(), TASK_TEXT, ITEMS, CAP)

REDACT = re.compile(
    r"/?\bhov-stack:[\w-]+|/?\b(ui-design|better-interface|interface-review|better-(?:accessibility|layout|"
    r"writing|typography|colors|ui)|review-animations|kill-ai-slop|pick-ui-library|apple-design|animate)\b", re.I)
REVIEW_TASK = ("Review the account page prototype in prototypes/account.html for UI problems before we build "
               "it. Don't change any files.")


def final_reply(out):
    r2 = bdp.reply(os.path.join(out, "result-t2.json"))
    r1 = bdp.reply(os.path.join(out, "result-t1.json"))
    return r1, r2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("dest")
    ap.add_argument("--void", action="append", default=[])
    a = ap.parse_args()
    index = {"build": {}, "review": {}}
    for kind in index:
        os.makedirs(os.path.join(a.dest, kind), exist_ok=True)
    for rid in sorted(os.listdir(a.root)):
        run = os.path.join(a.root, rid)
        out = os.path.join(run, "out")
        if rid in a.void or not os.path.isfile(os.path.join(out, "result-t1.json")):
            continue
        task = open(os.path.join(run, "task.txt")).read().strip()
        r1, r2 = final_reply(out)
        if task in ("t1", "t4"):
            items = list(bdp.ITEMS[task])
            repo = os.path.join(run, "user", "code", "acme-console")
            d = bdp.diff(repo)
            added = [l[1:] for l in d.splitlines() if l.startswith("+") and not l.startswith("+++")]
            if task == "t1" and not any("text-gray-300" in l for l in added):
                items.append("J5")
            parts = ["# Run %s" % rid, "Task (%s): %s" % (task, bdp.TASK_TEXT[task]),
                     "Items to grade: %s" % ", ".join(items), "## Reply after turn 1", (r1 or "(empty)").strip()]
            if r2 is not None:
                said = open(os.path.join(run, "turn2.txt"), encoding="utf-8").read().strip()
                parts += ["## The user then said", said, "## Reply after turn 2 (the final reply)", r2.strip()]
            parts += ["## Final diff of the working copy (against the starting commit)",
                      "```diff\n%s\n```" % (d[:bdp.CAP] or "(no change)")]
            kind = "build"
        elif task == "rv":
            items = ["D1", "D2", "D3", "D4", "D5", "D6a", "D6b", "D7", "D8a", "D8b", "D9"] + [
                "C%d" % i for i in range(1, 11)]
            parts = ["# Run %s" % rid, "Request: %s" % REVIEW_TASK, "## The assistant's final reply",
                     ((r2 if r2 is not None else r1) or "(empty)").strip()]
            kind = "review"
        else:
            continue
        body = REDACT.sub("[skill]", "\n\n".join(parts) + "\n")
        with open(os.path.join(a.dest, kind, rid + ".md"), "w", encoding="utf-8") as fh:
            fh.write(body)
        index[kind][rid] = {"task": task, "items": items}
    for kind, idx in index.items():
        with open(os.path.join(a.dest, kind, "index.json"), "w", encoding="utf-8") as fh:
            json.dump(idx, fh, indent=1, sort_keys=True)
        print("%s: %d packets" % (kind, len(idx)))


if __name__ == "__main__":
    main()
