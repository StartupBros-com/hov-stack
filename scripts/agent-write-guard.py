#!/usr/bin/env python3
"""agent-write-guard — detect SSD-hostile write patterns from coding-agent harnesses.

WHY THIS EXISTS (incident 2026-08-06)
  openai/codex#28224: Codex attached its persistent SQLite log sink
  (~/.codex/logs_2.sqlite) with a global TRACE filter, so every websocket frame,
  OTel mirror record and inotify event was INSERTed into a table that retains only
  a small rolling window. Insert-then-prune churn through the WAL produced 37 TB of
  physical writes in 21 days (~640 TB/yr) for one reporter, and killed a 13-month-old
  4 TB NVMe for another. Fixed upstream in 0.142.0/0.143.0.

  We were still hit — not by the upstream bug, but by our own harness. An
  app-server-broker from codex 0.142.5 was left running after its worktree was
  swept out from under it. It ran orphaned for 15 days and wrote ~400 GiB (37 GiB/day,
  57% of ALL disk writes on the box) to record `inotify event: ... ld.so.cache` at
  65 rows/sec. Nothing in the harness noticed, because nothing was looking.

  The defining property of this failure is that SIZE ON DISK HIDES IT. The file
  stayed at 337 MB the whole time; only the *rate* and the *churn ratio* reveal it.
  So this checks rates and ratios, not sizes.

CHECKS
  orphan      agent daemons whose --cwd/--worktree target no longer exists
  version     installed codex builds older than the #28224 fix (0.143.0)
  churn       agent SQLite log DBs where max(rowid) >> retained rows
  write-rate  per-process block-layer writes sampled over a window

Report-only: reads /proc and opens SQLite read-only. Kills nothing, deletes nothing.
Exit 0 = clean, 1 = findings (same contract as harness-doctor.sh).

Usage:
  agent-write-guard.py                 # full pass, 30s rate sample
  agent-write-guard.py --skip-rate     # instant checks only
  agent-write-guard.py --json          # machine-readable
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time

HOME = os.path.expanduser("~")

# A single agent process sustaining this much is not normal background bookkeeping.
# Calibrated against the incident: the orphan sat at 37 GiB/day, healthy codex
# 0.145.0 on the same box sits at ~0.1 GiB/day — three orders of magnitude apart,
# so the exact threshold is not delicate.
WRITE_GIB_DAY_WARN = 5.0
WRITE_GIB_DAY_CRIT = 20.0

# Retained rows vs allocated rowids. AUTOINCREMENT never reuses ids, so this ratio
# is a durable historical record of insert-and-prune churn even after the writer
# dies. The incident DB read 2,653,846:1.
CHURN_RATIO_WARN = 1_000

# First codex release carrying the full #28224 log-volume fix (PRs 29432/29457/29599).
CODEX_FIXED = (0, 143, 0)

AGENT_PAT = re.compile(
    r"(codex|claude|ccflare|opencode|cass|coding-agent-search|app-server|broker\.mjs)",
    re.I,
)
CWD_FLAG = re.compile(r"--(?:cwd|worktree|workdir|project-dir)[= ]([^\s\0]+)")
# Only long-lived daemons are orphan candidates. A `bash -c` wrapper that merely
# QUOTES a --cwd string inside its script body is not a daemon holding a deleted
# directory open, and flagging it buries the real finding in noise.
DAEMON_PAT = re.compile(r"(app-server|broker\.mjs|--serve|daemon|/bin/codex\b)", re.I)
SHELL_WRAPPER = re.compile(r"^\S*/?(?:ba|z|da)?sh\s+-[a-z]*c\b")

def windows_homes() -> list[str]:
    """Windows user profiles visible from WSL, e.g. /mnt/c/Users/<name>.

    Globbed, never hardcoded: under WSL the same agent tools keep a SECOND set of
    state on the Windows side, on the same physical SSD, and an audit that only
    looks at $HOME misses half the damage. Returns [] off WSL.
    """
    out = []
    for drive in sorted(glob.glob("/mnt/[a-z]/Users")):
        for prof in sorted(glob.glob(f"{drive}/*")):
            if os.path.isdir(prof) and os.path.basename(prof) not in (
                "Public", "Default", "Default User", "All Users",
            ):
                out.append(prof)
    return out


# Globbed rather than hardcoded so a future logs_3.sqlite, a different pnpm store
# version, or another operator's username is covered without editing this file.
def log_db_globs() -> list[str]:
    pats = [f"{HOME}/.codex/logs_*.sqlite", f"{HOME}/.codex/sqlite/logs_*.sqlite"]
    pats += [f"{w}/.codex/logs_*.sqlite" for w in windows_homes()]
    return pats


def codex_pkg_roots() -> list[str]:
    roots = glob.glob(f"{HOME}/.local/share/pnpm/global/*/.pnpm")
    roots += glob.glob(f"{HOME}/.nvm/versions/node/*/lib/node_modules/@openai")
    roots += [f"{HOME}/.local/share/pnpm/global/5/.pnpm"]
    roots += [f"{w}/AppData/Roaming/npm/node_modules/@openai" for w in windows_homes()]
    return [r for r in dict.fromkeys(roots) if os.path.isdir(r)]


HAVE_PROC = os.path.isdir("/proc/self")


# --------------------------------------------------------------------------- procs


def _read_proc(pid: str) -> tuple[str, str, int] | None:
    """(cmdline, ppid, net_write_bytes) for one pid, or None if unreadable/gone."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            cmd = f.read().replace(b"\x00", b" ").decode("utf8", "replace").strip()
        with open(f"/proc/{pid}/stat") as f:
            ppid = f.read().split()[3]
        with open(f"/proc/{pid}/io") as f:
            io = dict(line.split(": ") for line in f.read().strip().split("\n"))
    except (OSError, ValueError, IndexError):
        return None
    if not cmd:
        return None
    net = int(io.get("write_bytes", 0)) - int(io.get("cancelled_write_bytes", 0))
    return cmd, ppid, net


