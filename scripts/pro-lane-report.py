#!/usr/bin/env python3
"""Weekly Pro-lane visibility over the pro-gate ledger (report-only).

Why this exists: the harness spends against three separate usage pools
(Claude Max, Codex agentic, ChatGPT Pro chat) and only the first has a
durable weekly read (`spend-report.py` over the better-ccflare ledger). The
Pro chat pool's sync lane — pro-gate's oracle bridge — already writes one
JSON line per run to `$PRO_GATE_HOME/ledger.jsonl` (default
`~/.pro-review-daemon`), with the two numbers that decide whether the lane
is a bottleneck: `pre_slot_secs` (time a run waited for the single-account
slot) and the `lock-timeout` outcome (a run that waited the whole window and
got nothing). Measured over EDT calendar days 2026-09-01..02 (reproduce:
`PRO_LANE_NOW=2026-09-03T04:00:00+0000 pro-lane-report.py --days 2`; the
window is rolling, so an unpinned `--days 2` reports a different slice): 45
fresh runs, 13.7 h of queue wait against 14.1 h of oracle time, 19
lock-timeouts. Nothing surfaced that until this script (umbrella
dotfiles#849, step 3).

Report, never actor: this script reads `ledger.jsonl`, lists
`in-progress/`, asks the engine's read-only `oracle-review.sh --status
--json` which reservations still hold capacity, and runs `git remote
get-url origin` against checkout paths so two checkouts of one GitHub repo
count once; it writes nothing under `$PRO_GATE_HOME`, never labels a PR,
never spends a slot. The headroom line is a fail-open preflight in the
`codex-quota-guard.js` sense — it reports what the engine says (or, when the
engine is absent or fails, what the reservation directory says as an upper
bound) and never denies anything itself. A superseded reservation (the PR
moved to a new commit) stays in `in-progress/` awaiting an optional harvest
but holds no capacity; counting it as busy is what printed "0 of 4 free"
on 2026-09-02 when the engine had 2 of 4 pinned (dotfiles#883).

Flags are trend-shaped, matching spend-report's noise floor: lock-timeouts
WARN only past a floor (PRO_LANE_LOCK_TIMEOUT_FLOOR, default 5) and a
week-over-week ratio (PRO_LANE_WOW_RATIO, default 1.5) against the prior
window of the same length, and a slot-bound median wait WARNs only when the
lane newly crosses 10 min. The body always prints the counts either way.
Stale capacity-holding reservations (older than
PRO_LANE_STALE_RESERVATION_HOURS, default 6), completed reviews still
awaiting harvest, and throttles WARN unconditionally: all are actions, not
weather. A stale reservation the engine marks superseded holds nothing and
does not WARN. One the engine reports still generating past its generation
ceiling (pro-gate#273) holds nothing either, but its owner is gone and
nothing will collect it, so it is counted on its own and WARNs.

Output contract (harness-weekly): human lines, `[WARN]`-bracketed findings,
and a trailing `pro-lane-flagged:N` counter for the toast gate. A missing
ledger prints an unbracketed `WARN ...` line (trips the WARNS grep): a lane
report that silently reports nothing is the silent-fallback failure mode.

Env seams: PRO_GATE_HOME (ledger + in-progress dir + engine), PRO_LANE_NOW
(ISO timestamp, tests only), PRO_GATE_MAX_CONCURRENCY (ceiling override),
PRO_LANE_ENGINE_STATUS (set to 0 to skip the engine call and count files),
PRO_LANE_ASYNC_ROOT (async-lane freshness via scripts/fleet_status.py under
the configured root; unset or a missing script prints a skipped line, never faked).
"""

import argparse
import datetime as _dt
import json
import os
import re
import statistics
import subprocess
import sys

MODEL_DENYLIST = re.compile(r"\b(mini|nano|instant)\b", re.IGNORECASE)
OWNER_PREFIXES = ("StartupBros-com-", "StartupBros-")


def home_dir():
    return os.environ.get("PRO_GATE_HOME") or os.path.expanduser("~/.pro-review-daemon")


def now_utc():
    raw = os.environ.get("PRO_LANE_NOW")
    if raw:
        parsed = parse_ts(raw)
        if parsed is not None:
            return parsed
    return _dt.datetime.now(_dt.timezone.utc)


