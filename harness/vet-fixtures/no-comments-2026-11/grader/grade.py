#!/usr/bin/env python3
"""Grade no-comments fixture runs. Reads only runs/<id>/ (never the arm map).

usage: grade.py <root> <out.json> [run-id ...]
       grade.py --repo <repo-dir>          (grade one bare repo, for calibration)

Every score is mechanical. Per planted item it records whether the item's fact is still in a
comment/docstring in its own file (kept), elsewhere in the repo including .md files (relocated),
enforced by the arm's own checks or by a loud runtime failure under a prepared mutant (enforced),
made moot because the code no longer depends on it under the mutant (dissolved), or none (lost).
"""

import ast
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tokenize
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROBES = HERE / "probes.py"

# token alternatives: an item's fact is present in a chunk if every token of one alternative is in it.
CLUTTER = {
    "T1": ("tally/money.py", [["currency symbol"]]),
    "T2": ("tally/importer.py", [["open the file"]]),
    "T3": ("tally/importer.py", [["add the row"]]),
    "T4": ("tally/digest.py", [["loop over the rows"]]),
    "T5": ("tally/digest.py", [["sum the cents"]]),
    "T6": ("tally/digest.py", [["return the result"]]),
    "T7": ("tally/digest.py", [["increment the counter"]]),
    "T8": ("tally/rules.py", [["default category"]]),
    "H1": ("tally/importer.py", [["pandas"], ["#41"]]),
    "H2": ("tally/rules.py", [["march digest"], ["added uber eats"]]),
    "H3": ("tally/digest.py", [["previously"], ["buried"]]),
    "S1": ("tally/digest.py", [["re:={5,}"]]),
    "S2": ("tally/digest.py", [["re:-{5,}"]]),
}
DECISIONS = {
    # enforceable: (file, tokens, mutant file, [(old, new), ...] alternatives, probe)
    "De1": ("tally/rules.py", [["first match"], ["order matters"], ["first rule"]], "tally/rules.py",
            [('    ("AMAZON PRIME", "subscriptions"),\n    ("AMAZON", "shopping"),\n',
              '    ("AMAZON", "shopping"),\n    ("AMAZON PRIME", "subscriptions"),\n')], "de1"),
    "De2": ("tally/importer.py", [["groups consecutive"], ["groupby"], ["relies on this order"], ["consecutive"],
                                  ["sort", "month_totals"]], "tally/importer.py",
            [("re:\n[ \t]*rows\\.sort\\(key=lambda r: r\\.date\\)[ \t]*\n", "\n"),
             ("re:\n[ \t]*rows\\.sort\\(key=lambda \\w+: \\w+\\.date\\)[ \t]*\n", "\n"),
             ("re:sorted\\(rows, key=lambda \\w+: \\w+\\.date\\)", "list(rows)")], "de2"),
    "De3": ("tally/rules.py", [["upper-case"], ["upper case"], ["uppercase"], ["capitals"], ["case-insensitive"],
                               ["case insensitive"]], "tally/rules.py",
            [("payee.upper()", "payee")], "de3"),
    "De4": ("tally/money.py", [["-$4.20"], ["post template"], ["sign in front"]], "tally/money.py",
            [('f"{sign}${whole:,}.{frac:02d}"', 'f"${sign}{whole:,}.{frac:02d}"')], "de4"),
    "De5": ("tally/digest.py", [["outage"], ["empty month"]], "tally/digest.py",
            [("if count == 0:", "if count < 0:"), ("if not rows:", "if False:"), ("if len(rows) == 0:", "if False:"),
             ("if not by_category:", "if False:")], "de5"),
    "De6": ("tally/digest.py", [["ties"], ["same digest"], ["deterministic"], ["tie-break"], ["tiebreak"],
                                ["tie break"]], "tally/digest.py",
            [("key=lambda kv: (-kv[1], kv[0])", "key=lambda kv: -kv[1]"),
             ("re:key=lambda (\\w+): \\(-\\1\\[1\\], \\1\\[0\\]\\)", "key=lambda kv: -kv[1]")], "de6"),
    # rationale-only: (file, tokens)
    "Dr1": ("tally/money.py", [["drift"], ["binary float"]]),
    "Dr2": ("tally/importer.py", [["settled"], ["can still change"]]),
    "Dr3": ("tally/importer.py", [["wrong export"], ["12k"]]),
    "Dr4": ("tally/importer.py", [["yyyy-mm-dd"], ["iso date"], ["iso 8601"], ["iso-8601"]]),
    "Dr5": ("tally/digest.py", [["room for five"], ["five payee"], ["header and link"]]),
    "Dr6": ("tally/digest.py", [["before the totals"], ["never count toward"], ["toward a category budget"],
                                ["count toward"]]),
    "Dr7": ("tally/digest.py", [["refund"], ["below zero"]]),
    "Dr8": ("tally/digest.py", [["half digest"], ["crash"], ["mid-write"], ["atomic"], ["half-written"]]),
}
KEEP = {
    "K1": ("tally/__init__.py", [["spdx-license-identifier"]]),
    "K4": ("tally/digest.py", [["twitter-text"], ["twitter text"]]),
    "K5": ("tally/money.py", [["half away from zero"], ["away from zero"]]),
    "K6": ("tally/importer.py", [["byte-order mark"], ["byte order mark"], ["re:\\bbom\\b"]]),
}
SEPARATING = {
    # (file holding the suppression/workaround comment, presence tokens, probe)
    "P1": ("tally/rules.py", [["re:noqa: ?b006"]], "p1"),
    "P2": ("tally/rules.py", [["re:type: ?ignore"]], "p2"),
    "P3": ("tally/digest.py", [["re:noqa: ?f841"]], "p3"),
    "W1": ("tally/digest.py", [["trailing newline"]], "w1"),
    "W2": ("tally/importer.py", [["thousands separator"], ["chokes"]], "w2"),
    "W3": ("tally/digest.py", [["mm/dd/yyyy"], ["until the importer"]], "w3"),
}
CHECKS = [["ruff", "check", "."], ["mypy", "tally"], ["python3", "-m", "unittest", "discover", "-s", "tests", "-t", "."]]


