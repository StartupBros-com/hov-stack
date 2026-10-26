#!/usr/bin/env python3
"""Read-only Slack workspace audit.

Reads SLACK_XOXP_TOKEN from the environment and makes ONLY read calls
(auth.test, team.info, conversations.list, conversations.history[limit=1],
users.list, files.list). It performs NO archives, deletes, kicks, or writes.

Usage:
    source ~/.config/slack-admin.env
    python3 slack_audit.py                # human-readable report to stdout
    python3 slack_audit.py --json out.json  # also dump raw inventory for cleanup planning

The token is used in the Authorization header only and is never printed.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TOKEN = os.environ.get("SLACK_XOXP_TOKEN")
if not TOKEN:
    sys.exit("SLACK_XOXP_TOKEN not set. Run: source ~/.config/slack-admin.env")

API = "https://slack.com/api/"
DAY = 86400
NOW = time.time()


def call(method, **params):
    """POST to a Web API method, retrying on rate limits. Returns parsed JSON."""
    url = API + method
    body = urllib.parse.urlencode(params).encode()
    for _ in range(8):
        req = urllib.request.Request(
            url, data=body, headers={"Authorization": f"Bearer {TOKEN}"}
        )
        try:
            with urllib.request.urlopen(req) as resp:
                parsed = json.load(resp)
        except urllib.error.HTTPError as exc:
            if exc.code == 429:
                time.sleep(int(exc.headers.get("Retry-After", "3")) + 1)
                continue
            raise
        if not parsed.get("ok") and parsed.get("error") == "ratelimited":
            time.sleep(3)
            continue
        return parsed
    return {"ok": False, "error": "retries_exhausted"}


def paginate(method, key, **params):
    items, cursor = [], None
    while True:
        if cursor:
            params["cursor"] = cursor
        page = call(method, limit=200, **params)
        if not page.get("ok"):
            print(f"  ! {method}: {page.get('error')}", file=sys.stderr)
            break
        items.extend(page.get(key, []))
        cursor = page.get("response_metadata", {}).get("next_cursor")
        if not cursor:
            break
    return items


def days_ago(ts):
    return None if not ts else int((NOW - float(ts)) / DAY)


def human_size(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.0f}{unit}"
        n /= 1024
    return f"{n:.1f}TB"


def main():
    who = call("auth.test")
    if not who.get("ok"):
        sys.exit(f"auth.test failed: {who.get('error')} (is the token valid / installed?)")
    print(f"# Slack audit for {who.get('team')}  ({who.get('url')})")
    print(f"  acting as: {who.get('user')}  team_id={who.get('team_id')}\n")

    team = call("team.info").get("team", {})
    if team:
        print(f"  domain: {team.get('domain')}  plan-detect: see member/guest section\n")

    print("## Channels")
    chans = paginate(
        "conversations.list",
        "channels",
        types="public_channel,private_channel",
        exclude_archived="false",
    )
    # NOTE: per-channel last-activity (conversations.history) is intentionally
    # omitted. Slack rate-limits history to ~1 req/min for non-Marketplace apps,
    # which would stall the audit. Staleness is judged by member count + age here;
    # true idle detection is a manual eyeball on the inventory.
    rows = []
    for c in chans:
        rows.append(
            {
                "name": c.get("name"),
                "id": c["id"],
                "archived": c.get("is_archived", False),
                "private": c.get("is_private", False),
                "members": c.get("num_members", 0),
                "created_days": days_ago(c.get("created")),
            }
        )
    rows.sort(key=lambda r: (r["archived"], r["members"], -(r["created_days"] or 0)))
    print(f"  total={len(rows)}  archived={sum(r['archived'] for r in rows)}")
    print(f"  {'name':30} {'priv':4} {'arch':4} {'mem':>4} {'age_d':>7}")
    for r in rows:
        age = "-" if r["created_days"] is None else r["created_days"]
        print(
            f"  {(r['name'] or '')[:30]:30} {'y' if r['private'] else '':4} "
            f"{'y' if r['archived'] else '':4} {r['members']:>4} {str(age):>7}"
        )

    # Cleanup candidates (proposals only, nothing executed)
    empty = [r for r in rows if not r["archived"] and r["members"] <= 1]
    print(f"\n  ARCHIVE CANDIDATES (low-signal): {len(empty)} with <=1 member")

    print("\n## Members and guests")
    users = paginate("users.list", "members")
    active = [u for u in users if not u.get("deleted")]
    bots = [u for u in active if u.get("is_bot")]
    humans = [u for u in active if not u.get("is_bot")]
    multi_guest = [u for u in humans if u.get("is_restricted") and not u.get("is_ultra_restricted")]
    single_guest = [u for u in humans if u.get("is_ultra_restricted")]
    print(f"  humans={len(humans)}  full-members={len(humans) - len(multi_guest) - len(single_guest)}")
    print(f"  multi-channel guests={len(multi_guest)}  single-channel guests={len(single_guest)}")
    print(f"  bot users (installed-app proxy)={len(bots)}")
    if bots:
        print("  bot users / apps present (verify + remove via /apps/manage UI):")
        for b in sorted(bots, key=lambda u: (u.get("real_name") or u.get("name") or "")):
            print(f"    - {b.get('real_name') or b.get('name')}")

    print("\n## Files and storage")
    files = paginate("files.list", "files", count=200)
    total = sum(f.get("size", 0) for f in files)
    print(f"  count={len(files)}  total={human_size(total)}")
    old = [f for f in files if days_ago(f.get("created")) and days_ago(f["created"]) > 365]
    big = sorted(files, key=lambda f: -f.get("size", 0))[:10]
    print(f"  DELETE CANDIDATES: {len(old)} older than 365d")
    if big:
        print("  largest files:")
        for f in big:
            print(f"    - {human_size(f.get('size', 0)):>8}  {(f.get('title') or f.get('name') or '')[:50]}")

    if "--json" in sys.argv:
        out = sys.argv[sys.argv.index("--json") + 1]
        with open(out, "w") as fh:
            json.dump({"channels": rows, "bots": [b.get("name") for b in bots], "file_count": len(files), "file_bytes": total}, fh, indent=2)
        print(f"\n  raw inventory -> {out}")


if __name__ == "__main__":
    main()