def parse_ts(raw):
    """Ledger timestamps look like 2026-09-01T23:51:17-0400 (no colon in the
    offset). Accept that, the colon form, and a trailing Z."""
    if not raw:
        return None
    text = raw.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+0000"
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S.%f%z"):
        try:
            return _dt.datetime.strptime(text, fmt)
        except ValueError:
            pass
    try:
        parsed = _dt.datetime.fromisoformat(raw.strip())
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.timezone.utc)
    return parsed


def read_ledger(path):
    rows, malformed = [], 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                malformed += 1
                continue
            if not isinstance(row, dict):
                malformed += 1
                continue
            rows.append(row)
    return rows, malformed


def _repo_from_marker(marker):
    stem = re.sub(r"-\d+-\d+-\d+$", "", marker[len("pg-run-"):])
    for prefix in OWNER_PREFIXES:
        if stem.startswith(prefix):
            return stem[len(prefix):]
    return stem


_REMOTE_CACHE = {}


def _repo_from_remote(path):
    """Read-only `git -C <path> remote get-url origin`, cached per path.
    Two local checkouts of one GitHub repo (`~/SITES/example-app` and
    `~/SITES/announce-bot` are both acme-org/announce-bot) would otherwise read
    as two consumers. Returns None when the path is gone or has no origin;
    PRO_LANE_RESOLVE_REMOTES=0 disables the lookup entirely."""
    if os.environ.get("PRO_LANE_RESOLVE_REMOTES", "1") == "0":
        return None
    if path in _REMOTE_CACHE:
        return _REMOTE_CACHE[path]
    name = None
    probe = path
    # A worktree that has since been swept still names its parent checkout in
    # the path; resolve through that rather than falling back to the basename.
    if not os.path.isdir(probe) and "/.claude/worktrees/" in probe:
        probe = probe.split("/.claude/worktrees/", 1)[0]
    if os.path.isdir(probe):
        try:
            proc = subprocess.run(["git", "-C", probe, "remote", "get-url", "origin"],
                                  capture_output=True, text=True, timeout=5, check=False)
            url = proc.stdout.strip() if proc.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            url = ""
        match = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$", url)
        if match:
            name = match.group(2)
    _REMOTE_CACHE[path] = name
    return name


def repo_name(row):
    repo = row.get("repo") or ""
    marker = row.get("marker") or ""
    if repo and not repo.startswith("/tmp/pro-gate-"):
        resolved = _repo_from_remote(repo)
        if resolved:
            return resolved
    match = re.search(r"/SITES/([^/]+)", repo)
    if match:
        return match.group(1)
    match = re.search(r"/([^/]+)/\.claude/worktrees/", repo)
    if match:
        return match.group(1)
    if repo.startswith("/tmp/pro-gate-"):
        return "diff-fork"
    if not repo and marker.startswith("pg-run-"):
        return _repo_from_marker(marker)
    if repo:
        base = os.path.basename(repo.rstrip("/")) or repo
        # Autoclone checkouts end in a literal `repo/` directory; the marker
        # still names the GitHub repo, so prefer it over the bare basename.
        if base == "repo" and marker.startswith("pg-run-"):
            return _repo_from_marker(marker)
        return base
    return "unknown"


def percentile(values, pct):
    if not values:
        return 0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, int(round((pct / 100.0) * (len(ordered) - 1)))))
    return ordered[idx]


