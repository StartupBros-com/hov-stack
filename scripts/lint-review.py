#!/usr/bin/env python3
"""Read-only lint review across many repositories: which suppressions still do anything, which rules people
route around, and which candidate rules earn a place.

  lint-review.py suppressions <root>... [--json FILE] [--ruff CMD | --no-ruff] [--stamp-min N] [--top N]
  lint-review.py admit <root>... --rules ruff:F821,oxlint:no-unused-vars --out FILE [--per-rule N] [--seed N]
                                 [--ruff CMD] [--oxlint CMD]
  lint-review.py score <labels.json>

A <root> is a git checkout, or a directory whose immediate children are git checkouts, so a new repository is
covered with no setup. Only tracked, hand-written source files are read: generated, vendored and build paths
are skipped (--exclude adds a pattern). Nothing is written to any repository and no linter runs with --fix, so
a re-run is always safe. CMD is split like a shell word list, e.g. --ruff "uvx ruff@0.17.3".

suppressions: every inline suppression (ruff/flake8 noqa, eslint/oxlint/biome disables, ts-ignore and
ts-expect-error, mypy type: ignore, pyright ignore, shellcheck disable), labelled two ways.
  state   For ruff noqa codes ruff itself decides, under each repo's own configuration: `dead` when RUF100 says
          the directive suppresses nothing there (the rule is not enabled, or the line no longer violates it),
          `live` when it does, `unchecked` when the repo's config excludes the file, `unparsed` when ruff cannot
          parse the file, `unknown-code` when the code is not one this ruff implements (a flake8 plugin's, or a
          removed rule's). Every other tool's suppressions are `not-measured`.
  reason  `same-line` (text after the directive), `line-above` (a comment directly above it; it may describe
          the code rather than the suppression, so it is an upper bound), `stamp` (one text on --stamp-min or
          more suppressions of the same rule, as a codemod leaves) or `none`.
Each repo also gets its ruff configs, whether each pins a rule set (`select`) or builds on the installed ruff's
defaults, and any ruff version the repo pins. A repo on the defaults changes behaviour when ruff changes them:
ruff 0.16 grew the default set from 59 rules to about 400 and dropped E402.
A rule with many live or unmeasured suppressions that give no reason is being routed around and needs a
decision; a rule whose suppressions are mostly dead only needs its comments removed.

admit: runs only the candidate rules (ruff with --isolated; oxlint with every other rule off) over tracked
hand-written files, counts hits per rule and repo, and writes a seeded sample per rule, spread round-robin
across repos, for refute-by-default judging. It judges nothing.

score: applies the admission bar to judge labels, {"<rule>": ["real_defect" | "latent_risk" | "false_positive",
...]}. With n labels and useful = real_defect + latent_risk: ADMIT when n >= 5, useful >= 0.8 n and at least one
real_defect; NOISE when n >= 5 and useful <= 0.2 n; UNDETERMINED otherwise. Write the bar down before reading
any verdict; judges told to default to false_positive bias counts down, so NOISE is the weaker call.

Retire this script when two consecutive re-runs (one per ruff or oxlint release) change no decision.
"""

import argparse
import collections
import json
import os
import random
import re
import shlex
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

GENERATED = re.compile(
    r"(^|/)(dist|build|out|vendor|vendored|third_party|node_modules|generated|evidence|runs|artifacts|snapshots|"
    r"\.venv|site-packages|\.claude/worktrees)/|\.min\.|_pb2\.py$|database\.types\.ts$|\.generated\.")