def _pids() -> list[str]:
    return [p for p in os.listdir("/proc") if p.isdigit()]


def reaper_pids() -> set[str]:
    """Pids that adopt orphans. WSL reparents to /init, NOT to pid 1."""
    reapers = {"1"}
    if not HAVE_PROC:
        return reapers
    for pid in _pids():
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                if f.read().replace(b"\x00", b" ").strip() in (b"/init", b"/sbin/init"):
                    reapers.add(pid)
        except OSError:
            continue
    return reapers


# -------------------------------------------------------------------------- checks


def is_orphan_candidate(cmd: str) -> str | None:
    """Missing --cwd target for a daemon-shaped cmdline, else None.

    Split out from check_orphans so the filter chain is testable without /proc.
    """
    if not AGENT_PAT.search(cmd):
        return None
    if SHELL_WRAPPER.match(cmd) or not DAEMON_PAT.search(cmd):
        return None
    for target in CWD_FLAG.findall(cmd):
        target = target.strip("'\"")
        if target.startswith("/") and not os.path.exists(target):
            return target
    return None


def _ps_snapshot() -> list[tuple[str, str, str]]:
    """(pid, ppid, cmdline) for every process, via /proc or `ps` off-Linux.

    The orphan and version checks are the portable ones — they work anywhere with
    `ps`. Only the write-rate check genuinely needs /proc's io accounting.
    """
    if HAVE_PROC:
        rows = []
        for pid in _pids():
            info = _read_proc(pid)
            if info:
                rows.append((pid, info[1], info[0]))
        return rows
    try:
        out = subprocess.run(
            ["ps", "-eo", "pid=,ppid=,args="], capture_output=True, text=True, timeout=10
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            rows.append((parts[0], parts[1], parts[2]))
    return rows


def check_orphans() -> list[dict]:
    findings, reapers = [], reaper_pids()
    for pid, ppid, cmd in _ps_snapshot():
        target = is_orphan_candidate(cmd)
        if target is None:
            continue
        findings.append(
            {
                "check": "orphan",
                "severity": "crit",
                "pid": pid,
                "ppid": ppid,
                "reparented": ppid in reapers,
                "missing_target": target,
                "cmd": cmd[:160],
                "note": "daemon outlived the worktree it was launched for; "
                "it will keep writing until killed",
            }
        )
    return findings


# Matching on the ExecStart *binary* alone is useless: units routinely start
# /usr/bin/python3, /bin/sh, node or ssh, and every unrelated process running that
# interpreter then looks like a zombie. First draft of this check produced 5 false
# positives to 1 real finding. Match the full argv instead.
INTERPRETERS = re.compile(
    r"/(python[0-9.]*|node|bun|deno|sh|bash|zsh|ssh|env|pnpm|npm|npx|uv|ruby|perl)$"
)


def unit_exec_cmd(show_output: str) -> str | None:
    """Full ExecStart argv from `systemctl show -p ExecStart` output.

    Format: `ExecStart={ path=/usr/bin/foo ; argv[]=/usr/bin/foo --flag ; ... }`
    (or `ExecStart[0]={...}` on newer systemd). Returns None when the argv is a
    bare interpreter with no distinguishing arguments — unmatchable without noise.
    Pure, so it is testable without systemd present.
    """
    m = re.search(r"argv\[\]=([^;}]+)", show_output)
    if not m:
        return None
    argv = " ".join(m.group(1).split())
    if not argv.startswith("/"):
        return None
    parts = argv.split()
    if len(parts) == 1 and INTERPRETERS.search(parts[0]):
        return None
    return argv


def parse_cgroup(text: str) -> str | None:
    """systemd unit owning a process, from /proc/<pid>/cgroup. None if unsupervised.

    An orphan lands in /init.scope (WSL) or a bare session scope; a supervised
    process sits in <slice>/<unit>.service. Pure, so it is testable.

    Takes the LAST .service in the path, not the first: a user-scope unit nests
    under user@1000.service, and the first match would name the session manager
    for every user unit on the box rather than the actual owning unit.
    """
    matches = re.findall(r"/([A-Za-z0-9_.@\-]+\.service)", text)
    return matches[-1] if matches else None


def supervising_unit(pid: str) -> str | None:
    try:
        with open(f"/proc/{pid}/cgroup") as f:
            return parse_cgroup(f.read())
    except OSError:
        return None


def check_zombie_units() -> list[dict]:
    """Processes still running while their systemd unit is inactive.

    The second orphan found on 2026-08-06: onwatch's unit was `disabled` AND
    `inactive`, but nobody killed the process — it ran 10 days reparented to init.
    `systemctl disable` does not stop anything, and `stop` does not reap a process
    that has already detached, so "I turned that off" and "that is not running" are
    different facts. Neither the --cwd orphan check nor the write-rate threshold
    catches this shape: onwatch had no --cwd flag and wrote only ~44 MiB/day.
    """
    if not shutil.which("systemctl"):
        return []

    running = _ps_snapshot()
    findings = []
    candidates: list[tuple[str, str, str]] = []  # (scope, unit, exec_cmd)

    for scope, flag in (("system", []), ("user", ["--user"])):
        try:
            listing = subprocess.run(
                ["systemctl", *flag, "list-unit-files", "--type=service",
                 "--no-legend", "--no-pager"],
                capture_output=True, text=True, timeout=15,
            ).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        for line in listing.splitlines():
            parts = line.split()
            if len(parts) < 2:
                continue
            unit, state = parts[0], parts[1]
            try:
                show = subprocess.run(
                    ["systemctl", *flag, "show", "-p", "ExecStart", "-p", "ActiveState", unit],
                    capture_output=True, text=True, timeout=10,
                ).stdout
            except (OSError, subprocess.SubprocessError):
                continue
            exec_cmd = unit_exec_cmd(show)
            if not exec_cmd or "ActiveState=active" in show:
                continue
            if state in ("disabled", "masked"):
                candidates.append((scope, unit, exec_cmd))

    for scope, unit, exec_cmd in candidates:
        for pid, ppid, cmd in running:
            if exec_cmd not in " ".join(cmd.split()):
                continue
            # Ask the kernel who owns it, not the unit files. A disabled unit in one
            # scope routinely shadows an ACTIVE unit in the other, and the two can
            # declare different ExecStart lines for the same process (a wrapper that
            # exec's the real binary), so argv cross-referencing silently fails.
            # The cgroup is the authoritative record.
            if supervising_unit(pid):
                break
            findings.append({
                "check": "zombie-unit",
                "severity": "crit",
                "pid": pid,
                "ppid": ppid,
                "unit": f"{unit} ({scope} scope)",
                "exec": exec_cmd[:100],
                "note": "process still running while its systemd unit is off, and no "
                        "active unit in either scope owns it; `disable` does not stop, "
                        "and `stop` does not reap a detached child",
            })
            break
    return findings


def parse_version(text: str) -> tuple[int, ...] | None:
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", text)
    return tuple(int(x) for x in m.groups()) if m else None


def check_versions() -> list[dict]:
    findings, seen = [], set()
    for root in codex_pkg_roots():
        try:
            entries = os.listdir(root)
        except OSError:
            continue
        for entry in entries:
            if "codex" not in entry.lower():
                continue
            v = parse_version(entry)
            if not v or v in seen or v >= CODEX_FIXED:
                continue
            seen.add(v)
            findings.append(
                {
                    "check": "version",
                    "severity": "crit",
                    "path": os.path.join(root, entry),
                    "version": ".".join(map(str, v)),
                    "note": "predates the #28224 log-volume fix "
                    f"({'.'.join(map(str, CODEX_FIXED))}); a long-lived daemon "
                    "from this build writes tens of GiB/day",
                }
            )
    return findings


def churn_severity(retained: int, max_rowid: int, size_bytes: int) -> str | None:
    """'crit' | 'warn' | None for one log DB's shape. Pure, so it is testable."""
    ratio = (max_rowid / retained) if retained else 0
    if ratio >= CHURN_RATIO_WARN:
        return "crit"
    if size_bytes > 256 * 1024 * 1024:
        return "warn"
    return None


def check_churn() -> list[dict]:
    findings = []
    for pattern in log_db_globs():
        for db in sorted(glob.glob(pattern)):
            try:
                size = os.path.getsize(db)
                con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
                retained = con.execute("select count(*) from logs").fetchone()[0]
                top = con.execute("select max(rowid) from logs").fetchone()[0] or 0
                con.close()
            except (sqlite3.Error, OSError) as e:
                # SQLite cannot lock over drvfs (/mnt/c); that is expected, not a finding.
                findings.append(
                    {
                        "check": "churn",
                        "severity": "info",
                        "db": db,
                        "note": f"unreadable ({type(e).__name__}) — normal for /mnt/c over drvfs",
                    }
                )
                continue
            sev = churn_severity(retained, top, size)
            if not sev:
                continue
            findings.append(
                {
                    "check": "churn",
                    "severity": sev,
                    "db": db,
                    "size_mb": round(size / 1048576, 1),
                    "retained_rows": retained,
                    "max_rowid": top,
                    "churn_ratio": round((top / retained) if retained else 0, 1),
                    "note": "inserts far exceed retention: insert-and-prune write amplification",
                }
            )
    return findings


def check_write_rate(window: int) -> list[dict]:
    if not HAVE_PROC:
        # macOS/BSD have no per-process io accounting without root (fs_usage/dtrace).
        # Say so instead of silently returning clean — a check that reports nothing
        # and a check that found nothing must never look identical.
        return [{
            "check": "write-rate",
            "severity": "info",
            "note": "skipped: per-process write accounting needs /proc (Linux/WSL). "
                    "The orphan, version and churn checks still ran.",
        }]
    before = {p: _read_proc(p) for p in _pids()}
    time.sleep(window)
    findings = []
    for pid in _pids():
        prev, now = before.get(pid), _read_proc(pid)
        if not prev or not now:
            continue
        cmd, _, net_now = now
        delta = net_now - prev[2]
        if delta <= 0 or not AGENT_PAT.search(cmd):
            continue
        gib_day = delta / window * 86400 / 1073741824
        if gib_day < WRITE_GIB_DAY_WARN:
            continue
        findings.append(
            {
                "check": "write-rate",
                "severity": "crit" if gib_day >= WRITE_GIB_DAY_CRIT else "warn",
                "pid": pid,
                "gib_per_day": round(gib_day, 2),
                "tib_per_year": round(delta / window * 31536000 / 1099511627776, 2),
                "cmd": cmd[:160],
            }
        )
    return sorted(findings, key=lambda f: -f["gib_per_day"])


# ---------------------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--window", type=int, default=30, help="write-rate sample seconds")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--skip-rate", action="store_true", help="skip the timed sample")
    args = ap.parse_args(argv)

    findings: list[dict] = []
    findings += check_orphans()
    findings += check_zombie_units()
    findings += check_versions()
    findings += check_churn()
    if not args.skip_rate:
        findings += check_write_rate(args.window)

    actionable = [f for f in findings if f["severity"] in ("crit", "warn")]

    if args.json:
        print(json.dumps({"findings": findings}, indent=2))
    elif not actionable:
        print("agent-write-guard: clean — no SSD-hostile agent write patterns detected")
        # Surface skips even on a clean run: "nothing found" and "did not look" are
        # different states, and collapsing them is how a guard rots into decoration.
        for f in findings:
            if f["severity"] == "info" and "skipped" in str(f.get("note", "")):
                print(f"  note: {f['check']}: {f['note']}")
    else:
        for f in sorted(actionable, key=lambda x: x["severity"] != "crit"):
            tag = "CRIT" if f["severity"] == "crit" else "WARN"
            rest = {k: v for k, v in f.items() if k not in ("check", "severity")}
            print(f"[{tag}] {f['check']}: " + "  ".join(f"{k}={v}" for k, v in rest.items()))

    return 1 if actionable else 0


if __name__ == "__main__":
    sys.exit(main())
