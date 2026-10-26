#!/usr/bin/env python3
"""Accept a batch of `claude -p --output-format json` arm runs, or name what failed.

Usage: check-arms.py OUT RUNS ARM [ARM ...]

The runner persisted each slot's CLI exit status as OUT/<arm>-<n>.rc and its
envelope as OUT/<arm>-<n>.json, for n in 1..RUNS. A slot counts only when it
exited 0, the envelope parses, is_error is false, and result is a non-empty
string. The run is accepted only when every slot counts and no result file
outside the expected set is present (a stale file would otherwise be scored):
exactly RUNS x len(ARMS) successes. Anything else prints each problem and
exits 1 so the caller stops before its results summary (dotfiles#1683 round 1
P2, #1690). Messages are prefixed `run-arms:` because every caller is a
run-arms.sh.
"""
import json
import os
import sys


def main(argv):
    if len(argv) < 4:
        print("usage: check-arms.py OUT RUNS ARM [ARM ...]", file=sys.stderr)
        return 2
    out = argv[1]
    try:
        runs = int(argv[2])
    except ValueError:
        print("check-arms: RUNS must be an integer, got %r" % argv[2], file=sys.stderr)
        return 2
    arms = argv[3:]
    expected = runs * len(arms)
    expected_names = {"%s-%s.json" % (arm, n) for arm in arms for n in range(1, runs + 1)}
    ok = 0
    problems = []

    for name in sorted(n for n in os.listdir(out) if n.endswith(".json")):
        if name not in expected_names:
            problems.append("%s: unexpected result file" % name)

    for arm in arms:
        for n in range(1, runs + 1):
            slot = "%s-%s" % (arm, n)
            rc_path = os.path.join(out, slot + ".rc")
            js_path = os.path.join(out, slot + ".json")
            try:
                rc = open(rc_path, encoding="utf-8").read().strip()
            except OSError as exc:
                problems.append("%s: missing exit status (%s)" % (slot, exc))
                continue
            if rc != "0":
                problems.append("%s: exit=%s" % (slot, rc))
                continue
            try:
                with open(js_path, encoding="utf-8") as fh:
                    data = json.load(fh)
            except (OSError, json.JSONDecodeError) as exc:
                problems.append("%s: lacks a valid result (%s)" % (slot, exc))
                continue
            if not isinstance(data, dict) or data.get("is_error") is not False:
                shown = data.get("is_error") if isinstance(data, dict) else type(data).__name__
                flag = "true" if shown is True else shown
                problems.append("%s: is_error=%s" % (slot, flag))
                continue
            result = data.get("result")
            if not isinstance(result, str) or not result.strip():
                problems.append("%s: lacks a valid result" % slot)
                continue
            ok += 1

    if problems or ok != expected:
        for line in problems:
            print("run-arms: " + line, file=sys.stderr)
        print("run-arms: %s successful results, expected %s" % (ok, expected), file=sys.stderr)
        return 1
    print("run-arms: %s successful results (RUNS x %s)" % (ok, len(arms)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
