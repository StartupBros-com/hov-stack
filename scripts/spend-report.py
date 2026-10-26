#!/usr/bin/env python3
"""Weekly spend visibility over the better-ccflare request ledger (report-only).

Why ccflare and not transcripts: ANTHROPIC_BASE_URL routes all Claude Code
traffic through better-ccflare, whose `requests` table records per-request
cost_usd plus model/token attribution — the only durable, queryable spend
record on this box (statusline cost is render-only and freezes during subagent
runs; onwatch is retired; ccusage is ad-hoc). Codex is NOT in this ledger
(direct transport since 2026-07-03); the ccusage rollup below is the
cross-tool supplement.

Dollars are PLAN-EQUIVALENT list pricing, never billed: on subscription
billing the actionable signals are trend and model mix, and the binding
constraint (5h/7d quota) already lives on the statusline. Hence trend flags,
deliberately no budgets or caps (see spend-visibility posture memory,
2026-08-08, and HARNESS.md's gated downgrade-hook trigger).

Output contract (harness-weekly): human lines, [WARN]-bracketed findings, and
a trailing `spend-flagged:N` counter for the toast gate. A dead feed prints an
unbracketed `WARN ...` line (trips the WARNS grep): a spend report that
silently reports nothing is the silent-fallback failure mode.
"""

import json
import os
import sqlite3
import subprocess
import sys
import time

# The only ccusage version string in the repo: an exact npm version, never a
# mutable selector ('latest', '^20') that npx would resolve afresh every run.
CCUSAGE_PIN = "20.0.19"

DB = os.path.expanduser("~/.config/better-ccflare/better-ccflare.db")
DAY_MS = 86_400_000

# Flag thresholds. Week-over-week noise on small absolute numbers is not
# actionable, so the jump flag needs both the ratio and a floor.
WOW_RATIO = 1.5
WOW_FLOOR_USD = 200.0
DB_SIZE_FLAG_GIB = 4.0  # live DB only; backup residue is reclaim-sweep's counter

CCUSAGE_TIMEOUT_S = 120


def window_row(cur, since_ms: int, until_ms: int):
    cur.execute(
        "SELECT COALESCE(SUM(cost_usd),0), COUNT(*), COALESCE(SUM(total_tokens),0) "
        "FROM requests WHERE timestamp >= ? AND timestamp < ?",
        (since_ms, until_ms),
    )
    return cur.fetchone()


def report_ccflare() -> int:
    flags = 0
    now_ms = int(time.time() * 1000)
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    try:
        cur = con.cursor()
        last7 = window_row(cur, now_ms - 7 * DAY_MS, now_ms)
        prev7 = window_row(cur, now_ms - 14 * DAY_MS, now_ms - 7 * DAY_MS)
        last30 = window_row(cur, now_ms - 30 * DAY_MS, now_ms)
        print(
            f"ccflare 7d:  ${last7[0]:,.0f} plan-equivalent  "
            f"({last7[1]:,} requests, {last7[2] / 1e6:,.0f}M tokens)"
        )
        print(
            f"ccflare prior 7d: ${prev7[0]:,.0f}   30d: ${last30[0]:,.0f} "
            f"({last30[1]:,} requests)"
        )
        if prev7[0] > 0 and last7[0] >= WOW_FLOOR_USD and last7[0] > WOW_RATIO * prev7[0]:
            print(
                f"[WARN] spend trend: 7d plan-equivalent ${last7[0]:,.0f} is "
                f"{last7[0] / prev7[0]:.1f}x the prior week (${prev7[0]:,.0f}) — "
                f"check model mix below and recent workflows/loops"
            )
            flags += 1

        cur.execute(
            "SELECT model, COALESCE(SUM(cost_usd),0) c, COUNT(*) n FROM requests "
            "WHERE timestamp >= ? GROUP BY model ORDER BY c DESC LIMIT 8",
            (now_ms - 7 * DAY_MS,),
        )
        rows = cur.fetchall()
        total = sum(r[1] for r in rows) or 1.0
        print("model mix 7d (by plan-equivalent cost):")
        for model, cost, n in rows:
            print(f"  {100 * cost / total:5.1f}%  ${cost:8,.0f}  {n:7,} req  {model or '(none)'}")
    finally:
        con.close()

    size_gib = os.path.getsize(DB) / 2**30
    wal = DB + "-wal"
    wal_gib = os.path.getsize(wal) / 2**30 if os.path.exists(wal) else 0.0
    print(f"ledger size: {size_gib:.1f} GiB (+{wal_gib:.1f} WAL); backup residue is reclaim-sweep's job")
    if size_gib > DB_SIZE_FLAG_GIB:
        print(
            f"[WARN] ccflare DB {size_gib:.1f} GiB exceeds {DB_SIZE_FLAG_GIB} GiB — "
            f"consider pruning old request rows (retention started 2026-06-16)"
        )
        flags += 1
    return flags


def report_ccusage() -> None:
    # Supplementary cross-tool view (claude + codex + hermes + ...): ccusage
    # reads local transcripts, including ~/.codex/sessions, which the ccflare
    # ledger cannot see. Nicety, not a guard: failure is reported in-body but
    # never WARNs — a flaky npx fetch on an offline Monday should not page.
    since = time.strftime("%Y%m%d", time.localtime(time.time() - 8 * 86400))
    try:
        out = subprocess.run(
            ["npx", "--yes", f"ccusage@{CCUSAGE_PIN}", "daily", "--json", "--since", since],
            stdout=subprocess.PIPE,
            text=True,
            timeout=CCUSAGE_TIMEOUT_S,
            check=True,
        ).stdout
        data = json.loads(out)
        days = data.get("daily", [])
        total = sum(d.get("totalCost", 0) for d in days)
        agents = sorted({a for d in days for a in (d.get("metadata", {}) or {}).get("agents", [])})
        print(
            f"cross-tool 8d plan-equivalent (ccusage: {', '.join(agents) or 'no agents field'}): "
            f"${total:,.0f} across {len(days)} day(s)"
        )
    except Exception as e:  # noqa: BLE001 — any failure gets the same one-liner
        print(f"spend: ccusage rollup unavailable ({type(e).__name__}) — ccflare numbers above are unaffected")


def main() -> int:
    flags = 0
    if os.path.exists(DB):
        try:
            flags += report_ccflare()
        except sqlite3.Error as e:
            print(f"WARN spend report: ccflare DB unreadable ({e}) — the spend feed is DEAD, not quiet")
    else:
        print(f"WARN spend report: ccflare DB missing at {DB} — the spend feed is DEAD, not quiet")
    report_ccusage()
    print(f"spend-flagged:{flags}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