SOURCE = re.compile(r"\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|py|sh|bash)$")
JS = re.compile(r"\.(ts|tsx|js|jsx|mjs|cjs|mts|cts)$")
RULE = r"[@\w][\w@/.-]*"
RULES = RULE + r"(?:[ \t]*,[ \t]*" + RULE + r")*"
PATTERNS = [
    ("eslint", re.compile(r"eslint-disable(?:-next-line|-line)?(?:[ \t]+(" + RULES + r"))?")),
    ("oxlint", re.compile(r"oxlint-disable(?:-next-line|-line)?(?:[ \t]+(" + RULES + r"))?")),
    ("biome", re.compile(r"biome-ignore(?:-all|-start)?[ \t]+(" + RULE + r")")),
    ("typescript", re.compile(r"@(ts-ignore|ts-expect-error|ts-nocheck)\b")),
    ("ruff", re.compile(r"#[ \t]*(?i:noqa)(?::[ \t]*([A-Z]+[0-9]+(?:(?:[ \t]*,[ \t]*|[ \t]+)[A-Z]+[0-9]+)*))?")),
    ("mypy", re.compile(r"#[ \t]*type:[ \t]*ignore(?:\[([\w,-]+(?:[ \t]*,[ \t]*[\w-]+)*)\])?")),
    ("pyright", re.compile(r"#[ \t]*pyright:[ \t]*ignore(?:\[([\w,]+)\])?")),
    ("shellcheck", re.compile(r"shellcheck[ \t]+disable=(SC[0-9]+(?:,SC[0-9]+)*)")),
]
PREFILTER = re.compile(r"disable|ignore|noqa|@ts-", re.IGNORECASE)
DIRECTIVE = re.compile(r"noqa|type:\s*ignore|pyright:|eslint-disable|oxlint-disable|biome-ignore|@ts-|"
                       r"shellcheck\s+disable", re.IGNORECASE)
COMMENT_LEADER = re.compile(r"^\s*(#|//|\{?/\*+|\*)")
ALL_RULES = "(all rules)"
RUF100_PART = re.compile(r"(unused|non-enabled|disabled|unknown|duplicated):\s*([^;)]*)")
CHUNK = 400


def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)


def chunks(items, n=CHUNK):
    for i in range(0, len(items), n):
        yield items[i:i + n]


def discover(roots):
    repos = []
    for root in roots:
        p = Path(root).expanduser().resolve()
        if (p / ".git").exists():
            repos.append(p)
        elif p.is_dir():
            repos.extend(sorted(c for c in p.iterdir() if c.is_dir() and (c / ".git").exists()))
        else:
            sys.exit(f"lint-review: not a directory: {root}")
    return repos


def tracked(repo, extra_exclude):
    out = run(["git", "-C", str(repo), "ls-files", "-z"]).stdout
    files = [f for f in out.split("\0") if f]
    return [f for f in files if SOURCE.search(f) and not GENERATED.search(f)
            and not (extra_exclude and extra_exclude.search(f))]


def read_lines(path):
    try:
        if path.stat().st_size > 3_000_000:
            return None
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None


def clean_reason(text):
    t = re.sub(r"\*/\}?\s*$", "", text.strip()).strip()
    t = t.lstrip("-–—:;,#/* \t").strip()
    if not t or DIRECTIVE.search(t) or not re.search(r"[A-Za-z]{3,}", t):
        return ""
    return t


def find_suppressions(lines):
    """Yield (line_no, tool, rules, reason_kind, reason_text) for every suppression in a file."""
    for i, line in enumerate(lines):
        if not PREFILTER.search(line):
            continue
        for tool, pat in PATTERNS:
            for m in pat.finditer(line):
                g = m.group(1)
                if tool == "typescript":
                    rules = [g]
                else:
                    rules = [r for r in re.split(r"[,\s]+", g.strip()) if r] if g else [ALL_RULES]
                kind, text = "none", ""
                same = clean_reason(line[m.end():])
                if same:
                    kind, text = "same-line", same
                elif i > 0 and COMMENT_LEADER.match(lines[i - 1]):
                    above = clean_reason(COMMENT_LEADER.sub("", lines[i - 1], count=1))
                    if above:
                        kind, text = "line-above", above
                yield i + 1, tool, rules, kind, text


def ruff_cmd(spec):
    cmd = shlex.split(spec)
    if not cmd or not shutil.which(cmd[0]):
        return None
    return cmd


