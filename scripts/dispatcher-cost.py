#!/usr/bin/env python3
"""dispatcher-cost.py: cost/token lookup for one claude-loop run window, for
the always-on work dispatcher's ledger `ended` event (issue #444, R10/KTD6).

Reuses spend-report.py's window_row (identical SQL, one source of truth for
"how do we sum a time window over the ccflare ledger") via importlib, since
the sibling module has a hyphenated filename and cannot be `import`ed as a
normal module.

argv: <start_ms> <end_ms> -- epoch milliseconds bracketing the claude -p
run (same units as the ccflare `requests.timestamp` column).

Prints exactly one JSON object to stdout and ALWAYS exits 0: this is a
best-effort lookup called from claude-loop.sh's EXIT trap, which must never
fail (or change exit code) over a missing/unreadable ledger DB. A missing
DB WARNs to stderr and reports nulls rather than going quiet, mirroring
spend-report.py's "a dead feed is not quiet" contract.

window_cost_usd is the gateway's spend over the run's window, every session's
traffic in it included, so it bounds the run's cost from above and is not the
run's cost. It was named cost_usd before dotfiles#1429; the ledger summary
still reads that key on older rows.

A successful lookup also prints the value under cost_usd, as an alias. A
claude-loop.sh that started before the rename keeps its old exit trap in
memory, reads cost_usd, and runs this script from disk when it exits, so
without the alias that run would record a null cost. claude-loop records
only window_cost_usd in the ledger. Drop the alias on or after 2026-10-06,
once every loop run started before the rename has ended.
"""

import importlib.util
import json
import os
import sqlite3
import sys

DB = os.path.expanduser("~/.config/better-ccflare/better-ccflare.db")
NULLS = {"window_cost_usd": None, "tokens": None}


def load_window_row():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location(
        "spend_report", os.path.join(here, "spend-report.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.window_row


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: dispatcher-cost.py <start_ms> <end_ms>", file=sys.stderr)
        print(json.dumps(NULLS))
        return 0
    try:
        start_ms, end_ms = int(sys.argv[1]), int(sys.argv[2])
    except ValueError:
        print("dispatcher-cost: non-integer start/end ms", file=sys.stderr)
        print(json.dumps(NULLS))
        return 0

    if not os.path.exists(DB):
        print(f"WARN dispatcher-cost: ccflare DB missing at {DB}", file=sys.stderr)
        print(json.dumps(NULLS))
        return 0

    try:
        window_row = load_window_row()
        con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
        try:
            cost, _n, tokens = window_row(con.cursor(), start_ms, end_ms)
        finally:
            con.close()
        # cost_usd is the pre-rename alias described in the module docstring.
        print(json.dumps({"window_cost_usd": cost, "cost_usd": cost, "tokens": tokens}))
    except Exception as e:  # noqa: BLE001 -- best-effort, never fatal to the caller
        print(f"WARN dispatcher-cost: lookup failed ({type(e).__name__}: {e})", file=sys.stderr)
        print(json.dumps(NULLS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