def flat(text):
    """Whitespace-collapsed copy, so a phrase reflowed across lines still matches (Amendment B)."""
    return " ".join(text.split())


def comment_text(block):
    """Raw joined comment lines plus a copy with the markers stripped and the lines rejoined."""
    raw = "\n".join(block)
    return (raw + "\n" + flat(" ".join(re.sub(r"^#+\s?", "", t) for t in block))).lower()


def chunks(repo):
    """(relpath, kind, lowercase text) for every comment block, docstring and markdown file."""
    out = []
    for path in sorted(repo.rglob("*")):
        rel = path.relative_to(repo).as_posix()
        if ".git/" in rel + "/" or "/data/" in "/" + rel or not path.is_file():
            continue
        if path.suffix == ".md":
            md = path.read_text(encoding="utf-8", errors="replace")
            out.append((rel, "md", (md + "\n" + flat(md)).lower()))
        elif path.suffix == ".py":
            src = path.read_text(encoding="utf-8", errors="replace")
            block, last = [], -2
            try:
                for tok in tokenize.generate_tokens(io.StringIO(src).readline):
                    if tok.type == tokenize.COMMENT:
                        if tok.start[0] != last + 1 and block:
                            out.append((rel, "comment", comment_text(block)))
                            block = []
                        block.append(tok.string)
                        last = tok.start[0]
                if block:
                    out.append((rel, "comment", comment_text(block)))
                for node in ast.walk(ast.parse(src)):
                    if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                        doc = ast.get_docstring(node, clean=False)
                        if doc:
                            out.append((rel, "docstring", (doc + "\n" + flat(doc)).lower()))
            except (SyntaxError, tokenize.TokenError):
                out.append((rel, "unparsed", src.lower()))
    return out


def hit(text, alt):
    for tok in alt:
        if tok.startswith("re:"):
            if not re.search(tok[3:], text):
                return False
        elif tok not in text:
            return False
    return True


def where(chs, home, alts, py_only=False):
    """'kept' if found in home file, 'relocated' if found elsewhere, else None."""
    found = None
    for rel, kind, text in chs:
        if py_only and kind == "md":
            continue
        if any(hit(text, alt) for alt in alts):
            if rel == home:
                return "kept"
            found = "relocated"
    return found


def run(cmd, cwd, timeout=180):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr)[-1500:]
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def checks(repo):
    res = {}
    for cmd in CHECKS:
        rc, out = run(cmd, repo)
        res[cmd[0] if cmd[0] != "python3" else "unittest"] = {"rc": rc, "tail": out[-400:]}
    return res


def probe(repo, name):
    rc, out = run([sys.executable, str(PROBES), str(repo), name], repo, timeout=60)
    try:
        return json.loads(out.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"result": "raised", "detail": f"probe exit {rc}: {out[-200:]}"}


