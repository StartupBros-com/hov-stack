#!/usr/bin/env python3
"""CLAUDE.md adherence sweep — classify each rule as load-bearing or redundant.

Same 3-arm ablation as the package-manager experiment, generalised: measurement is
the agent's tool-call stream (--output-format stream-json), so no shims are needed
for rules whose sandbox has no external side effects.

  A_none  no CLAUDE.md
  B_full  entire CLAUDE.md
  C_rule  only the verbatim rule text

A vs C isolates the rule. B vs C tests dilution. A rule whose A_none baseline is
already compliant is REDUNDANT (the model does it anyway); one whose baseline fails
and whose C_rule passes is LOAD-BEARING.
"""
import os, sys, json, shutil, subprocess, time, argparse, collections, hashlib
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.path.dirname(os.path.abspath(__file__))
REP_OFFSET = int(os.environ.get("REP_OFFSET","0"))
sys.path.insert(0, ROOT)
from rules import RULES, CLAUDE_MD, child_env  # noqa: E402
import rules_v2  # noqa: E402,F401  (registers worktree_remote)

RUNS = os.path.join(ROOT, "sweep_runs")
LOGS = os.path.join(ROOT, "sweep_logs")
DISALLOW = "Bash(git push:*),Bash(git remote:*),Bash(gh:*),WebFetch,WebSearch"


def collect_tool_calls(stream_text):
    tcs, cost, turns, err = [], None, None, None
    for line in stream_text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        t = d.get("type")
        if t == "assistant":
            for b in (d.get("message") or {}).get("content") or []:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    tcs.append({"name": b.get("name"), "input": b.get("input") or {}})
        elif t == "result":
            cost = d.get("total_cost_usd")
            turns = d.get("num_turns")
            if d.get("is_error"):
                err = d.get("subtype") or "error"
    return tcs, cost, turns, err


def run_one(rule_key, arm_name, arm_text, rep, model, timeout=360):
    rule = RULES[rule_key]
    tag = f"{rule_key}__{arm_name}__{model}__r{rep}"
    cwd = os.path.join(RUNS, tag)
    shutil.rmtree(cwd, ignore_errors=True)
    os.makedirs(cwd, exist_ok=True)
    try:
        rule["build"](cwd)
    except Exception as e:
        return {"rule": rule_key, "arm": arm_name, "rep": rep, "model": model,
                "verdict": "NONE", "why": f"setup-failed:{e}", "cost_usd": 0, "dur": 0}

    env = child_env()
    cmd = ["claude", "--print", "--bare", "--output-format", "stream-json", "--verbose",
           "--model", model, "--dangerously-skip-permissions",
           "--disallowedTools", DISALLOW]
    if arm_text:
        cmd += ["--append-system-prompt", arm_text]
    cmd += ["-p", rule["prompt"]]

    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True,
                           text=True, timeout=timeout)
        out, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        out, rc = (e.stdout or b"").decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or ""), -9
    dur = time.time() - t0

    tcs, cost, turns, err = collect_tool_calls(out)
    verdict, why = rule["detect"](tcs)
    if err and verdict == "NONE":
        why = f"harness-error:{err}"

    os.makedirs(LOGS, exist_ok=True)
    with open(os.path.join(LOGS, tag + ".tools.json"), "w") as fh:
        json.dump([{"n": t["name"],
                    "i": (t["input"].get("command") or str(t["input"]))[:300]}
                   for t in tcs], fh, indent=1)
    shutil.rmtree(cwd, ignore_errors=True)

    return {"rule": rule_key, "arm": arm_name, "rep": rep, "model": model,
            "verdict": verdict, "why": why, "ntools": len(tcs), "turns": turns,
            "rc": rc, "dur": round(dur, 1), "cost_usd": cost}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--rules", default=",".join(RULES))
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--smoke", action="store_true")
    args = ap.parse_args()

    full = open(CLAUDE_MD, encoding="utf-8").read()
    print(f"CLAUDE.md {len(full.split()):,} words "
          f"sha={hashlib.sha256(full.encode()).hexdigest()[:12]}\n")
    keys = [k for k in args.rules.split(",") if k in RULES]
    for k in keys:
        r = RULES[k]["rule"]()
        print(f"  rule={k:13s} C_rule arm = {len(r.split()):3d} words")
        print(f"     {r.splitlines()[0][:120]}")
    print()

    if args.smoke:
        k = keys[0]
        print(json.dumps(run_one(k, "A_none", None, 0, args.model), indent=2))
        return

    jobs = []
    for k in keys:
        rule_text = RULES[k]["rule"]()
        for rep in range(REP_OFFSET, REP_OFFSET+args.reps):
            for an, at in (("A_none", None), ("B_full", full), ("C_rule", rule_text)):
                jobs.append((k, an, at, rep))
    print(f"running {len(jobs)} runs, {args.workers} parallel, model={args.model}\n")

    outp = os.path.join(ROOT, f"sweep_{args.model}.jsonl")
    results = []
    with open(outp, "a") as sink, ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = [ex.submit(run_one, k, an, at, r, args.model) for (k, an, at, r) in jobs]
        for f in as_completed(futs):
            r = f.result()
            results.append(r)
            sink.write(json.dumps(r) + "\n"); sink.flush()
            print(f"  {r['rule']:13s} {r['arm']:7s} r{r['rep']} -> {r['verdict']:5s} "
                  f"{str(r['why'])[:28]:28s} {r['dur']:6.1f}s ${r['cost_usd'] or 0:.4f}",
                  flush=True)

    print("\n" + "=" * 86)
    agg = collections.defaultdict(collections.Counter)
    for r in results:
        agg[(r["rule"], r["arm"])][r["verdict"]] += 1
    for k in keys:
        print(f"\n  rule={k}  ({RULES[k]['good_desc']})")
        for arm in ("A_none", "B_full", "C_rule"):
            c = agg[(k, arm)]
            n = sum(c.values())
            if n:
                print(f"    {arm:7s} GOOD {c['GOOD']}/{n}  BAD {c['BAD']}  NONE {c['NONE']}")
    tot = sum(r["cost_usd"] or 0 for r in results)
    print(f"\n  total ${tot:.2f} over {len(results)} runs -> {outp}")


if __name__ == "__main__":
    main()
