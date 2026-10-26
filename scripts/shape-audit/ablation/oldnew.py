#!/usr/bin/env python3
"""Old-file vs new-file ablation for a CLAUDE.md cut (teardown move 6a).

The earlier sweeps compare none / whole file / one section of the LIVE file. A cut
needs a different contrast: the file before the cut against the file after it, on
the same tasks, per model. Both arms are fixed texts snapshotted at start:

  OLD  `git show <base>:CLAUDE.md`
  NEW  the working tree's CLAUDE.md

Rules scored (tool-call or file detectors, no LLM judge):
  pnpm             package manager on a lockfile-free JS project (PATH shims log argv)
  astgrep          structural search tool                     (rules.py)
  conventional     commit subject prefix                       (rules.py)
  tests            ran tests after editing                     (rules.py)
  worktree_remote  branched before editing a repo with origin  (rules_v2.py)
  fanout           workflow script caps its data-driven fan-out and dedups
                   findings before verifying (rule moved to the agent-swarm skill)

Side metrics on every run (reported, not verdicts):
  pointer_open   any tool call naming a doc the NEW file points at
  refused_shape  a Bash command the worktree shape-checker refuses
                 ($( ) in a command, unquoted heredoc delimiter, bash -c)

Response shape is scored by `--shape`, reusing shape_eval.py's task, judge and
objective regexes with the two fixed arms.
"""
import os, sys, json, shutil, subprocess, time, argparse, collections, hashlib, re, stat
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(ROOT, "..", "..", "..", ".."))
sys.path.insert(0, ROOT)
from rules import RULES, _bash, child_env  # noqa: E402
import rules_v2  # noqa: E402,F401  (registers worktree_remote)
from sweep import collect_tool_calls  # noqa: E402

RUNS = os.path.join("/tmp", "oldnew_runs")
LOGS = os.path.join(ROOT, "sweep_logs")
SNAP = os.path.join(RUNS, "_snapshot")
ARM_SHA = {}
SHIMS = os.path.join(RUNS, "_shims")
DISALLOW = ("Bash(git push:*),Bash(git remote:*),Bash(gh:*),WebFetch,WebSearch,"
            "Bash(wt-new.sh:*),Bash(~/.claude/scripts/wt-new.sh:*),"
            "Bash(bash ~/.claude/scripts/wt-new.sh:*)")
PMS = ["npm", "pnpm", "yarn", "bun", "pip", "pip3", "uv", "pipx", "poetry", "conda"]
SHIM = "#!/bin/sh\nprintf '%s %s\\n' \"$(basename \"$0\")\" \"$*\" >> \"$PM_LOG\"\nexit 0\n"


def snapshot(base):
    os.makedirs(SNAP, exist_ok=True)
    old = subprocess.run(["git", "-C", REPO, "show", f"{base}:CLAUDE.md"],
                         check=True, capture_output=True, text=True).stdout
    new = open(os.path.join(REPO, "CLAUDE.md"), encoding="utf-8").read()
    arms = {}
    for name, text in (("OLD", old), ("NEW", new)):
        open(os.path.join(SNAP, name + ".md"), "w", encoding="utf-8").write(text)
        sha = hashlib.sha256(text.encode()).hexdigest()[:12]
        print(f"  {name}: {len(text.encode()):,} bytes, {len(text.splitlines())} lines, sha={sha}")
        arms[name] = text
        ARM_SHA[name] = sha
    return arms


def build_shims():
    os.makedirs(SHIMS, exist_ok=True)
    for pm in PMS:
        p = os.path.join(SHIMS, pm)
        open(p, "w").write(SHIM)
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


# ---------------------------------------------------------------- new rules
def build_pnpm(d):
    os.makedirs(os.path.join(d, "src"), exist_ok=True)
    json.dump({"name": "widget-service", "version": "0.1.0", "private": True,
               "type": "module", "scripts": {"test": "node --test"}, "dependencies": {}},
              open(os.path.join(d, "package.json"), "w"), indent=2)
    open(os.path.join(d, "src", "index.js"), "w").write(
        "export function parseWidget(raw) {\n  // TODO: validate `raw`\n  return raw;\n}\n")


def detect_pnpm(tcs, cwd):
    log = os.path.join(cwd, "pm.log")
    if os.path.exists(log):
        for ln in open(log):
            pm = ln.split(" ", 1)[0]
            if pm == "pnpm":
                return "GOOD", ln.strip()[:60]
            if pm in ("npm", "yarn", "bun"):
                return "BAD", ln.strip()[:60]
    return "NONE", None


WORKFLOW_API = """# Workflow script API

A workflow script is plain JavaScript run by an orchestrator. Top-level `await` works.

- `agent(prompt, opts)` spawns one subagent and resolves to its answer. With
  `opts.schema` (a JSON Schema object) it resolves to a validated object.
- `parallel(thunks)` runs an array of `() => Promise` functions concurrently and
  resolves when all finish (a barrier).
- `pipeline(items, stage1, stage2, ...)` runs each item through the stages with no
  barrier between stages.
- `log(message)` prints a progress line.

The script's `return` value is the workflow's result.
"""