def dead_codes(message):
    if "blanket" in message:
        return {ALL_RULES}
    out = set()
    for _, group in RUF100_PART.findall(message):
        out.update(re.findall(r"`([^`]+)`", group))
    return out


def ruff_states(repo, files, ruff):
    """For each file: whether ruff checks it under the repo's config, whether it parses, and dead codes per line."""
    checked, unparsed, errors = set(), set(), []
    dead = collections.defaultdict(lambda: collections.defaultdict(set))
    for part in chunks(files):
        shown = run([*ruff, "check", "--show-files", "--force-exclude", "--no-cache", *part], cwd=repo)
        checked.update(os.path.realpath(s.strip()) for s in shown.stdout.splitlines() if s.strip())
        r = run([*ruff, "check", "--no-cache", "--exit-zero", "--force-exclude", "--extend-select", "RUF100",
                 "--output-format", "json", *part], cwd=repo)
        try:
            diags = json.loads(r.stdout or "[]")
        except json.JSONDecodeError:
            errors.append((r.stderr or r.stdout).strip().splitlines()[:1])
            continue
        for d in diags:
            f = os.path.realpath(os.path.join(repo, d["filename"]))
            code = d.get("code")
            if code in (None, "invalid-syntax") or str(d.get("message", "")).startswith("SyntaxError"):
                unparsed.add(f)
            elif code == "RUF100":
                dead[f][d["location"]["row"]] |= dead_codes(d.get("message", ""))
    return checked, unparsed, dead, errors


def ruff_profile(repo, all_tracked):
    """Ruff configs in the repo (pinned rule set or defaults) and any ruff version it pins."""
    configs, pins = [], set()
    for rel in all_tracked:
        name = rel.rsplit("/", 1)[-1]
        path = repo / rel
        if name in ("pyproject.toml", "ruff.toml", ".ruff.toml"):
            try:
                data = tomllib.loads(path.read_text(encoding="utf-8"))
            except (OSError, tomllib.TOMLDecodeError):
                configs.append(f"{rel}: unreadable")
                continue
            sec = data.get("tool", {}).get("ruff") if name == "pyproject.toml" else data
            if sec is not None:
                lint = sec.get("lint", {}) if isinstance(sec.get("lint"), dict) else {}
                pinned = "select" in lint or "select" in sec
                configs.append(f"{rel}: {'pins select' if pinned else 'defaults'}")
        if name in ("pyproject.toml", "uv.lock", ".pre-commit-config.yaml") or name.startswith("requirements"):
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if name == "uv.lock":
                found = re.findall(r'name = "ruff"\nversion = "([^"]+)"', text)
            elif name == ".pre-commit-config.yaml":
                found = re.findall(r"ruff-pre-commit\S*\s*\n\s*rev:\s*v?([\w.]+)", text)
            else:
                found = [a + b for a, b in re.findall(r"""["']?\bruff\s*([=~<>!]=?)\s*([0-9][\w.]*)""", text)]
            pins.update(f"{v} ({rel})" for v in found)
    return configs, sorted(pins)


