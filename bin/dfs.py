#!/usr/bin/env python3
"""Agent-native DataForSEO access.

WHY THIS EXISTS

The DataForSEO credentials lived in exactly one place nobody would look:
one app's `.env.local` in a private repository, siloed there. The SEO
secrets inventory flagged that and recommended promoting them; nothing did.
So when the pair stopped working, nothing noticed, and no agent could find
them to check.

Same shape as `gsc`: a CLI beats an MCP server here. It shells out from
anywhere, has no session lifecycle, works from subagents and cron, and fails
with a readable message instead of `-32000`.

Stdlib only. DataForSEO is HTTP Basic auth, so unlike `gsc` there is no SDK
and no venv to rot.

CREDENTIAL RESOLUTION, in order:

  1. DATAFORSEO_LOGIN / DATAFORSEO_PASSWORD in the environment
  2. Bitwarden Secrets Manager  <- CANONICAL, put them here
     DATAFORSEO_LOGIN and DATAFORSEO_PASSWORD in the startupbros project
  3. ~/.secrets                 (local cache, 0600)
  4. DFS_LEGACY_ENV, when set (path to a deprecated legacy dotenv file)

Each fallback is reported with `--where` so a dead credential is traceable to
the file it came from rather than guessed at.

Usage:
  dfs whoami                          account, balance, and WHICH source was used
  dfs backlinks <domain>              backlink summary
  dfs refdomains <domain>             referring domains
  dfs ranked <domain>                 keywords the domain ranks for
  dfs serp "<query>"                  live Google SERP
  dfs keywords <seed>                 keyword ideas
  dfs raw <endpoint> [--data JSON]    any v3 endpoint

  --json    machine-readable (works before or after the subcommand)
  --limit   row cap where applicable (default 20)
  --where   print which credential source resolved, then exit
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

BASE = "https://api.dataforseo.com"
SECRETS_FILE = os.path.expanduser("~/.secrets")
LEGACY_ENV = os.path.expanduser(os.environ.get("DFS_LEGACY_ENV", ""))
BWS_TOKEN = os.path.expanduser("~/.config/bws/token")
BWS_PROJECT = os.path.expanduser("~/.config/bws/sb-project-id")


# Name pairs to try, in priority order.
#
# ~/.secrets carries BOTH pairs, and only the first works. DATAFORSEO_API_USER /
# DATAFORSEO_API_PASSWORD is a stale duplicate that returns 40100. Testing that
# pair and concluding "the account is dead" cost real time on 2026-08-05, with
# the live credential four lines away under a different name. Order matters
# here; do not reorder without checking `dfs whoami`.
NAME_PAIRS = (
    ("DATAFORSEO_LOGIN", "DATAFORSEO_PASSWORD"),
    ("DATAFORSEO_API_USER", "DATAFORSEO_API_PASSWORD"),
)


def _from_env_file(path):
    """First WORKING-name pair from a dotenv-style file.

    Tolerates an `export ` prefix. A `^KEY=` anchored match silently misses
    `export KEY=`, which is the second way this file defeated a grep.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            body = handle.read()
    except OSError:
        return None

    for login_key, pw_key in NAME_PAIRS:
        login = re.search(rf"^(?:export\s+)?{login_key}=(.*)$", body, re.M)
        password = re.search(rf"^(?:export\s+)?{pw_key}=(.*)$", body, re.M)
        if login and password:
            return (
                login.group(1).strip().strip("\"'"),
                password.group(1).strip().strip("\"'"),
                f"{path} ({login_key})",
            )
    return None


def _from_bws():
    """Canonical source. Absent bws or absent secrets both fall through."""
    import subprocess

    try:
        token = open(BWS_TOKEN, encoding="utf-8").read().strip()
        project = open(BWS_PROJECT, encoding="utf-8").read().strip()
    except OSError:
        return None

    try:
        out = subprocess.run(
            ["bws", "--color", "no", "secret", "list", project],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "BWS_ACCESS_TOKEN": token},
        )
        if out.returncode != 0:
            return None
        secrets = {s.get("key"): s.get("value") for s in json.loads(out.stdout)}
    except Exception:
        return None

    for login_key, pw_key in NAME_PAIRS:
        login, password = secrets.get(login_key), secrets.get(pw_key)
        if login and password:
            return login, password, f"bws ({login_key})"
    return None


def credentials():
    """Return (login, password, source). Exits with guidance if none found."""
    for login_key, pw_key in NAME_PAIRS:
        login, password = os.environ.get(login_key), os.environ.get(pw_key)
        if login and password:
            return login, password, f"environment ({login_key})"

    got = _from_bws()
    if got:
        return got

    for path in (SECRETS_FILE, LEGACY_ENV):
        if not path:
            continue
        got = _from_env_file(path)
        if got:
            return got

    sys.exit(
        "No DataForSEO credentials found.\n"
        "  Canonical home is Bitwarden Secrets Manager: set/update\n"
        "  DATAFORSEO_LOGIN and DATAFORSEO_PASSWORD through the BWS web vault\n"
        "  or an attended operator shell, then run `dfs --where`.\n"
        "  Worktree sessions: do not inline `$(cat ...)` in command arguments;\n"
        "  put multi-step credential setup in a Write-created script.\n"
        "  Get or rotate provider credentials at https://app.dataforseo.com/api-access"
    )