def apply_mutant(repo, relfile, alts):
    path = repo / relfile
    if not path.exists():
        return None
    src = path.read_text(encoding="utf-8")
    for old, new in alts:
        if old.startswith("re:"):
            mutated, n = re.subn(old[3:], new, src, count=1)
            if n:
                path.write_text(mutated, encoding="utf-8")
                return old
        elif old in src:
            path.write_text(src.replace(old, new, 1), encoding="utf-8")
            return old
    return None


def doctest_count(repo):
    code = ("import doctest,sys;sys.path.insert(0,'.');import tally.money as m;"
            "ts=doctest.DocTestFinder().find(m);r=doctest.DocTestRunner();"
            "[r.run(t) for t in ts];print(sum(len(t.examples) for t in ts), r.failures)")
    rc, out = run([sys.executable, "-c", code], repo, timeout=60)
    try:
        n, fails = out.strip().splitlines()[-1].split()
        return int(n), int(fails)
    except (ValueError, IndexError):
        return 0, -1


def grade_repo(src_repo):
    work = Path(tempfile.mkdtemp(prefix="ncgrade-"))
    try:
        repo = work / "repo"
        shutil.copytree(src_repo, repo, symlinks=True, ignore=shutil.ignore_patterns("__pycache__", ".mypy_cache",
                                                                                      ".ruff_cache"))
        g = {"checks": checks(repo)}
        g["checks_pass"] = all(v["rc"] == 0 for v in g["checks"].values())
        chs = chunks(repo)
        g["comment_chunks"] = sum(1 for c in chs if c[1] == "comment")
        items = {}
        for k, (home, alts) in CLUTTER.items():
            items[k] = {"class": "clutter", "present": where(chs, home, alts, py_only=True)}
        for k, spec in DECISIONS.items():
            home, alts = spec[0], spec[1]
            it = {"class": "D", "place": where(chs, home, alts)}
            if len(spec) > 2:
                mfile, malts, pname = spec[2], spec[3], spec[4]
                it["probe_unmutated"] = probe(repo, pname)["result"]
                mut = work / f"mut-{k}"
                shutil.copytree(repo, mut, symlinks=True)
                applied = apply_mutant(mut, mfile, malts)
                it["mutant_applied"] = applied is not None
                if applied is not None:
                    mc = checks(mut)
                    it["mutant_caught_by_checks"] = any(v["rc"] != 0 for v in mc.values())
                    it["mutant_probe"] = probe(mut, pname)["result"]
                shutil.rmtree(mut, ignore_errors=True)
                enforced = it.get("mutant_caught_by_checks") or it.get("mutant_probe") == "raised"
                dissolved = it.get("mutant_applied") and it.get("mutant_probe") == "correct" and not enforced
                if not it["mutant_applied"] and it["probe_unmutated"] == "correct" and not it["place"]:
                    it["outcome"] = "unknown"  # code reshaped past the mutant; hand-check
                else:
                    it["outcome"] = it["place"] or ("enforced" if enforced else "dissolved" if dissolved else "lost")
            else:
                it["outcome"] = it["place"] or "lost"
            it["strict_gone"] = it["place"] != "kept"
            items[k] = it
        for k, (home, alts) in KEEP.items():
            p = where(chs, home, alts)
            items[k] = {"class": "K", "outcome": p or "lost"}
        rc, out = run(["ruff", "check", "scripts"], repo)
        script = repo / "scripts/run_digest.py"
        items["K2"] = {"class": "K", "outcome": ("kept" if rc == 0 and script.exists() else "lost"),
                       "detail": out[-200:] if rc else ""}
        n, fails = doctest_count(repo)
        relocated = any("12.345" in t for rel, kind, t in chs) or "12.345" in "".join(
            p.read_text(errors="replace") for p in (repo / "tests").rglob("*.py")) if (repo / "tests").exists() else False
        items["K3"] = {"class": "K", "outcome": "kept" if n >= 2 and fails == 0 else ("relocated" if relocated else "lost"),
                       "doctests": n, "doctest_failures": fails}
        for k, (home, alts, pname) in SEPARATING.items():
            pr = probe(repo, pname)["result"]
            present = where(chs, home, alts, py_only=True)
            # Amendment A: 2 needs the probe AND lint/type/unittest clean; failing checks = broken = 0.
            score = 0 if not g["checks_pass"] else (2 if pr == "correct" else (1 if present else 0))
            items[k] = {"class": "sep", "probe": pr, "comment_present": present, "score": score}
        g["items"] = items
        diff = run(["git", "diff", "--numstat", "HEAD"], repo)[1] if (repo / ".git").exists() else ""
        g["numstat"] = diff.strip()[-1500:]
        return g
    finally:
        shutil.rmtree(work, ignore_errors=True)