def suppressions(args):
    ruff = None
    if not args.no_ruff:
        ruff = ruff_cmd(args.ruff)
        if ruff is None:
            sys.exit(f"lint-review: ruff not found ({args.ruff!r}); pass --ruff CMD, or --no-ruff to skip liveness")
    version = run([*ruff, "--version"]).stdout.strip() if ruff else "not run"
    known = set()
    if ruff:
        try:
            known = {r["code"] for r in json.loads(run([*ruff, "rule", "--all", "--output-format", "json"]).stdout)}
        except (json.JSONDecodeError, KeyError, TypeError):
            sys.exit("lint-review: could not read ruff's rule list (ruff rule --all --output-format json)")
    extra = re.compile(args.exclude) if args.exclude else None
    sites, repo_rows = [], []
    for repo in discover(args.roots):
        files = tracked(repo, extra)
        repo_sites = []
        for rel in files:
            lines = read_lines(repo / rel)
            if lines is None:
                continue
            for ln, tool, rules, kind, text in find_suppressions(lines):
                for rule in rules:
                    repo_sites.append({"repo": repo.name, "file": rel, "line": ln, "tool": tool, "rule": rule,
                                       "reason": kind, "reason_text": text[:160], "state": "not-measured"})
        noqa_files = sorted({s["file"] for s in repo_sites if s["tool"] == "ruff" and s["file"].endswith(".py")})
        errors = []
        if ruff and noqa_files:
            checked, unparsed, dead, errors = ruff_states(repo, noqa_files, ruff)
            for s in repo_sites:
                if s["tool"] != "ruff" or not s["file"].endswith(".py"):
                    continue
                f = os.path.realpath(repo / s["file"])
                if s["rule"] != ALL_RULES and s["rule"] not in known:
                    s["state"] = "unknown-code"
                elif f not in checked:
                    s["state"] = "unchecked"
                elif f in unparsed:
                    s["state"] = "unparsed"
                else:
                    s["state"] = "dead" if s["rule"] in dead[f].get(s["line"], set()) else "live"
        all_tracked = [f for f in run(["git", "-C", str(repo), "ls-files", "-z"]).stdout.split("\0") if f]
        configs, pins = ruff_profile(repo, all_tracked)
        measured = [s for s in repo_sites if s["state"] in ("live", "dead")]
        repo_rows.append({"repo": repo.name, "sites": len(repo_sites), "noqa_measured": len(measured),
                          "noqa_dead": sum(s["state"] == "dead" for s in measured), "ruff_configs": configs,
                          "ruff_pins": pins, "ruff_errors": [e for e in errors if e]})
        sites.extend(repo_sites)

    texts = collections.Counter((s["tool"], s["rule"], s["reason_text"].lower()) for s in sites if s["reason_text"])
    for s in sites:
        if s["reason_text"] and texts[(s["tool"], s["rule"], s["reason_text"].lower())] >= args.stamp_min:
            s["reason"] = "stamp"

    by_rule = collections.defaultdict(list)
    for s in sites:
        by_rule[f"{s['tool']}:{s['rule']}"].append(s)
    rows = []
    for key, ss in by_rule.items():
        st = collections.Counter(s["state"] for s in ss)
        rs = collections.Counter(s["reason"] for s in ss)
        open_bare = sum(1 for s in ss if s["state"] in ("live", "not-measured") and s["reason"] == "none")
        repos = collections.Counter(s["repo"] for s in ss)
        rows.append({"rule": key, "sites": len(ss), "repos": len(repos), "states": dict(st), "reasons": dict(rs),
                     "open_reasonless": open_bare, "top_repos": repos.most_common(3)})
    rows.sort(key=lambda r: (-r["open_reasonless"], -r["sites"], r["rule"]))

    print(f"lint-review suppressions: {len(repo_rows)} repos, {len(sites)} suppressions; ruff: {version}")
    print("\n## Rules by open reasonless suppressions (live or not measured, no reason)")
    print("rule | sites | repos | open reasonless | live | dead | unchecked | unparsed | not measured | "
          "same-line | line-above | stamp | none | top repos")
    print("|".join(["---"] * 14))
    for r in rows[:args.top]:
        st, rs = r["states"], r["reasons"]
        top = ", ".join(f"{n} {c}" for n, c in r["top_repos"])
        print(f"{r['rule']} | {r['sites']} | {r['repos']} | {r['open_reasonless']} | {st.get('live', 0)} | "
              f"{st.get('dead', 0)} | {st.get('unchecked', 0)} | {st.get('unparsed', 0)} | "
              f"{st.get('not-measured', 0)} | {rs.get('same-line', 0)} | {rs.get('line-above', 0)} | "
              f"{rs.get('stamp', 0)} | {rs.get('none', 0)} | {top}")
    mostly_dead = [r for r in rows if r["states"].get("dead", 0) >= args.dead_min
                   and r["states"].get("dead", 0) * 2 >= r["states"].get("dead", 0) + r["states"].get("live", 0)]
    print(f"\n## Mostly dead: at least {args.dead_min} dead, and dead >= live (only the comments need to go)")
    for r in sorted(mostly_dead, key=lambda r: -r["states"]["dead"]):
        print(f"{r['rule']}: {r['states']['dead']} dead, {r['states'].get('live', 0)} live")
    print("\n## Repos")
    print("repo | suppressions | ruff noqa dead / measured | ruff configs | pinned ruff")
    print("|".join(["---"] * 5))
    for r in repo_rows:
        if not r["sites"] and not r["ruff_configs"]:
            continue
        cfg = "; ".join(r["ruff_configs"]) or "none (installed defaults)"
        err = f" (ruff error: {r['ruff_errors'][0]})" if r["ruff_errors"] else ""
        print(f"{r['repo']} | {r['sites']} | {r['noqa_dead']} / {r['noqa_measured']}{err} | {cfg} | "
              f"{', '.join(r['ruff_pins']) or '-'}")
    if args.json:
        Path(args.json).write_text(json.dumps({"ruff": version, "repos": repo_rows, "rules": rows, "sites": sites},
                                              indent=1))


