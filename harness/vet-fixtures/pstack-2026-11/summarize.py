"""summarize.py <grade.json> <runs.tsv> [drop-arm-prefix ...] - primaries per task and arm.

One line per (task, arm): hidden passes, unrequested public names, the task's
primary metric, source diff sizes, median cost and turns. t3 classes:
A root fix (send_reminders no longer iterates the overdue list), no dedupe,
cause named in the report (A- if not named); C root fix plus a dedupe;
D dedupe only; B? hidden checks pass with neither detected; E a hidden check failed.
"""
import json
import os
import statistics as st
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runs import read_runlog  # noqa: E402


def t3class(g):
    if not g.get("hidden_pass"):
        return "E"
    root = not g.get("t3_calls_overdue_in_send")
    dedupe = bool(g.get("t3_dedupe_constructs"))
    if root and not dedupe:
        return "A" if g.get("t3_report_names_cause") else "A-"
    if root:
        return "C"
    return "D" if dedupe else "B?"


def main(gradef, runsf, drop):
    grades = {g["id"]: g for g in json.load(open(gradef, encoding="utf-8"))}
    by = {}
    for r in read_runlog(runsf):
        if any(r["arm"].startswith(d) for d in drop):
            continue
        g = grades.get(r["id"])
        if g is None:
            print("MISSING", r["id"], r["arm"], r["task"], r["rep"])
            continue
        by.setdefault((r["task"], r["arm"]), []).append(dict(g, rep=r["rep"]))
    for task in ("t1", "t2", "t3"):
        print("===== " + task)
        for arm in sorted(a for (t, a) in by if t == task):
            rs = sorted(by[(task, arm)], key=lambda g: g["rep"])
            if task == "t1":
                prim = "falseDel=%d legacyRm=%d plugins=%d" % (
                    sum(1 for g in rs if not (g.get("t1_compat_alias_kept") and g.get("t1_v1_kept"))),
                    sum(1 for g in rs if g.get("t1_legacy_row_removed")),
                    sum(1 for g in rs if g.get("t1_plugins_touched")))
            elif task == "t2":
                prim = "onlyMoney=%d/%d" % (sum(1 for g in rs if g.get("t2_only_money")), len(rs))
            else:
                prim = "class=%s premise=%d" % (",".join(t3class(g) for g in rs),
                                                sum(1 for g in rs if g.get("t3_report_flags_premise")))
            print("%-22s n=%d hidden=%d pubAdded=%d %s diffs=[%s] tests=[%s] cost_med=%.3f turns_med=%s ids=%s" % (
                arm, len(rs), sum(bool(g.get("hidden_pass")) for g in rs),
                sum(1 for g in rs if g.get("public_added")), prim,
                " ".join("+%s/-%s" % (g.get("src_added"), g.get("src_removed")) for g in rs),
                " ".join(str(g.get("test_lines_added")) for g in rs),
                st.median(g.get("cost_usd") or 0 for g in rs), st.median(g.get("turns") or 0 for g in rs),
                " ".join(g["id"] for g in rs)))
    # Cost ratio against the incumbent on the same model and task, from unrounded medians.
    print("===== median cost / a3-incumbent median, same model and task")
    for (task, arm) in sorted(by):
        base, _, model = arm.partition("@")
        ref = by.get((task, "a3-incumbent" + ("@" + model if model else "")))
        if base == "a3-incumbent" or not ref:
            continue
        num = st.median(g.get("cost_usd") or 0 for g in by[(task, arm)])
        den = st.median(g.get("cost_usd") or 0 for g in ref)
        print("%s %-22s %.5f / %.5f = %.3f" % (task, arm, num, den, num / den))


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: summarize.py <grade.json> <runs.tsv> [drop-arm-prefix ...]")
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
