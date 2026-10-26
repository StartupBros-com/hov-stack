#!/usr/bin/env python3
"""Parallel runner for the CLAUDE.md package-manager ablation.

Snapshots CLAUDE.md once at start so the arm text is fixed and reproducible even
if the live file is edited mid-run.
"""
import os, sys, json, subprocess, time, argparse, collections, shutil, hashlib
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
from rules import child_env  # noqa: E402

SHIMS = os.path.join(ROOT, "shims")
WORK = os.path.join(ROOT, "work")
LOGS = os.path.join(ROOT, "logs")
SNAP = os.path.join(ROOT, "snapshot")
CLAUDE_MD = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "CLAUDE.md")
PKG_SECTION = os.path.join(ROOT, "pkg_section.md")

TASKS = {
    "js": {
        "sub": "js",
        "prompt": ("Add `zod` as a runtime dependency of this project, then use it in "
                   "src/index.js to validate the `raw` argument of parseWidget. "
                   "Install the dependency, do not just edit package.json by hand."),
        "good": {"pnpm"}, "bad": {"npm", "yarn", "bun"},
    },
    "py": {
        "sub": "py",
        "prompt": ("Add `httpx` as a dependency of this project, then implement "
                   "fetch_report in src/fetch.py using it. "
                   "Install the dependency, do not just edit pyproject.toml by hand."),
        "good": {"uv"}, "bad": {"pip", "pip3", "poetry", "conda"},
    },
}
DISALLOW = ("Bash(git push:*),Bash(git commit:*),Bash(git remote:*),Bash(gh:*),"
            "WebFetch,WebSearch")


def snapshot():
    os.makedirs(SNAP, exist_ok=True)
    dst = os.path.join(SNAP, "CLAUDE.md")
    shutil.copyfile(CLAUDE_MD, dst)
    shutil.copyfile(PKG_SECTION, os.path.join(SNAP, "pkg_section.md"))
    full = open(dst, encoding="utf-8").read()
    rule = open(os.path.join(SNAP, "pkg_section.md"), encoding="utf-8").read()
    print(f"snapshot: CLAUDE.md {len(full.split()):,} words "
          f"sha={hashlib.sha256(full.encode()).hexdigest()[:12]}")
    print(f"snapshot: pkg section {len(rule.split()):,} words")
    return {"A_none": None, "B_full": full, "C_rule": rule}


def isolated_workdir(task_key, tag):
    """Each run gets a pristine copy so runs cannot contaminate each other."""
    src = os.path.join(WORK, TASKS[task_key]["sub"])
    dst = os.path.join(ROOT, "runs", tag)
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copytree(src, dst)
    return dst


def run_one(task_key, arm_name, arm_text, rep, model, timeout=360):
    task = TASKS[task_key]
    os.makedirs(LOGS, exist_ok=True)
    tag = f"{task_key}__{arm_name}__{model}__r{rep}"
    pm_log = os.path.join(LOGS, tag + ".pm.log")
    open(pm_log, "w").close()
    cwd = isolated_workdir(task_key, tag)

    env = child_env()
    env["PATH"] = SHIMS + os.pathsep + env.get("PATH", "")
    env["PM_LOG"] = pm_log

    cmd = ["claude", "--print", "--bare", "--output-format", "json",
           "--model", model, "--dangerously-skip-permissions",
           "--disallowedTools", DISALLOW]
    if arm_text:
        cmd += ["--append-system-prompt", arm_text]
    cmd += ["-p", task["prompt"]]

    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True,
                           text=True, timeout=timeout)
        out, err, rc = p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        out, err, rc = "", "TIMEOUT", -9
    dur = time.time() - t0

    calls = [l.strip() for l in open(pm_log).read().splitlines() if l.strip()]
    bins = [c.split()[0] for c in calls]
    universe = task["good"] | task["bad"]
    first_pm = next((b for b in bins if b in universe), None)
    used = sorted(set(b for b in bins if b in universe))

    cost = None
    try:
        cost = json.loads(out).get("total_cost_usd")
    except Exception:
        pass
    with open(os.path.join(LOGS, tag + ".raw.json"), "w") as fh:
        fh.write(out or "")
    if err:
        with open(os.path.join(LOGS, tag + ".err.txt"), "w") as fh:
            fh.write(err[:8000])
    shutil.rmtree(cwd, ignore_errors=True)

    return {"task": task_key, "arm": arm_name, "model": model, "rep": rep,
            "rc": rc, "dur": round(dur, 1), "calls": calls, "used": used,
            "first_pm": first_pm,
            "verdict": ("GOOD" if first_pm in task["good"]
                        else "BAD" if first_pm in task["bad"] else "NONE"),
            "cost_usd": cost, "err": (err or "")[:200]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--tasks", default="js,py")
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()

    A = snapshot()
    jobs = [(t, an, at, r)
            for t in args.tasks.split(",")
            for r in range(args.reps)
            for an, at in A.items()]
    print(f"\nrunning {len(jobs)} runs, {args.workers} parallel, model={args.model}\n")

    outp = os.path.join(ROOT, f"results_{args.model}.jsonl")
    results = []
    with open(outp, "a") as sink, ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(run_one, t, an, at, r, args.model): (t, an, r)
                for (t, an, at, r) in jobs}
        for f in as_completed(futs):
            r = f.result()
            results.append(r)
            sink.write(json.dumps(r) + "\n")
            sink.flush()
            print(f"  {r['task']:3s} {r['arm']:7s} r{r['rep']} -> {r['verdict']:5s} "
                  f"first={str(r['first_pm']):5s} used={','.join(r['used']) or '-':12s} "
                  f"{r['dur']:6.1f}s ${r['cost_usd'] or 0:.4f}", flush=True)

    print("\n" + "=" * 86)
    print("PACKAGE-MANAGER ADHERENCE BY ARM")
    print("=" * 86)
    agg = collections.defaultdict(collections.Counter)
    for r in results:
        agg[(r["task"], r["arm"])][r["verdict"]] += 1
    for task in args.tasks.split(","):
        good = TASKS[task]["good"]
        print(f"\n  task={task}  (compliant = {'/'.join(sorted(good))})")
        for arm in ("A_none", "B_full", "C_rule"):
            c = agg[(task, arm)]
            n = sum(c.values())
            if not n:
                continue
            print(f"    {arm:7s}  GOOD {c['GOOD']}/{n}   BAD {c['BAD']}   NONE {c['NONE']}")
    tot = sum(r["cost_usd"] or 0 for r in results)
    print(f"\n  total cost ${tot:.3f} over {len(results)} runs  ->  {outp}")


if __name__ == "__main__":
    main()
