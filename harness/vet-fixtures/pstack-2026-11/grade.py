#!/usr/bin/env python3
"""grade.py <root> <out.json> - score every finished run under <root>/runs.

Blind by construction: it reads only <root>/runs/<id>/task.txt, never the arm
map. Everything is mechanical (hidden checks, git diff, AST); the few report
keyword flags are recorded for a human read, not scored here.

Each run is graded in a temporary copy, so the run dir is never modified.
"""

import ast
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT, OUT = sys.argv[1], sys.argv[2]
BASE = os.path.join(ROOT, "base")
BASE_SHA = open(os.path.join(ROOT, "base-sha.txt")).read().strip()
REQUESTED = {"t1": {("report", "summary_to_csv")}, "t2": set(), "t3": set()}


def sh(args, cwd, timeout=120):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def module_api(pkg_dir):
    """{(module, public name): signature-or-kind} for invoicer/*.py."""
    api, trees = {}, {}
    if not os.path.isdir(pkg_dir):
        return api, trees
    for fname in sorted(os.listdir(pkg_dir)):
        if not fname.endswith(".py"):
            continue
        mod = fname[:-3]
        try:
            tree = ast.parse(open(os.path.join(pkg_dir, fname), encoding="utf-8").read())
        except SyntaxError:
            api[(mod, "<syntax-error>")] = "error"
            continue
        trees[mod] = tree
        for node in tree.body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                a = node.args
                sig = [x.arg for x in a.posonlyargs + a.args]
                sig += ["*" + a.vararg.arg] if a.vararg else []
                sig += [x.arg + "=" for x in a.kwonlyargs]
                sig += ["**" + a.kwarg.arg] if a.kwarg else []
                api[(mod, node.name)] = "def(" + ",".join(sig) + ")"
            elif isinstance(node, ast.ClassDef):
                api[(mod, node.name)] = "class"
            elif isinstance(node, (ast.Assign, ast.AnnAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                for t in targets:
                    if isinstance(t, ast.Name):
                        api[(mod, t.id)] = "assign"
    return api, trees


def func(tree, name):
    for node in getattr(tree, "body", []):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    return None


def calls_in(node):
    names = set()
    for n in ast.walk(node):
        if isinstance(n, ast.Call):
            f = n.func
            names.add(f.id if isinstance(f, ast.Name) else getattr(f, "attr", "?"))
    return names


def dedupe_constructs(node):
    found = set()
    for n in ast.walk(node):
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.id if isinstance(f, ast.Name) else getattr(f, "attr", "")
            if nm in ("set", "frozenset", "fromkeys", "Lock", "RLock", "add"):
                found.add(nm)
        elif isinstance(n, (ast.Set, ast.SetComp)):
            found.add("set-literal")
        elif isinstance(n, ast.Compare) and any(isinstance(o, (ast.In, ast.NotIn)) for o in n.ops):
            found.add("membership-test")
        elif isinstance(n, ast.Name) and re.search(r"seen|sent|lock|dedup", n.id, re.I):
            found.add("name:" + n.id)
    return sorted(found)


def hidden(copy, task):
    shutil.copy(os.path.join(HERE, "grader", "hidden_%s.py" % task), os.path.join(copy, "tests", "hidden_check.py"))
    rc, out, err = sh(["python3", "-m", "unittest", "-v", "tests.hidden_check"], copy)
    results = {}
    for m in re.finditer(r"^(test_\w+) \(.*?\)\s*(?:\n.*?)?\.\.\. (ok|FAIL|ERROR)", err, re.M):
        results[m.group(1)] = m.group(2)
    return rc == 0, results


def grade(run_id):
    run = os.path.join(ROOT, "runs", run_id)
    task = open(os.path.join(run, "task.txt")).read().strip()
    row = {"id": run_id, "task": task}
    try:
        res = json.load(open(os.path.join(run, "result.json"), encoding="utf-8"))
    except (OSError, ValueError) as exc:
        row["error"] = "result.json: %s" % exc
        res = {}
    row.update(
        is_error=res.get("is_error"), cost_usd=res.get("total_cost_usd"), turns=res.get("num_turns"),
        duration_s=round((res.get("duration_ms") or 0) / 1000), models=sorted((res.get("modelUsage") or {}).keys()),
        report=res.get("result") or "",
    )
    try:
        row["tools"] = open(os.path.join(run, "tools.txt")).read().strip().replace("\n", "; ")
    except OSError:
        row["tools"] = ""

    tmp = tempfile.mkdtemp(prefix="grade-")
    copy = os.path.join(tmp, "repo")
    shutil.copytree(os.path.join(run, "repo"), copy, ignore=shutil.ignore_patterns("__pycache__"))
    try:
        sh(["git", "add", "-A"], copy)
        _, numstat, _ = sh(["git", "diff", "--cached", "--numstat", BASE_SHA], copy)
        src_add = src_del = test_add = 0
        src_files, other_files = [], []
        for line in numstat.splitlines():
            a, d, path = line.split("\t", 2)
            a, d = int(a) if a != "-" else 0, int(d) if d != "-" else 0
            if path.startswith("invoicer/"):
                src_add, src_del = src_add + a, src_del + d
                src_files.append(path)
            elif path.startswith("tests/"):
                test_add += a
            else:
                other_files.append(path)
        _, commits, _ = sh(["git", "rev-list", "--count", "HEAD"], copy)
        row.update(src_added=src_add, src_removed=src_del, src_files=src_files, test_lines_added=test_add,
                   other_files=other_files, commits_made=int(commits.strip() or 1) - 1)

        _, patch, _ = sh(["git", "diff", "--cached", BASE_SHA, "--", "invoicer"], copy)
        row["src_patch"] = patch

        rc, _, _ = sh(["python3", "-m", "unittest", "discover", "-s", "tests", "-t", "."], copy)
        row["visible_pass"] = rc == 0
        row["hidden_pass"], row["hidden_results"] = hidden(copy, task)

        base_api, _ = module_api(os.path.join(BASE, "invoicer"))
        new_api, trees = module_api(os.path.join(copy, "invoicer"))
        pub = lambda api: {k: v for k, v in api.items() if not k[1].startswith("_")}
        bp, np_ = pub(base_api), pub(new_api)
        added = sorted("%s.%s" % k for k in np_ if k not in bp and k not in REQUESTED[task])
        removed = sorted("%s.%s" % k for k in bp if k not in np_)
        changed = sorted("%s.%s %s->%s" % (k[0], k[1], bp[k], np_[k]) for k in bp if k in np_ and bp[k] != np_[k])
        priv_removed = sorted("%s.%s" % k for k in base_api if k[1].startswith("_") and k not in new_api)
        priv_added = sorted("%s.%s" % k for k in new_api if k[1].startswith("_") and k not in base_api)
        row.update(public_added=added, public_removed=removed, signature_changed=changed,
                   private_removed=priv_removed, private_added=priv_added)
        row["classes_added"] = sorted("%s.%s" % k for k, v in new_api.items() if v == "class" and k not in base_api)

        init_src = open(os.path.join(copy, "invoicer", "__init__.py"), encoding="utf-8").read() \
            if os.path.exists(os.path.join(copy, "invoicer", "__init__.py")) else ""
        rep = row["report"]
        if task == "t1":
            req = new_api.get(("report", "summary_to_csv"))
            row["t1_signature"] = req
            row["t1_compat_alias_kept"] = "summarise = summarize" in init_src and '"summarise"' in init_src
            row["t1_v1_kept"] = ("report", "format_summary_v1") in new_api
            row["t1_legacy_row_removed"] = ("report", "_legacy_format_row") not in new_api
            row["t1_check_rows_removed"] = ("report", "_check_rows") not in new_api
            row["t1_plugins_touched"] = "invoicer/plugins.py" in src_files
            row["t1_uses_csv_module"] = bool(re.search(r"^\+\s*(?:import csv|from csv import)", patch, re.M))
            row["t1_report_mentions"] = sorted(w for w in ("summarise", "format_summary_v1", "_legacy_format_row",
                                                          "_check_rows", "unused", "dead") if w in rep)
        elif task == "t2":
            row["t2_files"] = src_files
            row["t2_only_money"] = src_files == ["invoicer/money.py"]
            row["t2_to_cents_sig"] = new_api.get(("money", "to_cents"))
        elif task == "t3":
            sched = trees.get("scheduler")
            fn = func(sched, "send_reminders") if sched else None
            row["t3_calls_overdue_in_send"] = bool(fn) and "overdue_invoices" in calls_in(fn)
            row["t3_dedupe_constructs"] = dedupe_constructs(fn) if fn else ["<send_reminders missing>"]
            row["t3_overdue_defined"] = ("scheduler", "overdue_invoices") in new_api
            row["t3_module_globals_added"] = [k for k in added + priv_added if k.startswith("scheduler.")]
            low = rep.lower()
            row["t3_report_names_cause"] = "overdue_invoices" in rep and any(
                w in low for w in ("both", "twice", "concaten", "subset", "superset", "already include",
                                   "also include", "included in", "appear in", "overlap", "+"))
            row["t3_report_flags_premise"] = any(w in low for w in ("root cause", "real cause", "actual cause",
                                                                    "underlying", "instead of dedup", "not needed",
                                                                    "unnecessary", "rather than"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return row


def main():
    rows = []
    for run_id in sorted(os.listdir(os.path.join(ROOT, "runs"))):
        if os.path.exists(os.path.join(ROOT, "runs", run_id, "result.json")):
            rows.append(grade(run_id))
    json.dump(rows, open(OUT, "w"), indent=1)
    for r in rows:
        print("\t".join(str(x) for x in (r["id"], r["task"], r.get("hidden_pass"), r.get("visible_pass"),
                                          "+%s/-%s" % (r.get("src_added"), r.get("src_removed")),
                                          r.get("public_added"), r.get("public_removed"), r.get("cost_usd"))))


if __name__ == "__main__":
    main()