def call(endpoint, payload=None):
    login, password, source = credentials()
    auth = base64.b64encode(f"{login}:{password}".encode()).decode()
    url = f"{BASE}{endpoint}"
    data = json.dumps([payload]).encode() if payload is not None else None

    request = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    request.add_header("Authorization", f"Basic {auth}")
    request.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            body = json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="ignore")[:400]
        # 40100 is DataForSEO's "not authorized". Name the source, because the
        # whole failure mode here was a dead credential nobody could locate.
        sys.exit(
            f"DataForSEO HTTP {exc.code} using credentials from: {source}\n"
            f"  {detail}\n"
            f"  If this is 40100, the pair is dead. Rotate at "
            f"https://app.dataforseo.com/api-access and update bws."
        )
    except urllib.error.URLError as exc:
        sys.exit(f"DataForSEO unreachable: {exc}")

    if body.get("status_code") != 20000:
        sys.exit(f"DataForSEO error {body.get('status_code')}: {body.get('status_message')}")
    return body


def first_result(body):
    tasks = body.get("tasks") or []
    if not tasks:
        return []
    result = tasks[0].get("result") or []
    return result


def emit(rows, as_json, columns=None):
    if as_json:
        print(json.dumps(rows, indent=2))
        return
    if not rows:
        print("(no results)")
        return
    if columns is None:
        print(json.dumps(rows, indent=2))
        return
    widths = {c: max(len(c), *(len(str(r.get(c, ""))) for r in rows)) for c in columns}
    print("  ".join(c.ljust(widths[c]) for c in columns))
    print("  ".join("-" * widths[c] for c in columns))
    for row in rows:
        print("  ".join(str(row.get(c, "")).ljust(widths[c]) for c in columns))


def main(argv=None):
    parser = argparse.ArgumentParser(description="Agent-native DataForSEO access.")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--where", action="store_true", help="report credential source and exit")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--location", default="United States")
    sub = parser.add_subparsers(dest="cmd")

    sub.add_parser("whoami")
    for name in ("backlinks", "refdomains", "ranked"):
        p = sub.add_parser(name)
        p.add_argument("target")
    p = sub.add_parser("serp"); p.add_argument("query")
    p = sub.add_parser("keywords"); p.add_argument("seed")
    p = sub.add_parser("raw"); p.add_argument("endpoint"); p.add_argument("--data", default=None)

    # --json accepted on either side, matching gsc.
    args, extra = parser.parse_known_args(argv)
    if extra:
        args = parser.parse_args([a for a in (argv or sys.argv[1:]) if a not in ("--json",)])
        args.json = True

    if args.where:
        login, _, source = credentials()
        print(f"  source: {source}\n  login : {login[:3]}…")
        return 0

    if not args.cmd:
        parser.print_help()
        return 0

    if args.cmd == "whoami":
        login, _, source = credentials()
        info = (first_result(call("/v3/appendix/user_data")) or [{}])[0]
        print(f"  source : {source}")
        print(f"  login  : {info.get('login', login)}")
        print(f"  balance: {(info.get('money') or {}).get('balance')}")
        return 0

    if args.cmd in ("backlinks", "refdomains"):
        ep = "/v3/backlinks/summary/live" if args.cmd == "backlinks" else "/v3/backlinks/referring_domains/live"
        rows = first_result(call(ep, {"target": args.target, "limit": args.limit}))
        emit(rows, args.json)
        return 0

    if args.cmd == "ranked":
        rows = first_result(call("/v3/dataforseo_labs/google/ranked_keywords/live",
                                 {"target": args.target, "location_name": args.location,
                                  "language_name": "English", "limit": args.limit}))
        emit(rows, args.json)
        return 0

    if args.cmd == "serp":
        rows = first_result(call("/v3/serp/google/organic/live/advanced",
                                 {"keyword": args.query, "location_name": args.location,
                                  "language_name": "English", "depth": args.limit}))
        emit(rows, args.json)
        return 0

    if args.cmd == "keywords":
        rows = first_result(call("/v3/dataforseo_labs/google/keyword_ideas/live",
                                 {"keywords": [args.seed], "location_name": args.location,
                                  "language_name": "English", "limit": args.limit}))
        emit(rows, args.json)
        return 0

    if args.cmd == "raw":
        payload = json.loads(args.data) if args.data else None
        print(json.dumps(call(args.endpoint, payload), indent=2))
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
