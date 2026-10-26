#!/usr/bin/env python3
"""hook-seam-check.py: detect a PreToolUse hook seam that stopped firing mid-session.

Ceremony Test (HARNESS.md, Doctrine -> Evidence regime):
  consumer     harness-weekly.sh, via the trailing `seam-flagged:N` line that
               drives the Windows toast; plus any operator running it ad hoc
               after suspecting a guard went quiet.
  gate         none. Report-only, matching docker-hygiene.sh. It never blocks a
               merge or mutates state; a nonzero count is a prompt to restart
               the named session.
  defect       OBSERVED, two of them: (1) Claude Code caches hooks at session
               start and its settings.json watcher misses the ad daemon's
               atomic rename, so a guard that blocked at 10:00 can stop blocking
               at 13:00 in the same session; (2) anthropics/claude-code#84302 --
               a PreToolUse hook killed past its timeout makes the CLI ALLOW the
               gated tool, and dcg + git-guard both run on the inherited 600s
               default.
  delete-when  Claude Code ships a native hook-liveness signal, OR #84302 closes
               upstream and killed PreToolUse hooks fail CLOSED by default. At
               that point this and hooks/lib/seam-heartbeat.js go together.

WHY
---
Claude Code caches hooks at session start and its settings.json watcher misses an
atomic-rename replacement (the ad daemon does this sub-second), so a guard that
blocked earlier can stop blocking later in the SAME session — documented in
HARNESS.md with "restart the session" as the only mitigation and no detector.
anthropics/claude-code#84302 (open) adds a second path: a KILLED PreToolUse hook
makes the CLI allow the gated tool, and dcg + git-guard.js both run on the
inherited 600s default timeout.

A dead seam cannot report itself — if hooks stop firing, no hook runs to say so.
So this observer lives outside the hook path and compares two independent
signals:

  beat  = hooks/lib/seam-heartbeat.js, written from inside every first-party
          PreToolUse guard process (loop-guard's matcher is `*`, so it beats on
          every tool call regardless of its opt-in state)
  truth = the session transcript, which Claude Code writes regardless of hook
          health

Tool calls continuing well past the last beat means the seam is not dispatching.

RELATIONSHIP TO dcg-contract
----------------------------
scripts/dcg-contract/ proves a guard's decision LOGIC is correct by
invoking it directly. It cannot see whether Claude Code is still invoking the
hook at all. These compose; neither substitutes for the other.

THREE STATES, DELIBERATELY
--------------------------
healthy / stale / unknown. "unknown" means recent tool activity with no beat file
at all, and is deliberately NOT a failure: right after deploy, sessions started
before the heartbeat shipped have the old module cached and legitimately cannot
beat. Collapsing unknown into healthy or stale manufactures confidence either way.

But "unknown" is not a permanent parking space. Once some OTHER beat proves the
heartbeat was already installed and running, a cwd whose tool calls span longer
than --unknown-escalate-sec with still no beat escalates to stale (reason
"never-beat"). Without that, a seam dead from its very first tool call sat in the
non-alarming bucket forever and never reached seam-flagged:N.

Usage:
  hook-seam-check.py [--window-min N] [--grace-sec N] [--json]
                     [--seam-dir DIR] [--projects-dir DIR]

  --window-min   only consider sessions with transcript activity this recent (default 30)
  --grace-sec    tool activity may lead the last beat by this much before flagging (default 300)
  --unknown-escalate-sec  activity span with NO beat before it escalates to stale (default 21600)
  --json         machine-readable output (also enabled by JSON=1)

Exit: 0 on a verified run (the trailing counters drive the weekly toast,
matching docker-hygiene.sh); 2 on usage error or an unavailable scan corpus.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from floor_assert import FloorNotMet, require_floor  # noqa: E402

# Only the tail of a transcript is read: we want the NEWEST tool call, and these
# files reach 100+ MB. A session whose last tool call is older than this many
# bytes of trailing records is reported as no-recent-activity rather than
# flagged — a deliberate false-negative bias, since the alternative is parsing
# gigabytes on every run.
TAIL_BYTES = 256 * 1024

# Unknowns are informational; enumerating dozens of scratch cwds would bury the
# stale lines that matter.
UNKNOWN_PREVIEW = 5

# Beat files for cwds not seen in this long are reaped. Comfortably longer than
# Claude Code's own ~30-day transcript retention, so a beat never disappears
# while the transcript it would be compared against still exists.
BEAT_MAX_AGE_DAYS = 45

# How long a cwd may show continuous tool activity with NO beat at all before it
# stops being "unknown" and becomes a real alarm. Only fires once some other beat
# proves the heartbeat was already installed and running (see scan()), so this is
# not a post-deploy grace period -- it is how long a genuinely dead-from-the-start
# seam is allowed to look benign. 6h is a judgment call: long enough that a normal
# working session never trips it, short enough that a dead seam surfaces the same
# day rather than never.
UNKNOWN_ESCALATE_SEC = 6 * 3600

# Orphaned `<key>.beat.<pid>.tmp` debris is reaped far sooner than a real beat:
# a live temp file is renamed within microseconds, so an hour is already generous.
TMP_MAX_AGE_SEC = 3600


def key_for(cwd: str) -> str:
    """Filename key for a cwd. MUST stay byte-identical to keyFor() in
    hooks/lib/seam-heartbeat.js -- two independently seeded 32-bit FNV-1a passes
    over UTF-16 code units, plus the length, as 20 lowercase hex chars.

    This is a deliberately duplicated contract, and the duplication is guarded:
    test_hook_seam_check.py drives the REAL JS writer and this reader end to end,
    so a change on either side fails rather than silently unpairing every beat.
    That test exists because this exact drift already happened once during
    development, when the JS side moved off sha1 and this side did not.
    """
    h1 = 0x811C9DC5
    h2 = 0x01000193
    # UTF-16 code units, because JS charCodeAt() and String.length count those,
    # not codepoints. Identical for ASCII paths; correct for the rest.
    raw = cwd.encode("utf-16-le")
    units = [int.from_bytes(raw[i : i + 2], "little") for i in range(0, len(raw), 2)]
    for c in units:
        h1 = ((h1 ^ c) * 0x01000193) & 0xFFFFFFFF
        h2 = ((h2 ^ c) * 0x85EBCA6B) & 0xFFFFFFFF
    return f"{h1:08x}{h2:08x}{len(units) & 0xFFFF:04x}"


def parse_iso(ts: str) -> float | None:
    """Epoch seconds from a transcript ISO-8601 Z timestamp, or None."""
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def newest_tool_call(path: Path) -> tuple[float | None, float | None, str | None]:
    """(newest tool_use epoch, oldest tool_use epoch, cwd) from a transcript tail.

    The oldest bound is what lets scan() distinguish "no beat yet, this session
    just started" from "no beat for hours while tool calls kept coming".

    The cwd is read off the records rather than reverse-engineered from the
    project directory name: Claude Code's cwd->directory mapping is version
    dependent (it folded `.` to `-` between Apr and Jul 2026) and guessing it
    silently unpairs every worktree session. Records carry the real cwd.
    """
    try:
        size = path.stat().st_size
        with path.open("rb") as fh:
            if size > TAIL_BYTES:
                fh.seek(size - TAIL_BYTES)
                fh.readline()  # discard the partial first line
            raw = fh.read()
    except OSError:
        return None, None, None

    newest: float | None = None
    oldest: float | None = None
    cwd: str | None = None
    # Walks the whole tail rather than breaking at the first hit: `oldest` needs
    # every tool_use in the window, and the tail is bounded at TAIL_BYTES so the
    # full pass is cheap.
    for line in reversed(raw.splitlines()):
        try:
            rec = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            continue
        # A line can parse into a non-dict (a bare string or number is valid
        # JSON), and .get() on that raises AttributeError. Guard before any
        # attribute access, or one odd record aborts the entire scan.
        if not isinstance(rec, dict):
            continue
        if cwd is None and isinstance(rec.get("cwd"), str) and rec["cwd"]:
            cwd = rec["cwd"]
        if rec.get("type") != "assistant":
            continue
        # dict.get(k, {}) substitutes the default only when the key is ABSENT.
        # A record carrying an explicit "message": null returns None, and the
        # chained .get() then raises. Check the value, not just the key.
        msg = rec.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if not isinstance(content, list):
            continue
        if not any(isinstance(b, dict) and b.get("type") == "tool_use" for b in content):
            continue
        found = parse_iso(rec.get("timestamp", ""))
        if found is None:
            continue
        if newest is None or found > newest:
            newest = found
        if oldest is None or found < oldest:
            oldest = found
    return newest, oldest, cwd


def read_beats(seam_dir: Path) -> dict[str, float]:
    """cwd -> last beat time.

    The filename is an opaque sha1 and carries no meaning; the real key is the
    literal cwd written inside. The heartbeat writes temp-then-rename, so a
    reader never observes a partial body — but a body that fails to parse is
    skipped rather than trusted, and mtime (not the embedded ts) remains the
    time source, since mtime cannot disagree with the filesystem.
    """
    beats: dict[str, float] = {}
    try:
        entries = list(seam_dir.iterdir())
    except OSError:
        return beats
    for entry in entries:
        if entry.suffix != ".beat":
            continue
        try:
            mtime = entry.stat().st_mtime
            rec = json.loads(entry.read_text(encoding="utf8"))
        except (OSError, ValueError):
            continue
        if not isinstance(rec, dict):
            continue
        cwd = rec.get("cwd")
        if not isinstance(cwd, str) or not cwd:
            continue
        # The filename must be the hash of the cwd the body claims. Without this
        # check a single arbitrary file write marks ANY project healthy, because
        # the body was trusted verbatim -- a forged all-clear on a monitoring
        # control. This raises the bar to "can compute sha1", not to "cannot
        # forge": a per-machine secret would be needed for that, and is overkill
        # for a single-UID box where an attacker with write access already has
        # the user's full capability.
        if entry.stem != key_for(cwd):
            continue
        beats[cwd] = max(beats.get(cwd, 0.0), mtime)
    return beats


def prune_beats(seam_dir: Path, max_age_days: int) -> int:
    """Delete beat files untouched for max_age_days; return how many went.

    Slugs are derived from cwd, and this harness's cwds are largely ephemeral —
    every worktree created by wt-new.sh and every scratch repo in a test run
    mints a new key that is never written again. Without pruning the directory
    grows without bound. Constant space per LIVE project only holds if the dead
    ones are reaped, and the checker already walks this directory, so it is the
    natural place to do it.
    """
    cutoff = time.time() - max_age_days * 86400
    # Orphaned temp files need their own, much shorter threshold. The writer
    # creates `<key>.beat.<pid>.tmp` and renames within microseconds, so anything
    # older is debris from a guard killed mid-write. They also need their own
    # MATCH: Path.suffix on that name is ".tmp", not ".beat", so the beat filter
    # below never saw them and nothing in the script ever reclaimed them --
    # exactly the unbounded growth this prune exists to prevent.
    tmp_cutoff = time.time() - TMP_MAX_AGE_SEC
    removed = 0
    try:
        entries = list(seam_dir.iterdir())
    except OSError:
        return 0
    for entry in entries:
        if entry.suffix == ".tmp":
            entry_cutoff = tmp_cutoff
        elif entry.suffix == ".beat":
            entry_cutoff = cutoff
        else:
            continue
        try:
            if entry.stat().st_mtime < entry_cutoff:
                entry.unlink()
                removed += 1
        except OSError:
            continue  # raced with a live guard, or not ours to remove
    return removed


def scan(
    projects_dir: Path,
    seam_dir: Path,
    window_min: int,
    grace_sec: int,
    unknown_escalate_sec: int = UNKNOWN_ESCALATE_SEC,
) -> dict:
    now = time.time()
    cutoff = now - window_min * 60
    beats = read_beats(seam_dir)
    deployed = seam_dir.exists()

    stale: list[dict] = []
    unknown: list[dict] = []
    healthy = 0

    try:
        slugs = [d for d in projects_dir.iterdir() if d.is_dir()]
    except OSError:
        slugs = []
    session_files_examined = 0

    # cwd -> newest tool call across every recent transcript for that cwd. Two
    # project directories can legitimately describe the same cwd (Claude Code
    # renamed its slug scheme mid-2026 and old dirs survive), so the cwd is the
    # unit of comparison, not the directory.
    activity: dict[str, float] = {}
    # cwd -> EARLIEST in-window tool call. Needed to tell "no beat yet, session
    # only just started" from "no beat for hours while tool calls kept coming".
    # Without it every never-beat cwd looks like the benign first case forever.
    earliest: dict[str, float] = {}
    for slug_dir in slugs:
        # Non-recursive on purpose: subagent transcripts live in a <uuid>/
        # sidecar and share the parent's seam, so counting them would double up.
        try:
            corpus = [p for p in slug_dir.glob("*.jsonl") if p.is_file()]
            session_files_examined += len(corpus)
            transcripts = [p for p in corpus if p.stat().st_mtime >= cutoff]
        except OSError:
            continue
        for transcript in transcripts:
            last_tool, first_tool, cwd = newest_tool_call(transcript)
            if last_tool is None or last_tool < cutoff or not cwd:
                continue  # no recent tool call, or no cwd to key on — proves nothing
            activity[cwd] = max(activity.get(cwd, 0.0), last_tool)
            in_window = max(first_tool or last_tool, cutoff)
            earliest[cwd] = min(earliest.get(cwd, in_window), in_window)

    # Lower bound on "the heartbeat was already installed and beating". Any beat
    # file, for any project, proves the mechanism was live at that time. Used to
    # decide whether a MISSING beat is meaningful: absence before the heartbeat
    # shipped is expected, absence after it was demonstrably running is not.
    # Conservative by construction — pruning only moves this bound forward, which
    # can only suppress escalations, never invent one.
    heartbeat_live_since = min(beats.values()) if beats else None

    for cwd, last_tool in activity.items():
        beat = beats.get(cwd)
        record = {
            "cwd": cwd,
            "last_tool_call": datetime.fromtimestamp(last_tool, timezone.utc).isoformat(),
            "last_beat": (
                datetime.fromtimestamp(beat, timezone.utc).isoformat() if beat else None
            ),
            "lag_sec": round(last_tool - beat, 1) if beat else None,
            "reason": "beat-stale" if beat else "never-beat",
        }
        if beat is not None:
            if last_tool > beat + grace_sec:
                stale.append(record)
            else:
                healthy += 1
            continue
        # No beat at all. Escalate only when the heartbeat is known to have been
        # running for the whole span of this cwd's activity — otherwise a session
        # that predates the install, or one that has only just started, would
        # alarm. Without this branch a seam that never beat ONCE sat in the
        # non-alarming bucket forever and never reached seam-flagged:N.
        began = earliest.get(cwd, last_tool)
        if (
            heartbeat_live_since is not None
            and began > heartbeat_live_since
            and (last_tool - began) > unknown_escalate_sec
        ):
            record["lag_sec"] = round(last_tool - began, 1)
            stale.append(record)
        else:
            unknown.append(record)

    stale.sort(key=lambda r: r["lag_sec"] or 0, reverse=True)
    return {
        "deployed": deployed,
        "healthy": healthy,
        "stale": stale,
        "unknown": unknown,
        "project_dirs_examined": len(slugs),
        "session_files_examined": session_files_examined,
        "window_min": window_min,
        "grace_sec": grace_sec,
    }


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--window-min", type=int, default=30)
    ap.add_argument("--grace-sec", type=int, default=300)
    ap.add_argument("--json", action="store_true", default=os.environ.get("JSON") == "1")
    ap.add_argument("--seam-dir", default=os.environ.get("CLAUDE_SEAM_DIR"))
    ap.add_argument("--projects-dir", default=None)
    ap.add_argument("--prune-days", type=int, default=BEAT_MAX_AGE_DAYS)
    ap.add_argument("--no-prune", action="store_true")
    ap.add_argument("--unknown-escalate-sec", type=int, default=UNKNOWN_ESCALATE_SEC)
    args = ap.parse_args()

    home = Path.home()
    seam_dir = Path(args.seam_dir) if args.seam_dir else home / ".claude" / "run" / "hook-seam"
    projects_dir = (
        Path(args.projects_dir) if args.projects_dir else home / ".claude" / "projects"
    )

    # Scan BEFORE pruning. The first cut did the reverse, reasoning that a
    # reaped beat belongs to a dead cwd and so could not turn a healthy result
    # stale. That reasoning has a hole, and it is the worst case: a seam that
    # died and never recovered has a FROZEN beat, so once that beat ages past
    # the prune threshold it is deleted, and the cwd -- which still has live
    # tool calls -- silently drops from `stale` to the non-alarming `unknown`.
    # The one failure the detector most needs to report is the one whose alarm
    # disappeared. Scanning first is safe because BEAT_MAX_AGE_DAYS is far
    # larger than any realistic window/grace, so nothing prunable was healthy.
    result = scan(
        projects_dir,
        seam_dir,
        args.window_min,
        args.grace_sec,
        args.unknown_escalate_sec,
    )
    pruned = 0 if args.no_prune else prune_beats(seam_dir, args.prune_days)
    result["pruned"] = pruned
    flagged = len(result["stale"])
    try:
        require_floor(
            min(result["project_dirs_examined"], result["session_files_examined"]),
            1,
            "hook-seam-check project/session corpus",
        )
        unverified_reason = None
    except FloorNotMet as error:
        unverified_reason = str(error)
    result["unverified"] = int(unverified_reason is not None)
    result["unverified_reason"] = unverified_reason

    if args.json:
        # Must be the ONLY thing on stdout: the trailing seam-flagged line below
        # is for the weekly's grep, and emitting it here made the payload
        # unparseable (caught the first time this was piped into json.load).
        # The count is carried as a field instead.
        result["flagged"] = flagged
        print(json.dumps(result, indent=2))
        return 2 if unverified_reason else 0
    if unverified_reason:
        print(unverified_reason)
    if not result["deployed"]:
        print("hook-seam-check: heartbeat not deployed yet (no seam dir) — nothing to check.")
    elif not unverified_reason:
        print(
            f"hook-seam-check: {result['healthy']} healthy, {flagged} stale, "
            f"{len(result['unknown'])} unknown "
            f"(window {args.window_min}m, grace {args.grace_sec}s)"
        )
        for rec in result["stale"]:
            print(
                f"  STALE  {rec['cwd']}: tool calls continued {rec['lag_sec']}s past the "
                f"last guard beat — the PreToolUse seam may have stopped firing. "
                f"Restart that session to re-arm the guards."
            )
        # Unknowns are not failures and are dominated by short-lived scratch and
        # worktree sessions, so they are summarised rather than enumerated —
        # printing every one buries the STALE lines that actually matter.
        if result["unknown"]:
            shown = result["unknown"][:UNKNOWN_PREVIEW]
            print(
                f"  unknown ({len(result['unknown'])}): recent tool calls but no beat file. "
                f"Expected for sessions started before the heartbeat shipped, and for "
                f"short-lived scratch/worktree sessions. Investigate only if a long-lived "
                f"project persists here."
            )
            for rec in shown:
                print(f"    - {rec['cwd']}")
            if len(result["unknown"]) > len(shown):
                print(f"    - ... and {len(result['unknown']) - len(shown)} more")
        if flagged:
            print(
                "  NOTE: concurrent sessions in the SAME project can refresh each other's beat, "
                "so a stale result is a strong signal but a healthy one is not a guarantee."
            )

    # Trailing machine-readable line for harness-weekly's toast, matching
    # docker-hygiene.sh's `docker-flagged:N` convention.
    print(f"seam-flagged:{flagged}")
    print(f"seam-unverified:{result['unverified']}")
    return 2 if unverified_reason else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