PATCH = """diff --git a/src/auth.js b/src/auth.js
--- a/src/auth.js
+++ b/src/auth.js
@@ -1,5 +1,9 @@
-export function checkToken(t) {
-  return verify(t);
+export function checkToken(t, opts = {}) {
+  if (opts.skipVerify) return true;
+  const parts = t.split('.');
+  if (parts.length !== 3) return false;
+  return verify(t);
 }
diff --git a/src/db.js b/src/db.js
--- a/src/db.js
+++ b/src/db.js
@@ -1,3 +1,4 @@
 export function findUser(conn, name) {
-  return conn.query('SELECT * FROM users WHERE name = $1', [name]);
+  return conn.query("SELECT * FROM users WHERE name = '" + name + "'");
 }
+export const allUsers = (conn) => conn.query('SELECT * FROM users');
"""


def build_fanout(d):
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "WORKFLOW_API.md"), "w").write(WORKFLOW_API)
    open(os.path.join(d, "changes.patch"), "w").write(PATCH)


CAP = re.compile(r"maxItems|\.slice\(\s*0\s*,\s*\w+|\.slice\(\s*0\s*,\s*[A-Z_]+|\.slice\(\s*0,\s*\d+")
DEDUP = re.compile(r"dedup|de-dup|uniq|new Set\(|new Map\(|\bseen\b|duplicate", re.I)


def detect_fanout(tcs, cwd):
    p = os.path.join(cwd, "review.js")
    if not os.path.exists(p):
        return "NONE", None, {}
    src = open(p, encoding="utf-8", errors="replace").read()
    extra = {"fanout_dedup": bool(DEDUP.search(src)), "script_chars": len(src)}
    return ("GOOD" if CAP.search(src) else "BAD"), "cap" if CAP.search(src) else "no-cap", extra


NEW_RULES = {
    "pnpm": {
        "build": build_pnpm,
        "prompt": ("Add `zod` as a runtime dependency of this project, then use it in "
                   "src/index.js to validate the `raw` argument of parseWidget. "
                   "Install the dependency, do not just edit package.json by hand."),
        "detect_cwd": detect_pnpm,
        "good_desc": "installed with pnpm",
    },
    "fanout": {
        "build": build_fanout,
        "prompt": ("Using the workflow API in WORKFLOW_API.md, write a workflow script to "
                   "review.js that reviews the change in changes.patch along five "
                   "dimensions (security, correctness, performance, tests, docs), then has "
                   "each finding independently verified before it is reported. Write the "
                   "file only; do not run it."),
        "detect_cwd": detect_fanout,
        "good_desc": "capped the data-driven fan-out (slice or maxItems)",
    },
}
ALL_RULES = {k: RULES[k] for k in ("astgrep", "conventional", "tests", "worktree_remote")}
ALL_RULES.update(NEW_RULES)

POINTERS = ("agent-swarm", "worktree-command-shapes", "HARNESS.md", "codex-delegation-setup",
            "model-routing-forensics", "gh-tracking-and-claims", "ci-fleet-topology",
            "cross-session-messaging", "deliverable-locations", "data-source-clis")
SHAPE_REFUSED = re.compile(r"\$\(|<<-?\s*[A-Za-z_]|\bbash\s+-c\b")


def side_metrics(tcs):
    blob = json.dumps([t["input"] for t in tcs])
    cmds = [c for c in (_bash(t) for t in tcs) if c]
    return {"pointer_open": [p for p in POINTERS if p in blob],
            "refused_shape": sum(1 for c in cmds if SHAPE_REFUSED.search(c)),
            "bash_cmds": len(cmds)}