def sample_hits(hits, per_rule, seed):
    """Up to per_rule hits per rule, round-robin across repos, deterministic for a given seed."""
    rnd = random.Random(seed)
    out = {}
    for rule in sorted(hits):
        by_repo = collections.defaultdict(list)
        for h in sorted(hits[rule], key=lambda h: (h["repo"], h["file"], h["line"])):
            by_repo[h["repo"]].append(h)
        queues = []
        for repo in sorted(by_repo):
            q = list(by_repo[repo])
            rnd.shuffle(q)
            queues.append(q)
        picked = []
        while len(picked) < per_rule and any(queues):
            for q in queues:
                if q and len(picked) < per_rule:
                    picked.append(q.pop())
        out[rule] = picked
    return out


def admit(args):
    wanted = [r.strip() for r in args.rules.split(",") if r.strip()]
    ruff_codes = [r.split(":", 1)[1] for r in wanted if r.startswith("ruff:")]
    ox_rules = [r.split(":", 1)[1] for r in wanted if r.startswith("oxlint:")]
    if len(ruff_codes) + len(ox_rules) != len(wanted):
        sys.exit("lint-review: --rules entries must start with ruff: or oxlint:")
    ruff = ruff_cmd(args.ruff) if ruff_codes else None
    oxlint = shlex.split(args.oxlint) if ox_rules else None
    if ruff_codes and ruff is None:
        sys.exit(f"lint-review: ruff not found ({args.ruff!r})")
    if ox_rules and not (oxlint and shutil.which(oxlint[0])):
        sys.exit(f"lint-review: oxlint not found ({args.oxlint!r})")
    extra = re.compile(args.exclude) if args.exclude else None
    hits = collections.defaultdict(list)
    roots = {}
    for repo in discover(args.roots):
        roots[repo.name] = repo
        files = tracked(repo, extra)
        py = [f for f in files if f.endswith(".py")]
        js = [f for f in files if JS.search(f) and not f.endswith(".d.ts")]
        for part in chunks(py) if ruff_codes else ():
            r = run([*ruff, "check", "--no-cache", "--isolated", "--select", ",".join(ruff_codes), "--exit-zero",
                     "--output-format", "json", *part], cwd=repo)
            for d in json.loads(r.stdout or "[]"):
                if d.get("code") in ruff_codes:
                    rel = os.path.relpath(os.path.join(repo, d["filename"]), repo)
                    hits[f"ruff:{d['code']}"].append({"repo": repo.name, "file": rel, "line": d["location"]["row"],
                                                      "message": d.get("message", "")})
        flags = [x for rule in ox_rules for x in ("-D", rule)]
        for part in chunks(js) if ox_rules else ():
            r = run([*oxlint, "--format", "json", "-A", "all", *flags, *part], cwd=repo)
            try:
                data = json.loads(r.stdout or "{}")
            except json.JSONDecodeError:
                continue
            for d in data.get("diagnostics", []) if isinstance(data, dict) else data:
                inner = re.sub(r"^.*\(([^)]+)\)$", r"\1", d.get("code") or "")
                rule = next((w for w in ox_rules if w.rsplit("/", 1)[-1] == inner), None)
                if rule is None:
                    continue
                labels = d.get("labels") or [{}]
                line = labels[0].get("span", {}).get("line", 0)
                hits[f"oxlint:{rule}"].append({"repo": repo.name, "file": d.get("filename", ""), "line": line,
                                               "message": d.get("message", "")})
    picked = sample_hits(hits, args.per_rule, args.seed)
    for rule, samples in picked.items():
        for h in samples:
            lines = read_lines(roots[h["repo"]] / h["file"]) or []
            lo = max(0, h["line"] - 4)
            h["snippet"] = "\n".join(f"{lo + i + 1}: {t}" for i, t in enumerate(lines[lo:h["line"] + 3]))
    out = {"seed": args.seed, "per_rule": args.per_rule, "rules": {}}
    print("rule | hits | repos | sampled")
    print("---|---|---|---")
    for rule in wanted:
        hs = hits.get(rule, [])
        repos = collections.Counter(h["repo"] for h in hs)
        out["rules"][rule] = {"hits": len(hs), "repos": dict(repos), "sample": picked.get(rule, [])}
        print(f"{rule} | {len(hs)} | {len(repos)} | {len(picked.get(rule, []))}")
    Path(args.out).write_text(json.dumps(out, indent=1))
    print(f"\nsample written to {args.out}; label each hit real_defect, latent_risk or false_positive, then run score")


