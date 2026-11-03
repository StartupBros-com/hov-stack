#!/usr/bin/env python3
"""Was a malicious package version ever in this repo, not just in today's lockfile?

A clean lockfile today says nothing about the version a laptop or CI installed last
month, which is when a worm would have taken the keys. This reads every lockfile
version git holds (all branches, within --since, plus the version each in-window
change replaced and the version at every branch tip), every uncommitted lockfile,
and what is installed in node_modules and virtualenvs. It then asks OSV which of
those package versions carry advisories. By default it reports malicious-package
advisories (MAL- ids) only; --all-vulns reports every advisory.

Run it with python3 -I. Lockfiles are read as data and never executed. The OSV
query sends package names and versions, nothing else, to api.osv.dev.

Usage:
  lockfile-history.py [--repo DIR] [--since 180.days|all] [--all-vulns]
                      [--list-packages] [--extract DIR] [--json FILE]

  --list-packages  print every name@version found and where, with no network call
  --extract DIR    write each lockfile version found to DIR/<blob>/<path>, with no
                   network call, so `osv-scanner scan source -r DIR` can cover the
                   formats this script does not parse (Cargo, Go, Ruby, PHP, ...)

Exit status: 0 nothing found, 2 findings, 1 error. An error never reads as clean.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

OSV_BATCH = "https://api.osv.dev/v1/querybatch"
OSV_VULN = "https://api.osv.dev/v1/vulns/"
UA = "lockfile-history/1 (security-audit-for-saas)"
MAX_BLOB = 64 * 1024 * 1024

SEMVER = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$")
NPM_NAME = re.compile(r"^(?:@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+$")
PEP440 = re.compile(r"^[0-9][0-9A-Za-z.!+-]*$")

# Lockfile names whose format git history may hold but this script does not parse.
UNPARSED = {"Cargo.lock", "Gemfile.lock", "composer.lock", "go.mod", "go.sum", "packages.lock.json",
            "gradle.lockfile", "pubspec.lock", "mix.lock", "Podfile.lock", "bun.lockb"}


def add_npm(out, name, version):
    if not isinstance(name, str) or not isinstance(version, str):
        return
    if version.startswith("npm:"):  # alias: "npm:real-name@1.2.3"
        real, _, version = version[4:].rpartition("@")
        name = real or name
    if NPM_NAME.match(name) and SEMVER.match(version):
        out.add(("npm", name, version))


def pypi_name(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def add_pypi(out, name, version):
    if isinstance(name, str) and isinstance(version, str) and name and PEP440.match(version):
        out.add(("PyPI", pypi_name(name), version))


def parse_npm_json(data):
    """package-lock.json / npm-shrinkwrap.json / node_modules/.package-lock.json, v1-v3."""
    try:
        doc = json.loads(data)
    except ValueError:
        return set(), "not valid JSON"
    out = set()
    packages = doc.get("packages") if isinstance(doc, dict) else None
    if isinstance(packages, dict):
        for key, ent in packages.items():
            if "node_modules/" not in key or not isinstance(ent, dict) or ent.get("link"):
                continue
            add_npm(out, ent.get("name") or key.rsplit("node_modules/", 1)[1], ent.get("version"))

    def walk(deps):
        for name, ent in deps.items():
            if isinstance(ent, dict):
                add_npm(out, name, ent.get("version"))
                if isinstance(ent.get("dependencies"), dict):
                    walk(ent["dependencies"])

    if isinstance(doc, dict) and isinstance(doc.get("dependencies"), dict):
        walk(doc["dependencies"])
    return out, None


PNPM_ENTRY = re.compile(r"""^  (['"]?)(\S.*?)\1:\s*$""")


def parse_pnpm(data):
    """pnpm-lock.yaml and node_modules/.pnpm/lock.yaml, lockfile v5 to v9."""
    text = data.decode("utf-8", "replace")
    m = re.search(r"""^lockfileVersion:\s*['"]?(\d+)""", text, re.M)
    major = int(m.group(1)) if m else 9
    out, section = set(), False
    for line in text.splitlines():
        if line and not line[0].isspace():
            section = line.rstrip() in ("packages:", "snapshots:")
            continue
        if not section:
            continue
        m = PNPM_ENTRY.match(line)
        if not m:
            continue
        key = m.group(2).lstrip("/")
        if major < 6:  # /name/1.0.0_peer@x or /@scope/name/1.0.0
            parts = key.split("/")
            if key.startswith("@") and len(parts) >= 3:
                name, ver = parts[0] + "/" + parts[1], parts[2]
            elif len(parts) >= 2:
                name, ver = parts[0], parts[1]
            else:
                continue
            add_npm(out, name, ver.split("_", 1)[0])
        else:  # name@1.0.0(peer@x)
            key = key.split("(", 1)[0]
            i = key.rfind("@")
            if i > 0:
                add_npm(out, key[:i], key[i + 1:])
    return out, None


def parse_yarn(data):
    """yarn.lock, classic (v1) and berry."""
    out = set()
    block = {}

    def flush():
        name = block.get("res_name") or block.get("url_name") or block.get("header_name")
        ver = block.get("res_ver") or block.get("version")
        if name and ver and ver != "0.0.0-use.local":
            add_npm(out, name, ver)
        block.clear()

    for line in data.decode("utf-8", "replace").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            flush()
            header = line.rstrip()
            if header.endswith(":"):
                first = header[:-1].split(",")[0].strip().strip('"')
                i = first.find("@", 1)
                if first != "__metadata" and i > 0:
                    block["header_name"] = first[:i]
            continue
        if not line.startswith("  ") or line.startswith("   "):
            continue
        m = re.match(r'^  version:?\s+"?([^"\s]+)"?\s*$', line)
        if m:
            block["version"] = m.group(1)
            continue
        m = re.match(r'^  resolution:\s+"?(.+?)@npm:([^"\s]+)"?\s*$', line)
        if m:
            block["res_name"], block["res_ver"] = m.group(1), m.group(2)
            continue
        m = re.match(r'^  resolved\s+"?[^"\s]*?/((?:@[^/"]+/)?[^/"]+)/-/', line)
        if m:
            block["url_name"] = m.group(1).replace("%2f", "/").replace("%2F", "/")
    flush()
    return out, None


BUN_ENTRY = re.compile(r'^\s*"[^"]+":\s*\[\s*"((?:@[^"/@]+/)?[^"/@]+)@([^"]+)"')


def parse_bun(data):
    """bun.lock (the text format, bun 1.2+)."""
    out = set()
    for line in data.decode("utf-8", "replace").splitlines():
        m = BUN_ENTRY.match(line)
        if m:
            add_npm(out, m.group(1), m.group(2))
    return out, None


def parse_toml_packages(data):
    """uv.lock and poetry.lock: [[package]] name/version, registry packages only."""
    try:
        doc = tomllib.loads(data.decode("utf-8", "replace"))
    except tomllib.TOMLDecodeError:
        return set(), "not valid TOML"
    out = set()
    for p in doc.get("package") or []:
        if not isinstance(p, dict):
            continue
        src = p.get("source")
        if isinstance(src, dict):
            if "registry" not in src and any(k in src for k in ("editable", "virtual", "directory", "path", "git", "url")):
                continue
            if src.get("type") in ("directory", "file", "git", "url"):
                continue
        add_pypi(out, p.get("name"), p.get("version"))
    return out, None


def parse_pipfile(data):
    try:
        doc = json.loads(data)
    except ValueError:
        return set(), "not valid JSON"
    out = set()
    for group in ("default", "develop"):
        for name, ent in (doc.get(group) or {}).items():
            if isinstance(ent, dict) and isinstance(ent.get("version"), str):
                add_pypi(out, name, ent["version"].lstrip("="))
    return out, None


REQ_PIN = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^\]]*\])?\s*===?\s*([0-9][^\s;\\#,]*)")


def parse_requirements(data):
    out = set()
    for line in data.decode("utf-8", "replace").splitlines():
        m = REQ_PIN.match(line.strip())
        if m:
            add_pypi(out, m.group(1), m.group(2))
    return out, None


PARSERS = {
    "package-lock.json": parse_npm_json, "npm-shrinkwrap.json": parse_npm_json,
    "pnpm-lock.yaml": parse_pnpm, "yarn.lock": parse_yarn, "bun.lock": parse_bun,
    "uv.lock": parse_toml_packages, "poetry.lock": parse_toml_packages, "Pipfile.lock": parse_pipfile,
}


def parser_for(path):
    base = os.path.basename(path)
    if base in PARSERS:
        return PARSERS[base]
    if re.fullmatch(r"requirements[\w.-]*\.txt", base):
        return parse_requirements
    return None


def is_lockfile(path):
    return parser_for(path) is not None or os.path.basename(path) in UNPARSED


class GitError(Exception):
    pass


def git(repo, *args, stdin=None):
    r = subprocess.run(["git", "-C", repo, "-c", "core.quotePath=false", *args],
                       input=stdin, capture_output=True)
    if r.returncode != 0:
        raise GitError(f"git {' '.join(args[:2])}: {r.stderr.decode('utf-8', 'replace').strip()[:300]}")
    return r.stdout


def history(repo, since):
    """blob id -> {"paths": set, "commits": [(unix time, sha)], "tip": bool}."""
    blobs = {}

    def note(blob, path, commit=None, tip=False):
        if set(blob) == {"0"}:
            return
        b = blobs.setdefault(blob, {"paths": set(), "commits": [], "tip": False})
        b["paths"].add(path)
        if commit:
            b["commits"].append(commit)
        b["tip"] = b["tip"] or tip

    specs = [f":(glob)**/{n}" for n in list(PARSERS) + sorted(UNPARSED)] + [":(glob)**/requirements*.txt"]
    args = ["log", "--all", "-m", "--raw", "--no-abbrev", "--no-renames", "--format=@%H %ct"]
    if since != "all":
        args.append(f"--since={since}")
    commit = None
    for raw in git(repo, *args, "--", *specs).decode("utf-8", "replace").splitlines():
        if raw.startswith("@"):
            sha, ct = raw[1:].split()
            commit = (int(ct), sha)
        elif raw.startswith(":") and "\t" in raw:
            meta, path = raw.split("\t", 1)
            fields = meta.split()
            if len(fields) >= 4 and is_lockfile(path):
                note(fields[2], path, commit)  # the version this change replaced
                note(fields[3], path, commit)  # the version it wrote
    tips = set(git(repo, "for-each-ref", "--format=%(objectname)", "refs/heads", "refs/remotes").decode().split())
    for tip in tips:
        for line in git(repo, "ls-tree", "-r", "--full-tree", tip).decode("utf-8", "replace").splitlines():
            meta, _, path = line.partition("\t")
            fields = meta.split()
            if len(fields) == 3 and fields[1] == "blob" and is_lockfile(path):
                note(fields[2], path, tip=True)
    return blobs, len(tips)


def read_blobs(repo, ids):
    """Yield (blob id, bytes or None) one at a time from a single git cat-file --batch,
    so only one lockfile version is held in memory at once."""
    if not ids:
        return
    proc = subprocess.Popen(["git", "-C", repo, "cat-file", "--batch"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        for bid in ids:
            proc.stdin.write(bid.encode() + b"\n")
            proc.stdin.flush()
            header = proc.stdout.readline().decode().split()
            if len(header) < 3 or header[1] != "blob":
                yield bid, None
                continue
            size = int(header[2])
            data = proc.stdout.read(size)
            proc.stdout.read(1)
            yield bid, data if size <= MAX_BLOB else None
    finally:
        proc.stdin.close()
        proc.wait()


def prune_nested(root, dirs, include_nested):
    """Drop subdirectories that are their own git checkout (worktrees, submodules, vendored
    repos) unless asked; return how many were dropped."""
    if ".git" in dirs:
        dirs.remove(".git")
    if include_nested:
        return 0
    nested = [d for d in dirs if os.path.lexists(os.path.join(root, d, ".git"))]
    for d in nested:
        dirs.remove(d)
    return len(nested)


def on_disk(repo, include_nested=False):
    """Uncommitted lockfiles and installed manifests: (list of (path, kind), nested skipped)."""
    found, skipped = [], 0
    for root, dirs, files in os.walk(repo):
        skipped += prune_nested(root, dirs, include_nested)
        if "node_modules" in dirs:
            nm = Path(root, "node_modules")
            for f in (nm / ".package-lock.json", nm / ".pnpm" / "lock.yaml"):
                if f.is_file():
                    found.append((str(f), "installed"))
            dirs.remove("node_modules")
        if "pyvenv.cfg" in files:
            for sp in list(Path(root).glob("lib/python*/site-packages")) + list(Path(root).glob("Lib/site-packages")):
                found.append((str(sp), "installed-venv"))
            dirs[:] = []
            continue
        for f in files:
            if is_lockfile(f):
                found.append((str(Path(root, f)), "worktree"))
    return found, skipped


def dist_info(site_packages):
    out = set()
    for d in Path(site_packages).glob("*.dist-info"):
        m = re.match(r"^(.+?)-(\d[^-]*)\.dist-info$", d.name)
        if m:
            add_pypi(out, m.group(1), m.group(2))
    return out


def post(url, payload, timeout=60):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def osv_ids(pkgs):
    """(eco, name, ver) -> [vuln ids]; raises on any network or API failure."""
    pkgs = sorted(pkgs)
    hits = {}
    for i in range(0, len(pkgs), 1000):
        chunk = pkgs[i:i + 1000]
        queries = [{"package": {"name": n, "ecosystem": e}, "version": v} for e, n, v in chunk]
        results = post(OSV_BATCH, {"queries": queries})["results"]
        if len(results) != len(chunk):
            raise ValueError("OSV returned a different number of results than queries")
        for pkg, q, res in zip(chunk, queries, results):
            ids = [v["id"] for v in res.get("vulns") or []]
            token = res.get("next_page_token")
            while token:
                more = post(OSV_BATCH, {"queries": [dict(q, page_token=token)]})["results"][0]
                ids += [v["id"] for v in more.get("vulns") or []]
                token = more.get("next_page_token")
            if ids:
                hits[pkg] = ids
    return hits


def osv_detail(vid):
    req = urllib.request.Request(OSV_VULN + vid, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.load(r)
        return d.get("summary") or "", d.get("aliases") or []
    except (OSError, ValueError):
        return "", []


def when(ts):
    import datetime
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--repo", default=".")
    ap.add_argument("--since", default="180.days", help="git --since value, or 'all' (default 180.days)")
    ap.add_argument("--all-vulns", action="store_true", help="report every advisory, not only MAL- ids")
    ap.add_argument("--list-packages", action="store_true", help="print what was found; no network call")
    ap.add_argument("--extract", metavar="DIR", help="write every lockfile version found to DIR; no network call")
    ap.add_argument("--json", metavar="FILE", help="write findings as JSON")
    ap.add_argument("--include-nested", action="store_true",
                    help="also read files in nested checkouts (worktrees, submodules) on disk")
    a = ap.parse_args()
    repo = str(Path(a.repo).resolve())

    try:
        git(repo, "rev-parse", "--git-dir")
        blobs, nrefs = history(repo, a.since)
    except (GitError, OSError) as e:
        print(f"lockfile-history: cannot read git history of {repo}: {e}", file=sys.stderr)
        return 1

    # pkg -> {"first": (ts, sha), "last": (ts, sha), "paths": set, "tip": bool, "local": set}
    seen = {}
    unparsed, problems = {}, []

    def record(pkgs, path, commits=(), tip=False, local=None):
        for p in pkgs:
            s = seen.setdefault(p, {"first": None, "last": None, "paths": set(), "tip": False, "local": set()})
            s["paths"].add(path)
            for c in commits:
                s["first"] = c if s["first"] is None or c < s["first"] else s["first"]
                s["last"] = c if s["last"] is None or c > s["last"] else s["last"]
            s["tip"] = s["tip"] or tip
            if local:
                s["local"].add(local)

    for bid, data in read_blobs(repo, sorted(blobs)):
        info = blobs[bid]
        path = sorted(info["paths"])[0]
        if data is None:
            problems.append(f"{path}@{bid[:10]}: unreadable or over {MAX_BLOB // 2**20} MiB")
            continue
        if a.extract:
            dest = Path(a.extract, bid[:12], path)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
        parse = parser_for(path)
        if parse is None:
            unparsed[os.path.basename(path)] = unparsed.get(os.path.basename(path), 0) + 1
            continue
        pkgs, err = parse(data)
        if err:
            problems.append(f"{path}@{bid[:10]}: {err}")
        record(pkgs, path, info["commits"], info["tip"])

    local, nested = on_disk(repo, a.include_nested)
    for f, kind in local:
        rel = os.path.relpath(f, repo)
        if kind == "installed-venv":
            record(dist_info(f), rel, local="installed")
            continue
        try:
            data = Path(f).read_bytes()
        except OSError as e:
            problems.append(f"{rel}: {e}")
            continue
        if a.extract:
            dest = Path(a.extract, kind, rel)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
        if kind == "installed":
            parse = parse_npm_json if f.endswith(".package-lock.json") else parse_pnpm
        else:
            parse = parser_for(f)
        if parse is None:
            unparsed[os.path.basename(f)] = unparsed.get(os.path.basename(f), 0) + 1
            continue
        pkgs, err = parse(data)
        if err:
            problems.append(f"{rel}: {err}")
        record(pkgs, rel, local=kind)

    eco = {}
    for e, _, _ in seen:
        eco[e] = eco.get(e, 0) + 1
    window = "all history" if a.since == "all" else f"since {a.since}"
    print(f"lockfile-history: {repo}")
    print(f"  read {len(blobs)} lockfile versions from git ({window}, {nrefs} branch tips) "
          f"and {len(local)} files on disk")
    print("  package versions: " + (", ".join(f"{k} {v}" for k, v in sorted(eco.items())) or "none"))
    if nested:
        print(f"  skipped {nested} nested checkouts (worktrees, submodules) on disk; their committed "
              f"lockfiles are still in the git history above; --include-nested reads their files too")
    for name, n in sorted(unparsed.items()):
        print(f"  not parsed: {name} ({n} version{'s' if n > 1 else ''}); rerun with --extract DIR, "
              f"then osv-scanner scan source -r DIR")
    for p in problems:
        print(f"  problem: {p}")

    if a.list_packages:
        for (e, n, v), s in sorted(seen.items()):
            where = []
            if s["first"]:
                where.append(f"git {when(s['first'][0])}..{when(s['last'][0])}")
            if s["tip"]:
                where.append("branch tip")
            where += sorted(s["local"])
            print(f"{e}\t{n}\t{v}\t{', '.join(where)}\t{', '.join(sorted(s['paths']))}")
        return 0
    if a.extract:
        print(f"  extracted to {a.extract}")
        return 0
    if not seen:
        print("result: no package versions found to check")
        return 0

    try:
        hits = osv_ids(seen.keys())
    except (OSError, ValueError, KeyError, urllib.error.URLError) as e:
        print(f"lockfile-history: OSV query failed, nothing was checked: {e}", file=sys.stderr)
        return 1
    print(f"  asked OSV about {len(seen)} package versions")

    findings = []
    details = {}
    for pkg, ids in sorted(hits.items()):
        keep = ids if a.all_vulns else [i for i in ids if i.startswith("MAL-")]
        if not keep:
            continue
        s = seen[pkg]
        for vid in keep:
            if vid not in details and len(details) < 200:
                details[vid] = osv_detail(vid)
        findings.append({
            "ecosystem": pkg[0], "name": pkg[1], "version": pkg[2], "ids": keep,
            "malicious": any(i.startswith("MAL-") for i in keep),
            "summary": "; ".join(details.get(i, ("", []))[0] for i in keep if details.get(i, ("", []))[0]),
            "first_seen": {"date": when(s["first"][0]), "commit": s["first"][1]} if s["first"] else None,
            "last_seen": {"date": when(s["last"][0]), "commit": s["last"][1]} if s["last"] else None,
            "on_branch_tip": s["tip"], "on_disk": sorted(s["local"]), "paths": sorted(s["paths"]),
        })
    for f in findings:
        tag = "MALICIOUS" if f["malicious"] else "ADVISORY"
        print(f"{tag}  {f['ecosystem']} {f['name']}@{f['version']}  {', '.join(f['ids'])}  {f['summary'][:120]}")
        seen_in = []
        if f["first_seen"]:
            seen_in.append(f"git {f['first_seen']['date']} ({f['first_seen']['commit'][:10]}) .. "
                           f"{f['last_seen']['date']} ({f['last_seen']['commit'][:10]})")
        print(f"    in {', '.join(f['paths'])}; {'; '.join(seen_in) or 'not in git history'}; "
              f"on a branch tip now: {'yes' if f['on_branch_tip'] else 'no'}; "
              f"on disk now: {', '.join(f['on_disk']) or 'no'}")
    if a.json:
        Path(a.json).write_text(json.dumps(findings, indent=1) + "\n")
    kind = "advisories" if a.all_vulns else "malicious package versions"
    print(f"result: {len(findings)} {kind} found" + (" (see problems above)" if problems else ""))
    return 2 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
