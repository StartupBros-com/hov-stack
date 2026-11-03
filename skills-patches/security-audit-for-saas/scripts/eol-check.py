#!/usr/bin/env python3
"""Which runtimes, databases and frameworks this repo pins are past or near end of life?

An end-of-life runtime gets no security fixes, so every CVE published after that
date stays open. This reads the version pins a repo already declares and checks
each against endoflife.date:

  .nvmrc .node-version .python-version .tool-versions mise.toml .mise.toml
  package.json (engines.node floor, next) pyproject.toml (requires-python floor)
  go.mod  supabase/config.toml ([db] major_version)  runtime.txt
  Dockerfile* and compose files (FROM / image: node, python, postgres, redis, golang,
  ruby, mysql, alpine, debian, ubuntu)  .github/workflows (node-version, python-version)

Only product names and nothing about the repo are sent (one GET per product to
endoflife.date). --list prints the pins without any network call; --data DIR reads
<product>.json files from DIR instead of the network.

Usage: eol-check.py [--repo DIR] [--warn-days 90] [--list] [--data DIR] [--today YYYY-MM-DD]
                    [--json FILE]
Exit status: 2 a pin is past end of life or inside the warning window, 1 a lookup
failed, 0 otherwise.
"""
import argparse
import datetime
import json
import os
import re
import sys
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

API = "https://endoflife.date/api/{}.json"
UA = "eol-check/1 (security-audit-for-saas)"
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "vendor", "dist", "build", ".next", ".turbo",
             "target", "__pycache__", ".cache"}
IMAGES = {"node": "nodejs", "python": "python", "postgres": "postgresql", "redis": "redis",
          "golang": "go", "ruby": "ruby", "mysql": "mysql", "alpine": "alpine", "debian": "debian",
          "ubuntu": "ubuntu"}
TOOLS = {"node": "nodejs", "nodejs": "nodejs", "python": "python", "golang": "go", "go": "go",
         "ruby": "ruby", "postgres": "postgresql", "postgresql": "postgresql"}
DEBIAN_NAMES = {"bookworm": "12", "bullseye": "11", "buster": "10", "trixie": "13"}
VER = re.compile(r"(\d+(?:\.\d+){0,2})")
NAMES = {".nvmrc", ".node-version", ".python-version", ".tool-versions", "mise.toml", ".mise.toml",
         "package.json", "pyproject.toml", "go.mod", "runtime.txt", "config.toml"}
COMPOSE = re.compile(r"(docker-)?compose[\w.-]*\.ya?ml")
WORKFLOWS = os.path.join(".github", "workflows")


def wanted(dirpath, f):
    """Only files that can hold a version pin are opened; nothing else (.env included) is read."""
    return (f in NAMES or f.startswith("Dockerfile") or f.endswith(".Dockerfile") or COMPOSE.fullmatch(f)
            or (f.endswith((".yml", ".yaml")) and dirpath.endswith(WORKFLOWS)))


