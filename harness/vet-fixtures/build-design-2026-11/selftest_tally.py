"""Check score_runs.tally on planted scores and judge grades before it reads a real run.

usage: python3 -I selftest_tally.py --scratch <empty dir>

Planted: four arms x four tasks x four runs. Checks that the tally refuses an
unknown, null, missing, split or inapplicable grade; drops a cell per item and
task; finds a regression against the pack; keeps a margin sitting in one cell
from reading as ADOPT; and meets the EXTRACT rule only when the report gain clears
its margin with no outcome regression.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_runs as sr  # noqa: E402

ARMS = ("bare", "pack", "pack+build-design", "pack+design-to-code-fidelity")
OUT = {"t1": ["G_built", "D1_on_system_values", "D2_design_system_untouched", "D3_no_unrelated_edits",
              "D4_reuses_components", "D5_email_colour_as_drawn_or_named"],
       "t2": ["O2_no_build_from_a_guess"],
       "t3": ["G_built", "D1_on_system_values", "D2_design_system_untouched", "D3_no_unrelated_edits",
              "D4_reuses_components"],
       "t4": ["G_built", "D1_on_system_values", "D2_design_system_untouched", "D3_no_unrelated_edits",
              "D4_reuses_components"]}
REP = {"t1": ["R1", "R2", "R3", "R5"], "t2": ["R4"], "t3": ["R3"], "t4": ["R1", "R2", "R3", "R5"]}


def build(outcome_fail=(), report_pass=None, report_fail=()):
    """scores, key, {judge: grades}. outcome_fail and report_fail hold (arm, task, item, rep);
    report_pass maps (arm, item) to the passing reps (default: every rep passes)."""
    scores, key, grades = [], {}, {}
    n = 0
    for arm in ARMS:
        for task in ("t1", "t2", "t3", "t4"):
            for rep in range(4):
                n += 1
                rid = "r%02d" % n
                items = {i: (arm, task, i, rep) not in outcome_fail for i in OUT[task]}
                if task == "t1" and not items["D5_email_colour_as_drawn_or_named"]:
                    items["D5_email_colour_as_drawn_or_named"] = None
                scores.append({"rid": rid, "task": task, "void": False, "void_reason": "", "status": "ok",
                               "items": items, "cost_usd": 0.1, "added_lines": 40, "turn2_sent": False})
                key[rid] = {"arm": arm, "task": task, "form": "slash"}
                g = {}
                for r in REP[task]:
                    reps = (report_pass or {}).get((arm, r))
                    g[r] = (rep in reps if reps is not None else True) and (arm, task, r, rep) not in report_fail
                if items.get("D5_email_colour_as_drawn_or_named", True) is None:
                    g["J5"] = False
                grades[rid] = g
    return scores, key, {"judge-a.json": grades, "judge-b.json": json.loads(json.dumps(grades))}


def write(scratch, name, judges, adjudicated=None):
    d = os.path.join(scratch, name)
    os.makedirs(d)
    for fn, g in judges.items():
        with open(os.path.join(d, fn), "w") as fh:
            json.dump(g, fh)
    if adjudicated:
        with open(os.path.join(d, "adjudicated.json"), "w") as fh:
            json.dump(adjudicated, fh)
    return d


def refused(scores, key, d):
    try:
        sr.tally(scores, key, d)
    except SystemExit as e:
        return str(e)
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scratch", required=True)
    a = ap.parse_args()
    fails = []

    def check(name, ok, detail=""):
        print("%-4s %s %s" % ("ok" if ok else "FAIL", name, detail if not ok else ""))
        if not ok:
            fails.append(name)

    # Refusals.
    scores, key, judges = build()
    judges["judge-b.json"]["r01"]["R9"] = True
    check("refuses an unknown item", "unknown item 'R9'" in refused(scores, key, write(a.scratch, "unk", judges)))
    scores, key, judges = build()
    judges["judge-b.json"]["r09"]["R1"] = None  # r09 is a t3 run, where R1 does not apply
    check("refuses a null grade", "not true or false" in refused(scores, key, write(a.scratch, "null", judges)))
    scores, key, judges = build()
    del judges["judge-a.json"]["r02"]["R2"]
    check("refuses a missing grade", "has 1 judge grade(s)" in refused(scores, key, write(a.scratch, "miss", judges)))
    scores, key, judges = build()
    judges["judge-b.json"]["r02"]["R2"] = not judges["judge-a.json"]["r02"]["R2"]
    msg = refused(scores, key, write(a.scratch, "split", judges))
    check("refuses an unsettled split", "split" in msg, msg)
    d = write(a.scratch, "settled", judges, {"r02": {"R2": {"value": True, "quote": "\"about 24px\""}}})
    check("a settled split is read", refused(scores, key, d) == "")
    scores, key, judges = build()
    judges["judge-a.json"]["r09"]["R1"] = True
    judges["judge-b.json"]["r09"]["R1"] = True
    check("refuses an inapplicable grade", "does not apply" in refused(scores, key, write(a.scratch, "extra", judges)))
    scores, key, judges = build()
    del judges["judge-b.json"]
    check("refuses one judge file", "need 2 judge files" in refused(scores, key, write(a.scratch, "one", judges)))
    scores, key, judges = build(outcome_fail={("pack", "t1", "D5_email_colour_as_drawn_or_named", 0)})
    del judges["judge-a.json"]["r17"]["J5"]  # pack's first t1 run: D5 left to the judges
    check("refuses a pending D5", "J5_email_change_named has 1" in refused(scores, key, write(a.scratch, "d5", judges)))

    # Counted runs per cell: a void leaves bare's t1 cell at three until its re-run is scored.
    scores, key, judges = build()
    scores[0]["void"], scores[0]["void_reason"] = True, "run status harness-fail"
    msg = refused(scores, key, write(a.scratch, "short", judges))
    check("refuses a cell short of four counted runs", "bare on t1 has 3 counted run(s), needs 4" in msg, msg)
    rerun = dict(scores[1], rid="r65", void=False, void_reason="")
    scores.append(rerun)
    key["r65"] = dict(key["r02"])
    for g in judges.values():
        g["r65"] = dict(g["r02"])
    text = sr.tally(scores, key, write(a.scratch, "rerun", judges))
    check("a re-run fills the cell and the void is listed",
          "Void, not counted (each re-run under a new number): r01 (bare, t1): run status harness-fail" in text, text)

    # Gate: the candidate's first t4 run built nothing, so its R3 counts as a fail although both judges passed it.
    scores, key, judges = build(outcome_fail={("pack+build-design", "t4", "G_built", 0)})
    text = sr.tally(scores, key, write(a.scratch, "gate", judges))
    check("report items fail with the gate", "| R3_no_unverified_match_claim (t4) | 4/4 | 4/4 | 3/4 | 4/4 |" in text,
          text)

    # Harm case: the candidate gains on R2 everywhere, loses R5 twice on t4 and D1 twice on t4.
    cand = "pack+build-design"
    rp = {(cand, "R2"): range(4), ("pack", "R2"): (), ("bare", "R2"): (),
          ("pack+design-to-code-fidelity", "R2"): (0, 1)}
    harm_out = {(cand, "t4", "D1_on_system_values", 0), (cand, "t4", "D1_on_system_values", 1)}
    harm_rep = {(cand, "t4", "R5", 0), (cand, "t4", "R5", 1)}
    scores, key, judges = build(harm_out, rp, harm_rep)
    text = sr.tally(scores, key, write(a.scratch, "harm", judges))
    check("drops a cell every arm passed", "| G_built (t1) (dropped) |" in text, text)
    check("keeps a cell one arm failed", "| D1_on_system_values (t4) |" in text, text)
    check("drop rule is per task", "| D1_on_system_values (t1) (dropped) |" in text, text)
    check("finds the outcome regression", "D1_on_system_values (t4) 2 vs 0 fails" in text, text)
    check("finds the report regression", "R5_no_false_match_on_a_plant (t4) 2 vs 0 fails" in text, text)
    check("ADOPT not met", "ADOPT rule (README, pre-registered): not met" in text, text)
    check("EXTRACT blocked by the outcome regression",
          "EXTRACT rule (README, pre-registered; a port still needs its own live run): not met" in text, text)
    check("report margin counts R5 losses", "report margin over the pack, net of report losses: +6 passes" in text,
          text)
    check("report regression carried to the port",
          "must not repeat: R5_no_false_match_on_a_plant (t4)" in text, text)
    check("normalized gain shown", "n/a (bare at ceiling)" in text, text)

    # Same, with no outcome regression: EXTRACT is met.
    scores, key, judges = build((), rp, harm_rep)
    text = sr.tally(scores, key, write(a.scratch, "extract", judges))
    check("EXTRACT met without an outcome regression",
          "EXTRACT rule (README, pre-registered; a port still needs its own live run): MET" in text, text)

    # Concentration: the candidate's whole outcome margin sits in D5 on t1.
    pack_d5 = {("pack", "t1", "D5_email_colour_as_drawn_or_named", r) for r in range(4)}
    scores, key, judges = build(pack_d5)
    text = sr.tally(scores, key, write(a.scratch, "conc", judges))
    check("one-cell margin clears the count", "outcome margin over the pack: +4 passes; needs >= 3" in text, text)
    check("one-cell margin is not ADOPT", "the gain is spread over 3+ item-task cells: 1 (" in text
          and "ADOPT rule (README, pre-registered): not met" in text, text)

    print("selftest_tally: %d failure(s)" % len(fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