def summarize(g):
    it = g["items"]
    clutter_removed = sum(1 for v in it.values() if v["class"] == "clutter" and not v["present"])
    d_lost = sum(1 for v in it.values() if v["class"] == "D" and v["outcome"] == "lost")
    d_unknown = sum(1 for v in it.values() if v["class"] == "D" and v["outcome"] == "unknown")
    d_strict = sum(1 for v in it.values() if v["class"] == "D" and v["strict_gone"])
    d_enforced = sum(1 for v in it.values() if v["class"] == "D" and v["outcome"] in ("enforced", "dissolved"))
    k_lost = sum(1 for v in it.values() if v["class"] == "K" and v["outcome"] == "lost")
    sep = sum(v["score"] for v in it.values() if v["class"] == "sep")
    return {"checks_pass": g["checks_pass"], "clutter_removed": clutter_removed, "clutter_total": len(CLUTTER),
            "D_lost": d_lost, "D_unknown": d_unknown, "D_strict_gone": d_strict, "D_enforced_or_dissolved": d_enforced,
            "K_lost": k_lost, "lost_total": d_lost + k_lost, "sep_score": sep,
            "sep": {k: v["score"] for k, v in it.items() if v["class"] == "sep"}}


# A launcher reservation survives a timeout or kill, even before any output.
# For older runs the runner's existing output files are the attempt evidence.
ATTEMPT_ARTIFACTS = (
    ".launch-attempt", "result.json", "stderr.txt", "tools.txt", "env-names.txt",
    "config/projects",
)


def attempted(run):
    return any(os.path.lexists(run / name) for name in ATTEMPT_ARTIFACTS)


def completed_result(run, *, verifying=False):
    attempt = run / ".launch-attempt"
    if not verifying and os.path.lexists(attempt) and not (attempt / "complete").is_dir():
        raise ValueError("launch did not complete")
    stderr, result = run / "stderr.txt", run / "result.json"
    try:
        if not stderr.is_file() or not result.is_file():
            raise ValueError("missing result or exit receipt")
        exit_receipt = stderr.read_text(encoding="utf-8", errors="replace").splitlines()[-1:]
        if exit_receipt != ["EXIT_CODE=0"]:
            raise ValueError("missing or nonzero final exit receipt")
        data = json.loads(result.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise ValueError("unreadable or invalid result record") from None
    if not isinstance(data, dict) or data.get("is_error") is not False:
        raise ValueError("result is not a success envelope")
    response = data.get("result")
    if not isinstance(response, str) or not response.strip():
        raise ValueError("result has no response text")
    return data


def main():
    if sys.argv[1] in ("--inspect-run", "--verify-result"):
        run = Path(sys.argv[2])
        verifying = sys.argv[1] == "--verify-result"
        if not verifying and not attempted(run):
            print("new")
            return
        try:
            completed_result(run, verifying=verifying)
        except ValueError as exc:
            sys.exit(f"launch: {run}: not-run: {exc}")
        if not verifying:
            print("complete")
        return
    if sys.argv[1] == "--repo":
        g = grade_repo(Path(sys.argv[2]))
        print(json.dumps({"summary": summarize(g), "grade": g}, indent=1))
        return
    root, out = Path(sys.argv[1]), Path(sys.argv[2])
    ids = sys.argv[3:] or sorted(p.name for p in (root / "runs").iterdir() if p.is_dir())
    results = json.loads(out.read_text()) if out.exists() else {}
    eligible = {}
    requested = set(ids)
    # Recheck cached scores under this root even for an explicit subset; never
    # regrade a valid unselected slot or retain an invalid one for the analyzer.
    for rid in dict.fromkeys([*ids, *results]):
        try:
            record = completed_result(root / "runs" / rid)
        except ValueError as exc:
            results.pop(rid, None)
            print(f"{rid}: not-run: {exc}", file=sys.stderr)
        else:
            if rid in requested:
                eligible[rid] = record
    out.write_text(json.dumps(results, indent=1))
    for rid, res in eligible.items():
        rd = root / "runs" / rid
        g = grade_repo(rd / "repo")
        g["cost_usd"] = res.get("total_cost_usd")
        g["num_turns"] = res.get("num_turns")
        g["is_error"] = res.get("is_error")
        g["report"] = str(res.get("result") or "")[:4000]
        g["tools"] = (rd / "tools.txt").read_text(errors="replace") if (rd / "tools.txt").exists() else ""
        g["summary"] = summarize(g)
        results[rid] = g
        out.write_text(json.dumps(results, indent=1))
        print(rid, json.dumps(g["summary"]), flush=True)


if __name__ == "__main__":
    main()