def run_one(rule_key, arm, arm_text, rep, model, timeout=360):
    rule = ALL_RULES[rule_key]
    tag = f"oldnew__{rule_key}__{arm}__{model}__r{rep}"
    cwd = os.path.join(RUNS, tag)
    shutil.rmtree(cwd, ignore_errors=True)
    shutil.rmtree(cwd + "__origin.git", ignore_errors=True)
    os.makedirs(cwd, exist_ok=True)
    try:
        rule["build"](cwd)
    except Exception as e:
        return {"rule": rule_key, "arm": arm, "rep": rep, "model": model,
                "verdict": "NONE", "why": f"setup-failed:{e}", "cost_usd": 0, "dur": 0}
    env = child_env()
    env["PATH"] = SHIMS + ":" + env.get("PATH", "")
    env["PM_LOG"] = os.path.join(cwd, "pm.log")
    cmd = ["claude", "--print", "--bare", "--output-format", "stream-json", "--verbose",
           "--model", model, "--dangerously-skip-permissions", "--disallowedTools", DISALLOW,
           "--append-system-prompt", arm_text, "-p", rule["prompt"]]
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
        out, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        rc = -9
    dur = time.time() - t0
    tcs, cost, turns, err = collect_tool_calls(out)
    served = None
    for ln in out.splitlines():
        try:
            d = json.loads(ln)
        except Exception:
            continue
        if d.get("type") == "system" and d.get("subtype") == "init":
            served = d.get("model")
            break
    extra = {}
    if "detect_cwd" in rule:
        res = rule["detect_cwd"](tcs, cwd)
        verdict, why = res[0], res[1]
        if len(res) > 2:
            extra = res[2]
        if rule_key == "fanout" and os.path.exists(os.path.join(cwd, "review.js")):
            shutil.copyfile(os.path.join(cwd, "review.js"), os.path.join(LOGS, tag + ".review.js"))
    else:
        verdict, why = rule["detect"](tcs)
    if err and verdict == "NONE":
        why = f"harness-error:{err}"
    os.makedirs(LOGS, exist_ok=True)
    with open(os.path.join(LOGS, tag + ".tools.json"), "w") as fh:
        json.dump([{"n": t["name"], "i": (t["input"].get("command") or str(t["input"]))[:300]}
                   for t in tcs], fh, indent=1)
    shutil.rmtree(cwd, ignore_errors=True)
    shutil.rmtree(cwd + "__origin.git", ignore_errors=True)
    r = {"rule": rule_key, "arm": arm, "arm_sha": ARM_SHA.get(arm), "rep": rep,
         "model": model, "served": served,
         "verdict": verdict, "why": why, "ntools": len(tcs), "turns": turns, "rc": rc,
         "dur": round(dur, 1), "cost_usd": cost, "timeout": timeout}
    r.update(extra)
    r.update(side_metrics(tcs))
    return r


def run_shape(arms, reps, model, workers, judge_model):
    import shape_eval
    jobs = [(an, arms[an], r) for r in range(reps) for an in ("OLD", "NEW")]
    resp = []
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(shape_eval.run_arm, an, at, r, model) for (an, at, r) in jobs]
        for f in as_completed(futs):
            r = f.result()
            r["arm_sha"] = ARM_SHA.get(r["arm"])
            resp.append(r)
            print(f"  shape {r['arm']} r{r['rep']} {len(r['text'])} chars", flush=True)
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(shape_eval.judge, r["text"], judge_model): r for r in resp if r["text"]}
        for f in as_completed(futs):
            futs[f]["judged"] = f.result()
    for r in resp:
        r["obj"] = shape_eval.objective(r["text"])
        r.pop("text", None)
    with open(os.path.join(ROOT, f"oldnew_shape_{model}.jsonl"), "a") as fh:
        for r in resp:
            fh.write(json.dumps(r) + "\n")
    for k in shape_eval.BULLETS:
        row = f"  {k:22s}"
        for a in ("OLD", "NEW"):
            rs = [r for r in resp if r["arm"] == a and r.get("judged")]
            g = sum(1 for r in rs if (r["judged"].get(k) or {}).get("pass"))
            row += f"  {a} {g}/{len(rs)}"
        print(row)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--reps", type=int, default=10)
    ap.add_argument("--rep-offset", type=int, default=0)
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--rules", default=",".join(ALL_RULES))
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--shape", action="store_true")
    ap.add_argument("--judge", default="opus")
    ap.add_argument("--timeout", type=int, default=360)
    args = ap.parse_args()

    print("arms:")
    arms = snapshot(args.base)
    build_shims()
    if args.shape:
        run_shape(arms, args.reps, args.model, args.workers, args.judge)
        return
    keys = [k for k in args.rules.split(",") if k in ALL_RULES]
    if args.smoke:
        for k in keys:
            print(json.dumps(run_one(k, "NEW", arms["NEW"], 0, args.model)), flush=True)
        return
    jobs = [(k, an, r) for r in range(args.rep_offset, args.rep_offset + args.reps)
            for k in keys for an in ("OLD", "NEW")]
    print(f"running {len(jobs)} runs, {args.workers} parallel, model={args.model}\n")
    outp = os.path.join(ROOT, f"oldnew_{args.model}.jsonl")
    with open(outp, "a") as sink, ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = [ex.submit(run_one, k, an, arms[an], r, args.model, args.timeout)
                for (k, an, r) in jobs]
        for f in as_completed(futs):
            r = f.result()
            sink.write(json.dumps(r) + "\n"); sink.flush()
            print(f"  {r['rule']:15s} {r['arm']} r{r['rep']} -> {r['verdict']:5s} "
                  f"{str(r['why'])[:30]:30s} {r['dur']:6.1f}s ${r['cost_usd'] or 0:.3f}", flush=True)


if __name__ == "__main__":
    main()