def summarize(rows, now, days, end=None):
    """Rows with cutoff <= ts (< end when end is given). The current window has
    no upper bound; the prior window passes end=cutoff of the current one."""
    cutoff = now - _dt.timedelta(days=days)
    window = []
    for row in rows:
        ts = parse_ts(row.get("ts", ""))
        if ts is None or ts < cutoff or (end is not None and ts >= end):
            continue
        window.append(row)
    fresh = [r for r in window if r.get("kind") == "fresh"]
    harvests = [r for r in window if r.get("kind") == "harvest"]
    outcomes = {}
    for row in fresh:
        key = row.get("outcome") or "?"
        outcomes[key] = outcomes.get(key, 0) + 1
    # pro-gate#143: failed rows carry a closed-enum `reason` from v0.40. Rows written before
    # the field existed have no key at all; label them rather than fold them into one bucket.
    reasons = {}
    for row in fresh:
        if row.get("outcome") != "failed":
            continue
        key = row.get("reason") if "reason" in row else "(pre-v0.40, unclassified)"
        key = key or "(empty)"
        reasons[key] = reasons.get(key, 0) + 1
    per_repo = {}
    for row in fresh:
        key = repo_name(row)
        per_repo[key] = per_repo.get(key, 0) + 1
    waits = [int(r.get("pre_slot_secs") or 0) for r in fresh]
    oracle = [int(r.get("post_slot_secs") or 0) for r in fresh if r.get("outcome") != "lock-timeout"]
    ceilings = [r.get("ceiling") for r in fresh if isinstance(r.get("ceiling"), int)]
    concs = [r.get("conc") for r in fresh if isinstance(r.get("conc"), int)]
    models = {}
    for row in window:
        label = (row.get("model") or "").strip()
        if label:
            models[label] = models.get(label, 0) + 1
    return {
        "days": days,
        "window_rows": len(window),
        "fresh": len(fresh),
        "harvests": len(harvests),
        "outcomes": outcomes,
        "reasons": dict(sorted(reasons.items(), key=lambda kv: (-kv[1], kv[0]))),
        "per_repo": dict(sorted(per_repo.items(), key=lambda kv: -kv[1])),
        "wait_p50": statistics.median(waits) if waits else 0,
        "wait_p90": percentile(waits, 90),
        "wait_max": max(waits) if waits else 0,
        "wait_sum": sum(waits),
        "oracle_sum": sum(oracle),
        "lock_timeouts": outcomes.get("lock-timeout", 0),
        "throttles": outcomes.get("throttle", 0),
        "round_capped": outcomes.get("round-capped", 0),
        "ceiling_seen": max(ceilings) if ceilings else None,
        "conc_seen": max(concs) if concs else None,
        "models": models,
    }


def _run_json(argv, timeout):
    """Run a read-only helper and parse its stdout as JSON. Returns (data, None)
    on success or (None, reason) with a short phrase the report line can quote."""
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return None, "timed out after %ds" % timeout
    except (OSError, subprocess.SubprocessError) as exc:
        return None, "failed to run (%s)" % exc
    if proc.returncode != 0:
        return None, "exit %d" % proc.returncode
    try:
        return json.loads(proc.stdout), None
    except ValueError:
        return None, "emitted non-JSON"


def engine_reservations(home):
    """Ask the engine's read-only `--status --json` which reservations still
    hold capacity. Returns ({marker: {"holds": bool, "state": str}}, None), or
    (None, reason) when the engine is absent, disabled
    (PRO_LANE_ENGINE_STATUS=0), fails, times out, emits non-JSON, or omits the
    reservations list — callers then fall back to the file count, an upper
    bound, and print the reason. Only an explicit false releases capacity:
    null, absent, or any other value keeps the upper bound (pins). The
    engine's `--status` is its documented read-only diagnostic; nothing here
    writes under $PRO_GATE_HOME."""
    if os.environ.get("PRO_LANE_ENGINE_STATUS", "1") == "0":
        return None, "disabled (PRO_LANE_ENGINE_STATUS=0)"
    engine = os.path.join(home, "oracle-review.sh")
    if not (os.path.isfile(engine) and os.access(engine, os.X_OK)):
        return None, "absent"
    data, err = _run_json([engine, "--status", "--json"], timeout=45)
    if err:
        return None, err
    recs = data.get("reservations") if isinstance(data, dict) else None
    if not isinstance(recs, list):
        return None, "returned no reservations list"
    out = {}
    for rec in recs:
        if not isinstance(rec, dict) or not rec.get("marker"):
            continue
        holds = rec.get("holds_capacity")
        released = holds is False or (isinstance(holds, str) and holds.strip().lower() in ("false", "0"))
        out[str(rec["marker"])] = {"holds": not released, "state": str(rec.get("state") or "")}
    return out, None