def pins(repo, include_nested=False, skipped=None):
    """Yield (product, version, kind, file) where kind is 'pin', 'floor' or 'range'.
    Nested checkouts (worktrees, submodules) are skipped and listed in `skipped` unless asked."""
    for dirpath, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        if not include_nested:
            nested = [d for d in dirs if os.path.lexists(os.path.join(dirpath, d, ".git"))]
            dirs[:] = [d for d in dirs if d not in nested]
            if skipped is not None:
                skipped.extend(os.path.join(dirpath, d) for d in nested)
        rel = os.path.relpath(dirpath, repo)
        for f in files:
            if not wanted(dirpath, f):
                continue
            p = Path(dirpath, f)
            relf = os.path.normpath(os.path.join(rel, f))
            try:
                text = p.read_text(errors="replace") if p.stat().st_size < 2_000_000 else ""
            except OSError:
                continue
            if f in (".nvmrc", ".node-version"):
                m = VER.search(text.strip().lstrip("v"))
                if m and not text.strip().startswith("lts"):
                    yield "nodejs", m.group(1), "pin", relf
            elif f == ".python-version":
                for line in text.split():
                    m = re.match(r"^(?:cpython-|pypy)?(\d+\.\d+(?:\.\d+)?)", line)
                    if m:
                        yield "python", m.group(1), "pin", relf
            elif f == ".tool-versions":
                for line in text.splitlines():
                    parts = line.split()
                    if len(parts) >= 2 and parts[0] in TOOLS and VER.match(parts[1]):
                        yield TOOLS[parts[0]], VER.match(parts[1]).group(1), "pin", relf
            elif f in ("mise.toml", ".mise.toml") or relf.endswith(os.path.join(".config", "mise.toml")):
                try:
                    tools = tomllib.loads(text).get("tools") or {}
                except tomllib.TOMLDecodeError:
                    continue
                for name, val in tools.items():
                    val = val[0] if isinstance(val, list) and val else val
                    val = val.get("version") if isinstance(val, dict) else val
                    if name in TOOLS and isinstance(val, str) and VER.match(val):
                        yield TOOLS[name], VER.match(val).group(1), "pin", relf
            elif f == "package.json":
                try:
                    doc = json.loads(text)
                except ValueError:
                    continue
                node = (doc.get("engines") or {}).get("node") if isinstance(doc, dict) else None
                if isinstance(node, str) and VER.search(node):
                    yield "nodejs", VER.search(node).group(1), "floor", relf
                deps = {**(doc.get("devDependencies") or {}), **(doc.get("dependencies") or {})}
                nxt = deps.get("next")
                if isinstance(nxt, str) and VER.search(nxt):
                    yield "nextjs", VER.search(nxt).group(1), "range", relf
            elif f == "pyproject.toml":
                try:
                    rp = (tomllib.loads(text).get("project") or {}).get("requires-python")
                except tomllib.TOMLDecodeError:
                    continue
                m = re.search(r">=?\s*(\d+\.\d+)", rp or "")
                if m:
                    yield "python", m.group(1), "floor", relf
            elif f == "go.mod":
                m = re.search(r"^go\s+(\d+\.\d+(?:\.\d+)?)", text, re.M)
                if m:
                    yield "go", m.group(1), "pin", relf
            elif f == "runtime.txt":
                m = re.search(r"python-(\d+\.\d+(?:\.\d+)?)", text)
                if m:
                    yield "python", m.group(1), "pin", relf
            elif f == "config.toml" and os.path.basename(dirpath) == "supabase":
                try:
                    mv = (tomllib.loads(text).get("db") or {}).get("major_version")
                except tomllib.TOMLDecodeError:
                    continue
                if isinstance(mv, int):
                    yield "postgresql", str(mv), "pin", relf
            if f.startswith("Dockerfile") or f.endswith(".Dockerfile") or COMPOSE.fullmatch(f):
                for m in re.finditer(r"^\s*(?:FROM(?:\s+--platform=\S+)?|image:)\s+['\"]?"
                                     r"(?:docker\.io/)?(?:library/)?([a-z0-9._-]+):([A-Za-z0-9._-]+)",
                                     text, re.M | re.I):
                    image, tag = m.group(1), m.group(2)
                    if image not in IMAGES:
                        continue
                    tag = DEBIAN_NAMES.get(tag.split("-")[0], tag)
                    v = VER.match(tag)
                    if v:
                        yield IMAGES[image], v.group(1), "pin", relf
            if f.endswith((".yml", ".yaml")) and dirpath.endswith(WORKFLOWS):
                for m in re.finditer(r"\b(node|python)-version:\s*\[?\s*['\"]?(\d+(?:\.\d+)*)", text):
                    yield ("nodejs" if m.group(1) == "node" else "python"), m.group(2), "ci", relf


def fetch(product, data_dir, cache):
    if product in cache:
        return cache[product]
    if data_dir:
        cache[product] = json.loads(Path(data_dir, f"{product}.json").read_text())
    else:
        req = urllib.request.Request(API.format(product), headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=30) as r:
            cache[product] = json.load(r)
    return cache[product]


def comps(v):
    return [int(x) for x in v.split(".") if x.isdigit()]