def band(labels):
    n = len(labels)
    real = labels.count("real_defect")
    useful = real + labels.count("latent_risk")
    if n >= 5 and useful >= 0.8 * n and real >= 1:
        return "ADMIT"
    if n >= 5 and useful <= 0.2 * n:
        return "NOISE"
    return "UNDETERMINED"


def score(args):
    data = json.loads(Path(args.labels).read_text(encoding="utf-8"))
    allowed = {"real_defect", "latent_risk", "false_positive"}
    print("rule | n | real | latent | false | verdict")
    print("---|---|---|---|---|---")
    for rule in sorted(data):
        labels = data[rule]
        bad = set(labels) - allowed
        if bad:
            sys.exit(f"lint-review: unknown label(s) for {rule}: {sorted(bad)}")
        print(f"{rule} | {len(labels)} | {labels.count('real_defect')} | {labels.count('latent_risk')} | "
              f"{labels.count('false_positive')} | {band(labels)}")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    sub = p.add_subparsers(dest="mode", required=True)
    s = sub.add_parser("suppressions")
    s.add_argument("roots", nargs="+")
    s.add_argument("--json")
    s.add_argument("--ruff", default="ruff")
    s.add_argument("--no-ruff", action="store_true")
    s.add_argument("--stamp-min", type=int, default=10)
    s.add_argument("--dead-min", type=int, default=10)
    s.add_argument("--top", type=int, default=30)
    s.add_argument("--exclude")
    a = sub.add_parser("admit")
    a.add_argument("roots", nargs="+")
    a.add_argument("--rules", required=True)
    a.add_argument("--out", required=True)
    a.add_argument("--per-rule", type=int, default=5)
    a.add_argument("--seed", type=int, default=20261124)
    a.add_argument("--ruff", default="ruff")
    a.add_argument("--oxlint", default="oxlint")
    a.add_argument("--exclude")
    c = sub.add_parser("score")
    c.add_argument("labels")
    args = p.parse_args(argv)
    {"suppressions": suppressions, "admit": admit, "score": score}[args.mode](args)


if __name__ == "__main__":
    main()