def headroom(home, ledger_ceiling, now):
    """Which reservations pin a slot. Preferred source: the engine's own
    `--status --json`, whose `holds_capacity` is false for a superseded run
    (the PR moved on; the reservation lingers only for an optional harvest)
    and for a complete one (the review finished and released its slot but
    nobody collected it yet — paid-for work, reported separately). Fallback
    when the engine is unavailable: every `in-progress/<marker>` file counts,
    an upper bound (an uncollected reservation still reads 'generating' to
    the account); complete/superseded are then unknown (None), not zero.
    Ceiling: PRO_GATE_MAX_CONCURRENCY, else the ceiling the ledger last saw,
    else 1."""
    env_ceiling = os.environ.get("PRO_GATE_MAX_CONCURRENCY")
    ceiling = None
    if env_ceiling and env_ceiling.isdigit():
        ceiling = int(env_ceiling)
    elif isinstance(ledger_ceiling, int) and ledger_ceiling > 0:
        ceiling = ledger_ceiling
    else:
        ceiling = 1
    res_dir = os.path.join(home, "in-progress")
    reservations = []
    if os.path.isdir(res_dir):
        for name in sorted(os.listdir(res_dir)):
            path = os.path.join(res_dir, name)
            if name.endswith(".lock") or not os.path.isfile(path):
                continue
            created = None
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    fields = fh.readline().rstrip("\n").split("\t")
                if len(fields) >= 3 and fields[2].isdigit():
                    created = int(fields[2])
            except OSError:
                pass
            if created is None:
                try:
                    created = int(os.path.getmtime(path))
                except OSError:
                    created = None
            reservations.append((name, created))
    engine, engine_note = engine_reservations(home)
    source = "engine" if engine is not None else "files"
    if engine is not None:
        # A reservation the engine indexed after the directory listing above still exists now.
        listed = {n for n, _ in reservations}
        for marker, info in engine.items():
            if marker not in listed and info["holds"]:
                reservations.append((marker, None))
        # Unknown to the engine (a file it has not indexed yet) keeps the upper bound: it pins.
        pinning = [(n, c) for n, c in reservations if n not in engine or engine[n]["holds"]]
        released = [n for n, _ in reservations if n in engine and not engine[n]["holds"]]
        complete = sum(1 for n in released if engine[n]["state"].startswith("complete"))
        # pro-gate#273: a review still generating past the engine's generation ceiling no
        # longer pins a slot, but it is not superseded either: its owner died or parked, and
        # nothing is collecting it. Before the ceiling the 6h stale WARN caught it.
        past_ceiling = sum(1 for n in released if engine[n]["state"] == "past-generation-ceiling")
        superseded = len(released) - complete - past_ceiling
    else:
        pinning = list(reservations)
        complete = None
        superseded = None
        past_ceiling = None
    busy = len(pinning)
    free = max(0, ceiling - busy)
    oldest = ""
    ages = [int(now.timestamp()) - c for _, c in pinning if c is not None]
    if ages:
        oldest = ", oldest %dm" % (max(ages) // 60)
    # An uncollected reservation reads "generating — still using the account"
    # until it is harvested (exit 0) or declared lost (exit 6); past a few
    # hours it is pinning a slot nobody will ever collect. The engine's own
    # harvest window is under an hour, so 6h is a generous default. Only
    # capacity-holding reservations count: a stale superseded one pins nothing.
    stale_after = os.environ.get("PRO_LANE_STALE_RESERVATION_HOURS", "6")
    stale_hours = float(stale_after) if re.match(r"^\d+(\.\d+)?$", stale_after) else 6.0
    stale = sum(1 for age in ages if age > stale_hours * 3600)
    if source == "engine":
        past = ("; %d past the generation ceiling (owner gone, no capacity)" % past_ceiling
                if past_ceiling else "")
        line = ("sync-lane headroom: %d of %d slot(s) free — %d live reservation(s) pin a slot%s; "
                "%d complete awaiting harvest; %d superseded (optional harvest, no capacity)%s "
                "— per oracle-review.sh --status"
                % (free, ceiling, busy, oldest, complete, superseded, past))
    else:
        line = ("sync-lane headroom: %d of %d slot(s) free — %d live reservation(s)%s "
                "(upper bound: a reservation pins a slot until harvested; engine --status %s)"
                % (free, ceiling, busy, oldest, engine_note))
    return {
        "ceiling": ceiling,
        "busy": busy,
        "free": free,
        "complete": complete,
        "superseded": superseded,
        "past_ceiling": past_ceiling,
        "source": source,
        "engine_note": engine_note,
        "stale": stale,
        "stale_hours": stale_hours,
        "line": line,
    }


def async_lane():
    root = os.environ.get("PRO_LANE_ASYNC_ROOT")
    if not root:
        return {"line": "async lane: PRO_LANE_ASYNC_ROOT not configured (skipped)", "rows": None}
    script = os.path.join(root, "scripts", "fleet_status.py")
    if not os.path.isfile(script):
        return {"line": "async lane: fleet_status.py not found under %s (skipped)" % root, "rows": None}
    rows, err = _run_json([sys.executable, script, "--root", root, "--json"], timeout=60)
    if err:
        return {"line": "async lane: fleet_status.py %s (skipped)" % err, "rows": None}
    if not isinstance(rows, list):
        return {"line": "async lane: fleet_status.py emitted no row list (skipped)", "rows": None}
    active = sum(1 for r in rows if str(r.get("status", "")).startswith("active"))
    waiting = sum(1 for r in rows if r.get("waiting"))
    missing = sum(1 for r in rows if r.get("source") == "missing")
    return {
        "line": "async lane: %d thread row(s), %d active, %d WAITING past the stale window, %d missing a log dir — read-only, per fleet_status.py"
        % (len(rows), active, waiting, missing),
        "rows": len(rows), "active": active, "waiting": waiting,
    }


def fmt_secs(secs):
    secs = int(secs or 0)
    if secs >= 3600:
        return "%.1fh" % (secs / 3600.0)
    return "%dm" % (secs // 60)


def render(summary, head, asy, malformed, ledger_path):
    lines, flags = [], []
    lines.append("sync lane (pro-gate oracle bridge) — last %d day(s), ledger %s" % (summary["days"], ledger_path))
    lines.append("fresh runs: %d (harvests: %d; ledger rows in window: %d; malformed lines: %d)"
                 % (summary["fresh"], summary["harvests"], summary["window_rows"], malformed))
    if summary["outcomes"]:
        lines.append("outcomes: " + ", ".join("%s=%d" % kv for kv in sorted(summary["outcomes"].items(), key=lambda kv: -kv[1])))
    if summary.get("reasons"):
        lines.append("failed by reason: " + ", ".join("%s=%d" % kv for kv in summary["reasons"].items()))
    if summary["per_repo"]:
        lines.append("per repo: " + ", ".join("%s: %d" % kv for kv in summary["per_repo"].items()))
    lines.append("queue wait (pre-slot): p50 %s, p90 %s, max %s, sum %s; oracle time sum %s; lock-timeouts: %d; throttles: %d; round-capped: %d"
                 % (fmt_secs(summary["wait_p50"]), fmt_secs(summary["wait_p90"]), fmt_secs(summary["wait_max"]),
                    fmt_secs(summary["wait_sum"]), fmt_secs(summary["oracle_sum"]),
                    summary["lock_timeouts"], summary["throttles"], summary["round_capped"]))
    if summary["ceiling_seen"] is not None:
        lines.append("concurrency seen: %s of ceiling %s" % (summary["conc_seen"], summary["ceiling_seen"]))
    if summary["models"]:
        labels = "; ".join("%s (x%d)" % (k[:70], v) for k, v in sorted(summary["models"].items(), key=lambda kv: -kv[1])[:3])
        lines.append("model label(s): " + labels)
        for label in summary["models"]:
            if MODEL_DENYLIST.search(label):
                flags.append("[WARN] pro-lane: a run's resolved model label matches the weak-model denylist (%s)" % label[:60])
                break
    prev = summary.get("prev") or {}
    lines.append("prior %d-day window: fresh %d, lock-timeouts %d, queue wait p50 %s"
                 % (summary["days"], prev.get("fresh", 0), prev.get("lock_timeouts", 0), fmt_secs(prev.get("wait_p50", 0))))
    lines.append(head["line"])
    lines.append(asy["line"])
    floor = _env_number("PRO_LANE_LOCK_TIMEOUT_FLOOR", 5)
    ratio = _env_number("PRO_LANE_WOW_RATIO", 1.5)
    cur_lt, prev_lt = summary["lock_timeouts"], prev.get("lock_timeouts", 0)
    if cur_lt >= floor and cur_lt >= ratio * prev_lt:
        flags.append("[WARN] pro-lane: %d lock-timeout(s) this window vs %d prior (floor %g, ratio %g) — agents waited the whole slot window and got no review; the sync lane is slot-bound"
                     % (cur_lt, prev_lt, floor, ratio))
    if head.get("stale", 0) > 0:
        if head.get("source") == "engine":
            flags.append("[WARN] pro-lane: %d capacity-holding reservation(s) older than %gh still in in-progress/ — each pins a slot until collected; `oracle-review.sh --recover <marker>` spends no slot"
                         % (head["stale"], head["stale_hours"]))
        else:
            flags.append("[WARN] pro-lane: %d reservation(s) older than %gh still in in-progress/ — an uncollected reservation pins a slot until harvested (exit 0) or declared lost (exit 6)"
                         % (head["stale"], head["stale_hours"]))
    if head.get("complete"):
        flags.append("[WARN] pro-lane: %d completed review(s) awaiting harvest — the slot is already released and the review is paid for; collect with `oracle-review.sh --harvest <marker>` (no spend)"
                     % head["complete"])
    if head.get("past_ceiling"):
        flags.append("[WARN] pro-lane: %d reservation(s) still generating past the engine's generation ceiling — no longer pinning a slot, but nothing is collecting them; `oracle-review.sh --recover <marker>` spends no slot"
                     % head["past_ceiling"])
    if summary["throttles"] > 0:
        flags.append("[WARN] pro-lane: %d throttle outcome(s) — the account tripped ChatGPT's limiter; do not raise concurrency" % summary["throttles"])
    was_bound = prev.get("fresh", 0) >= 5 and prev.get("wait_p50", 0) >= 600
    if summary["fresh"] >= 5 and summary["wait_p50"] >= 600 and not was_bound:
        flags.append("[WARN] pro-lane: median queue wait %s (>= 10m) across %d fresh runs, up from %s prior — capacity, not latency, is now the constraint"
                     % (fmt_secs(summary["wait_p50"]), summary["fresh"], fmt_secs(prev.get("wait_p50", 0))))
    return lines, flags


def _env_number(name, default):
    raw = os.environ.get(name, "")
    if re.match(r"^\d+(\.\d+)?$", raw or ""):
        return float(raw)
    return float(default)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Pro-lane weekly report (report-only)")
    parser.add_argument("--days", type=int, default=7, help="window in days (default 7)")
    parser.add_argument("--headroom", action="store_true", help="print only the sync-lane headroom line")
    parser.add_argument("--json", action="store_true", help="emit the summary as JSON")
    args = parser.parse_args(argv)

    home = home_dir()
    ledger_path = os.path.join(home, "ledger.jsonl")
    now = now_utc()
    rows, malformed, dead = [], 0, False
    if os.path.isfile(ledger_path):
        try:
            rows, malformed = read_ledger(ledger_path)
        except OSError as exc:
            dead = True
            dead_reason = "unreadable (%s)" % exc
    else:
        dead = True
        dead_reason = "not found"
    summary = summarize(rows, now, args.days)
    cutoff = now - _dt.timedelta(days=args.days)
    prev = summarize(rows, cutoff, args.days, end=cutoff)
    summary["prev"] = {k: prev[k] for k in ("fresh", "lock_timeouts", "wait_p50", "throttles", "oracle_sum")}
    head = headroom(home, summary["ceiling_seen"], now)

    if args.headroom:
        print(head["line"])
        return 0

    asy = async_lane()
    if args.json:
        print(json.dumps({"summary": summary, "headroom": {k: v for k, v in head.items() if k != "line"},
                          "async": {k: v for k, v in asy.items() if k != "line"}, "malformed": malformed,
                          "dead_feed": dead}, indent=2, default=str))
        return 0

    flagged = 0
    if dead:
        print("WARN pro-lane: ledger %s at %s — dead feed, the sync lane reports nothing" % (dead_reason, ledger_path))
        print(head["line"])
        print(asy["line"])
        print("pro-lane-flagged:%d" % flagged)
        return 0
    lines, flags = render(summary, head, asy, malformed, ledger_path)
    for line in lines:
        print(line)
    for flag in flags:
        print(flag)
        flagged += 1
    print("pro-lane-flagged:%d" % flagged)
    return 0


if __name__ == "__main__":
    sys.exit(main())