def find_cycle(cycles, version):
    """The longest cycle whose numeric components are a prefix of the version's."""
    vc = comps(version)
    best = None
    for c in cycles:
        cc = comps(str(c.get("cycle", "")))
        if cc and vc[:len(cc)] == cc and (best is None or len(cc) > len(comps(str(best["cycle"])))):
            best = c
    return best


def as_date(v):
    if isinstance(v, str):
        try:
            return datetime.date.fromisoformat(v)
        except ValueError:
            return None
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--repo", default=".")
    ap.add_argument("--warn-days", type=int, default=90)
    ap.add_argument("--list", action="store_true", help="print the pins found; no network call")
    ap.add_argument("--data", metavar="DIR", help="read <product>.json from DIR instead of endoflife.date")
    ap.add_argument("--today", help="YYYY-MM-DD, for reproducible runs (default: today)")
    ap.add_argument("--json", metavar="FILE")
    ap.add_argument("--include-nested", action="store_true",
                    help="also read nested checkouts (worktrees, submodules)")
    a = ap.parse_args()
    repo = str(Path(a.repo).resolve())
    today = datetime.date.fromisoformat(a.today) if a.today else datetime.date.today()

    skipped = []
    found = sorted(set(pins(repo, a.include_nested, skipped)))
    if skipped:
        print(f"skipped {len(skipped)} nested checkouts (worktrees, submodules); --include-nested reads them")
    if a.list:
        for product, version, kind, f in found:
            print(f"{product}\t{version}\t{kind}\t{f}")
        print(f"result: {len(found)} version pins found")
        return 0

    cache, rows, errors = {}, [], []
    for product, version, kind, f in found:
        try:
            cycles = fetch(product, a.data, cache)
        except (OSError, ValueError, urllib.error.URLError) as e:
            errors.append(f"{product}: {e}")
            continue
        c = find_cycle(cycles, version)
        row = {"product": product, "version": version, "kind": kind, "file": f, "status": "ok", "detail": ""}
        if c is None:
            row.update(status="unknown", detail="no matching release cycle on endoflife.date "
                       "(too vague, or not a release)")
        else:
            eol = c.get("eol")
            eol_date = as_date(eol)
            latest = str(c.get("latest") or "")
            if eol is True or (eol_date and eol_date <= today):
                row.update(status="eol", detail=f"cycle {c['cycle']} reached end of life"
                           + (f" on {eol_date}" if eol_date else ""))
            elif eol_date and (eol_date - today).days <= a.warn_days:
                row.update(status="eol-soon", detail=f"cycle {c['cycle']} reaches end of life on {eol_date} "
                           f"({(eol_date - today).days} days)")
            elif kind == "pin" and latest and len(comps(version)) == len(comps(latest)) and version != latest:
                row.update(status="behind", detail=f"latest {c['cycle']} release is {latest}")
            elif eol_date:
                row["detail"] = f"supported until {eol_date}"
            if kind == "floor" and row["status"] in ("eol", "eol-soon"):
                row["detail"] += " (this is the lowest version the file allows)"
        rows.append(row)

    label = {"eol": "EOL", "eol-soon": "EOL-SOON", "behind": "BEHIND", "unknown": "UNKNOWN", "ok": "ok"}
    order = {"eol": 0, "eol-soon": 1, "behind": 2, "unknown": 3, "ok": 4}
    for r in sorted(rows, key=lambda r: (order[r["status"]], r["product"], r["file"])):
        print(f"{label[r['status']]:9} {r['product']} {r['version']} ({r['kind']})  {r['file']}  {r['detail']}")
    for e in errors:
        print(f"ERROR     lookup failed: {e}")
    if a.json:
        Path(a.json).write_text(json.dumps({"rows": rows, "errors": errors}, indent=1) + "\n")
    bad = sum(r["status"] in ("eol", "eol-soon") for r in rows)
    print(f"result: {bad} of {len(rows)} pins past or within {a.warn_days} days of end of life"
          + (f"; {len(errors)} lookups failed" if errors else ""))
    return 2 if bad else (1 if errors else 0)


if __name__ == "__main__":
    sys.exit(main())
