#!/usr/bin/env python3
"""Contract tests for pro-lane-report.py: counts from a synthetic pro-gate
ledger, the headroom line, floor+trend flag gating, remote-coalesced repo
names, the toast counter, the dead-feed WARN, and the report-never-actor
invariant (PRO_GATE_HOME byte-identical after a run)."""

import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "pro-lane-report.py"
NOW = dt.datetime(2026, 9, 2, 12, 0, 0, tzinfo=dt.timezone.utc)


def ts(days_ago, hours=0):
    when = NOW - dt.timedelta(days=days_ago, hours=hours)
    # Ledger offsets have no colon: 2026-09-01T23:51:17-0400.
    return when.astimezone(dt.timezone(dt.timedelta(hours=-4))).strftime("%Y-%m-%dT%H:%M:%S%z")


def row(**kw):
    base = {"ts": ts(1), "kind": "fresh", "outcome": "clean", "pre_slot_secs": 0,
            "post_slot_secs": 0, "conc": 4, "ceiling": 4, "repo": "/home/user/SITES/announce-bot",
            "model": "the frontier OpenAI Pro reasoning model (web-UI-only, via the oracle bridge)"}
    base.update(kw)
    return json.dumps(base)


def snapshot(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            st = os.stat(path)
            out.append((os.path.relpath(path, root), st.st_size, int(st.st_mtime)))
    return out


class ProLaneReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / "pro-gate-home"
        (self.home / "in-progress").mkdir(parents=True)
        created = int((NOW - dt.timedelta(minutes=12)).timestamp())
        (self.home / "in-progress" / "pg-run-acme-org-announce-bot-9-1-1").write_text(
            "acme-org-announce-bot-9\t/tmp/out.md\t%d\t0\t1\t\t%d\tgenerating\n" % (created, created))
        (self.home / "in-progress.lock").write_text("")
        lines = [
            row(pre_slot_secs=600, post_slot_secs=900),
            row(ts=ts(2), outcome="lock-timeout", pre_slot_secs=2400, post_slot_secs=0),
            row(ts=ts(1, 3), pre_slot_secs=60, post_slot_secs=700,
                repo="/home/user/hov-stack/.claude/worktrees/read-guard-tail"),
            row(kind="harvest", outcome="in-progress", pre_slot_secs=0, post_slot_secs=1200, repo="",
                marker="pg-run-acme-org-announce-bot-2307-1-1"),
            row(ts=ts(30), pre_slot_secs=5000, post_slot_secs=5000),
            "this is not json",
        ]
        (self.home / "ledger.jsonl").write_text("\n".join(lines) + "\n")
        # Remote resolution is exercised by its own test; the synthetic paths
        # here do not exist, so the heuristic fallback is what gets tested.
        self.env = dict(os.environ, PRO_GATE_HOME=str(self.home), PRO_LANE_NOW=NOW.isoformat(),
                        PRO_LANE_ASYNC_ROOT=str(Path(self.tmp.name) / "no-such-acme-fleet"))
        for key in ("PRO_GATE_MAX_CONCURRENCY", "PRO_LANE_LOCK_TIMEOUT_FLOOR", "PRO_LANE_WOW_RATIO",
                    "PRO_LANE_STALE_RESERVATION_HOURS", "PRO_LANE_RESOLVE_REMOTES", "PRO_LANE_ENGINE_STATUS"):
            self.env.pop(key, None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args):
        proc = subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env,
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout

    def append(self, *lines):
        with open(self.home / "ledger.jsonl", "a") as fh:
            for line in lines:
                fh.write(line + "\n")

    def test_counts_from_synthetic_ledger_and_no_writes(self):
        before = snapshot(self.home)
        out = self.run_script()
        self.assertEqual(snapshot(self.home), before, "report must never write under PRO_GATE_HOME")
        self.assertIn("fresh runs: 3 (harvests: 1; ledger rows in window: 4; malformed lines: 1)", out)
        self.assertIn("lock-timeouts: 1", out)
        self.assertIn("per repo: announce-bot: 2, hov-stack: 1", out)
        self.assertIn("queue wait (pre-slot): p50 10m, p90 40m, max 40m, sum 51m", out)
        self.assertIn("prior 7-day window: fresh 0, lock-timeouts 0, queue wait p50 0m", out)
        self.assertIn("sync-lane headroom: 3 of 4 slot(s) free — 1 live reservation(s), oldest 12m", out)
        self.assertIn("async lane: fleet_status.py not found", out)
        self.assertNotIn("[WARN]", out, "one lock-timeout is under the floor; three runs is under the slot-bound floor")
        self.assertTrue(out.rstrip().endswith("pro-lane-flagged:0"), out)
        self.assertNotIn("\nWARN ", out)

    def test_async_lane_unset_is_explicitly_skipped(self):
        self.env.pop("PRO_LANE_ASYNC_ROOT", None)
        out = self.run_script()
        self.assertIn("async lane: PRO_LANE_ASYNC_ROOT not configured (skipped)", out)
        self.assertNotIn("fleet_status.py not found", out)

    def test_failed_reason_breakdown_labels_pre_field_rows(self):
        # pro-gate#143: rows from before the field existed have no `reason` key at all and must
        # be labelled as such, never folded into the enum. New rows tally by their enum value.
        self.append(
            row(ts=ts(1, 1), outcome="failed", exit=6),
            row(ts=ts(1, 2), outcome="failed", exit=6, reason="salvage-empty", detail="no usable review after salvage"),
            row(ts=ts(1, 4), outcome="failed", exit=6, reason="salvage-empty", detail="no usable review after salvage"),
            row(ts=ts(1, 5), outcome="failed", exit=6, reason="refunded-unsubmitted", detail="submission never landed"),
        )
        out = self.run_script()
        # Count descending, then name ascending, so a tie never reorders the line between runs.
        self.assertIn("failed by reason: salvage-empty=2, (pre-v0.40, unclassified)=1, refunded-unsubmitted=1", out)

    def test_no_failed_rows_prints_no_reason_line(self):
        out = self.run_script()
        self.assertNotIn("failed by reason:", out)

    def test_lock_timeouts_flag_needs_floor_and_trend(self):
        # Six lock-timeouts this window (floor 5) against two in the prior window: rose 3x -> flag.
        # The prior window is already slot-bound (7 runs, p50 15m) so only the trend flag fires.
        self.append(*[row(ts=ts(3, i), outcome="lock-timeout", pre_slot_secs=2400) for i in range(5)])
        self.append(*[row(ts=ts(9, i), outcome="lock-timeout", pre_slot_secs=2400) for i in range(2)])
        self.append(*[row(ts=ts(10, i), pre_slot_secs=900, post_slot_secs=600) for i in range(5)])
        out = self.run_script()
        self.assertIn("prior 7-day window: fresh 7, lock-timeouts 2, queue wait p50 15m", out)
        self.assertIn("[WARN] pro-lane: 6 lock-timeout(s) this window vs 2 prior (floor 5, ratio 1.5)", out)
        self.assertTrue(out.rstrip().endswith("pro-lane-flagged:1"), out)

    def test_steady_state_lock_timeouts_do_not_nag(self):
        self.append(*[row(ts=ts(3, i), outcome="lock-timeout", pre_slot_secs=2400) for i in range(5)])
        self.append(*[row(ts=ts(9, i), outcome="lock-timeout", pre_slot_secs=2400) for i in range(6)])
        out = self.run_script()
        self.assertIn("lock-timeouts: 6", out)
        self.assertIn("prior 7-day window: fresh 6, lock-timeouts 6", out)
        self.assertNotIn("[WARN] pro-lane: 6 lock-timeout(s)", out)
        self.assertTrue(out.rstrip().endswith("pro-lane-flagged:0"), out)

    def test_newly_slot_bound_median_flags_once(self):
        # Five fresh runs this window with a 12m median, prior window fast -> newly slot-bound.
        self.append(*[row(ts=ts(3, i), pre_slot_secs=720, post_slot_secs=600) for i in range(4)])
        self.append(*[row(ts=ts(9, i), pre_slot_secs=30, post_slot_secs=600) for i in range(5)])
        out = self.run_script()
        self.assertIn("[WARN] pro-lane: median queue wait 12m (>= 10m) across 7 fresh runs, up from 0m prior", out)
        # Same shape in the prior window too (its median moves to 15m) -> no repeat flag.
        self.append(*[row(ts=ts(10, i), pre_slot_secs=900, post_slot_secs=600) for i in range(6)])
        out = self.run_script()
        self.assertIn("prior 7-day window: fresh 11, lock-timeouts 0, queue wait p50 15m", out)
        self.assertNotIn("median queue wait", out)

    def test_headroom_only_is_one_line_and_honors_env_ceiling(self):
        self.env["PRO_GATE_MAX_CONCURRENCY"] = "2"
        out = self.run_script("--headroom")
        self.assertEqual(out.count("\n"), 1)
        self.assertIn("sync-lane headroom: 1 of 2 slot(s) free — 1 live reservation(s)", out)

    def test_stale_reservation_is_flagged_and_counted(self):
        created = int((NOW - dt.timedelta(hours=10)).timestamp())
        (self.home / "in-progress" / "pg-run-acme-org-announce-bot-8-1-1").write_text(
            "acme-org-announce-bot-8\t/tmp/out8.md\t%d\t0\t2\t\t%d\tgenerating\n" % (created, created))
        out = self.run_script()
        self.assertIn("sync-lane headroom: 2 of 4 slot(s) free — 2 live reservation(s), oldest 600m", out)
        self.assertIn("[WARN] pro-lane: 1 reservation(s) older than 6h still in in-progress/", out)
        self.assertTrue(out.rstrip().endswith("pro-lane-flagged:1"), out)

    def fake_engine(self, body, exit_code=0):
        # A stand-in for oracle-review.sh: answers `--status --json` from a canned
        # document and writes nothing, so the report-never-actor snapshot still holds.
        engine = self.home / "oracle-review.sh"
        engine.write_text("#!/bin/sh\ncat <<'EOF'\n%s\nEOF\nexit %d\n" % (body, exit_code))
        engine.chmod(0o755)

    def add_stale_reservation(self, marker="pg-run-acme-org-announce-bot-8-1-1", state="generating"):
        created = int((NOW - dt.timedelta(hours=10)).timestamp())
        (self.home / "in-progress" / marker).write_text(
            "acme-org-announce-bot-8\t/tmp/out8.md\t%d\t0\t2\t\t%d\t%s\n" % (created, created, state))

    def test_engine_status_excludes_superseded_reservations_from_busy(self):
        # Two files in in-progress/; the engine says the 10h-old one is superseded and
        # holds no capacity. Busy must be 1, the stale WARN must not fire, and the
        # superseded count is reported so the lingering file is still visible.
        self.add_stale_reservation(state="superseded")
        self.fake_engine(json.dumps({"reservations": [
            {"marker": "pg-run-acme-org-announce-bot-9-1-1", "holds_capacity": True, "state": "generating-or-recoverable"},
            {"marker": "pg-run-acme-org-announce-bot-8-1-1", "holds_capacity": False, "state": "superseded-awaiting-optional-harvest"},
        ]}))
        before = snapshot(self.home)
        out = self.run_script()
        self.assertEqual(snapshot(self.home), before, "engine --status must be read-only")
        self.assertIn("sync-lane headroom: 3 of 4 slot(s) free — 1 live reservation(s) pin a slot, oldest 12m; "
                      "0 complete awaiting harvest; 1 superseded (optional harvest, no capacity) — per oracle-review.sh --status", out)
        self.assertNotIn("older than 6h", out)
        self.assertTrue(out.rstrip().endswith("pro-lane-flagged:0"), out)
        data = json.loads(self.run_script("--json"))
        self.assertEqual(data["headroom"]["busy"], 1)
        self.assertEqual(data["headroom"]["superseded"], 1)
        self.assertEqual(data["headroom"]["complete"], 0)
        self.assertEqual(data["headroom"]["past_ceiling"], 0)
        self.assertEqual(data["headroom"]["source"], "engine")

    def test_engine_null_and_quoted_holds_capacity(self):
        # null (unclassified) keeps the upper bound and pins; a quoted "false" from a
        # hand-built JSON still releases. Neither may flip the safe default silently.
        self.add_stale_reservation(state="superseded")
        self.fake_engine(json.dumps({"reservations": [
            {"marker": "pg-run-acme-org-announce-bot-9-1-1", "holds_capacity": None},
            {"marker": "pg-run-acme-org-announce-bot-8-1-1", "holds_capacity": "false", "state": "superseded-awaiting-optional-harvest"},
        ]}))
        out = self.run_script("--headroom")
        self.assertIn("3 of 4 slot(s) free — 1 live reservation(s) pin a slot, oldest 12m; 0 complete awaiting harvest; 1 superseded", out)

    def test_engine_complete_reservation_is_counted_and_flagged(self):
        # A finished review whose slot is already released is paid-for work waiting to be
        # collected: not busy, not superseded, and worth a WARN of its own.
        self.add_stale_reservation(state="complete")
        self.fake_engine(json.dumps({"reservations": [
            {"marker": "pg-run-acme-org-announce-bot-9-1-1", "holds_capacity": True},
            {"marker": "pg-run-acme-org-announce-bot-8-1-1", "holds_capacity": False, "state": "complete-awaiting-harvest"},
        ]}))
        out = self.run_script()
        self.assertIn("3 of 4 slot(s) free — 1 live reservation(s) pin a slot, oldest 12m; 1 complete awaiting harvest; 0 superseded", out)
        self.assertIn("[WARN] pro-lane: 1 completed review(s) awaiting harvest", out)
        self.assertNotIn("older than 6h", out)
        self.assertTrue(out.rstrip().endswith("pro-lane-flagged:1"), out)

    def test_engine_past_ceiling_reservation_is_counted_apart_and_flagged(self):
        # pro-gate#273: a review still generating past the engine's generation ceiling pins
        # no slot, so the 6h stale WARN no longer sees it. It is not superseded either (its
        # owner is gone), so it gets its own count and its own WARN.
        self.add_stale_reservation()
        self.fake_engine(json.dumps({"reservations": [
            {"marker": "pg-run-acme-org-announce-bot-9-1-1", "holds_capacity": True, "state": "generating-or-recoverable"},
            {"marker": "pg-run-acme-org-announce-bot-8-1-1", "holds_capacity": False, "state": "past-generation-ceiling",
             "past_generation_ceiling": True},
        ]}))
        out = self.run_script()
        self.assertIn("sync-lane headroom: 3 of 4 slot(s) free — 1 live reservation(s) pin a slot, oldest 12m; "
                      "0 complete awaiting harvest; 0 superseded (optional harvest, no capacity); "
                      "1 past the generation ceiling (owner gone, no capacity) — per oracle-review.sh --status", out)
        self.assertIn("[WARN] pro-lane: 1 reservation(s) still generating past the engine's generation ceiling", out)
        self.assertIn("--recover <marker>", out)
        self.assertNotIn("older than 6h", out)
        self.assertTrue(out.rstrip().endswith("pro-lane-flagged:1"), out)
        data = json.loads(self.run_script("--json"))
        self.assertEqual(data["headroom"]["busy"], 1)
        self.assertEqual(data["headroom"]["past_ceiling"], 1)
        self.assertEqual(data["headroom"]["superseded"], 0)
        self.assertEqual(data["headroom"]["complete"], 0)

    def test_engine_only_marker_counts_when_it_holds_capacity(self):
        # The engine indexed a reservation created after the directory listing: it exists now.
        self.fake_engine(json.dumps({"reservations": [
            {"marker": "pg-run-acme-org-announce-bot-9-1-1", "holds_capacity": True},
            {"marker": "pg-run-acme-org-announce-bot-7-1-1", "holds_capacity": True},
            {"marker": "pg-run-acme-org-announce-bot-6-1-1", "holds_capacity": False, "state": "superseded-awaiting-optional-harvest"},
        ]}))
        out = self.run_script("--headroom")
        self.assertIn("2 of 4 slot(s) free — 2 live reservation(s) pin a slot, oldest 12m; 0 complete awaiting harvest; 0 superseded", out)

    def test_engine_without_reservations_list_falls_back_without_crashing(self):
        for body in ('{"status": "degraded"}', '{"reservations": 3}', '{"reservations": {"a": 1}}', '[1, 2]'):
            self.fake_engine(body)
            out = self.run_script("--headroom")
            self.assertIn("3 of 4 slot(s) free — 1 live reservation(s), oldest 12m (upper bound", out)
            self.assertIn("engine --status returned no reservations list", out)

    def test_engine_status_stale_pinning_reservation_still_warns(self):
        self.add_stale_reservation()
        self.fake_engine(json.dumps({"reservations": [
            {"marker": "pg-run-acme-org-announce-bot-9-1-1", "holds_capacity": True},
            {"marker": "pg-run-acme-org-announce-bot-8-1-1", "holds_capacity": True},
        ]}))
        out = self.run_script()
        self.assertIn("2 of 4 slot(s) free — 2 live reservation(s) pin a slot, oldest 600m; 0 complete awaiting harvest; 0 superseded", out)
        self.assertIn("[WARN] pro-lane: 1 capacity-holding reservation(s) older than 6h", out)
        self.assertIn("--recover <marker>", out)
        self.assertTrue(out.rstrip().endswith("pro-lane-flagged:1"), out)

    def test_engine_unknown_marker_keeps_upper_bound(self):
        # A file the engine has not indexed yet still counts as pinning.
        self.fake_engine(json.dumps({"reservations": []}))
        out = self.run_script("--headroom")
        self.assertIn("3 of 4 slot(s) free — 1 live reservation(s) pin a slot", out)

    def test_engine_failure_or_garbage_falls_back_to_file_count(self):
        self.add_stale_reservation(state="superseded")
        self.fake_engine("not json at all")
        out = self.run_script()
        self.assertIn("sync-lane headroom: 2 of 4 slot(s) free — 2 live reservation(s), oldest 600m (upper bound", out)
        self.assertIn("engine --status emitted non-JSON)", out)
        self.assertIn("[WARN] pro-lane: 1 reservation(s) older than 6h still in in-progress/", out)
        self.fake_engine(json.dumps({"reservations": []}), exit_code=3)
        out = self.run_script("--headroom")
        self.assertIn("2 of 4 slot(s) free — 2 live reservation(s), oldest 600m (upper bound", out)
        self.assertIn("engine --status exit 3)", out)
        # In fallback the engine-only counts are unknown, not zero.
        data = json.loads(self.run_script("--json"))
        self.assertEqual(data["headroom"]["source"], "files")
        self.assertIsNone(data["headroom"]["superseded"])
        self.assertIsNone(data["headroom"]["complete"])
        self.assertIsNone(data["headroom"]["past_ceiling"])
        self.assertEqual(data["headroom"]["engine_note"], "exit 3")

    def test_engine_status_can_be_disabled_by_env(self):
        self.fake_engine(json.dumps({"reservations": [
            {"marker": "pg-run-acme-org-announce-bot-9-1-1", "holds_capacity": False}]}))
        self.env["PRO_LANE_ENGINE_STATUS"] = "0"
        out = self.run_script("--headroom")
        self.assertIn("3 of 4 slot(s) free — 1 live reservation(s), oldest 12m (upper bound", out)
        self.assertIn("engine --status disabled (PRO_LANE_ENGINE_STATUS=0)", out)

    def test_dead_feed_warns_unbracketed_and_exits_zero(self):
        os.remove(self.home / "ledger.jsonl")
        out = self.run_script()
        self.assertTrue(out.startswith("WARN pro-lane: ledger not found"), out)
        self.assertIn("sync-lane headroom:", out)
        self.assertTrue(out.rstrip().endswith("pro-lane-flagged:0"), out)

    def test_json_mode_exposes_summary_prior_and_headroom(self):
        data = json.loads(self.run_script("--json"))
        self.assertEqual(data["summary"]["fresh"], 3)
        self.assertEqual(data["summary"]["lock_timeouts"], 1)
        self.assertEqual(data["summary"]["prev"]["fresh"], 0)
        self.assertEqual(data["headroom"]["busy"], 1)
        self.assertEqual(data["headroom"]["ceiling"], 4)
        self.assertFalse(data["dead_feed"])

    def test_autoclone_repo_basename_falls_back_to_marker(self):
        self.append(row(repo="/home/user/.pro-review-daemon/clones/x/repo",
                        marker="pg-run-StartupBros-com-pro-gate-4-1-1"))
        out = self.run_script()
        self.assertIn("pro-gate: 1", out)
        self.assertNotIn("repo: 1", out)

    def test_two_checkouts_of_one_remote_count_as_one_repo(self):
        origin = "git@github.com:acme-org/announce-bot.git"
        paths = []
        for name in ("example-app", "announce-bot"):
            path = Path(self.tmp.name) / "SITES" / name
            path.mkdir(parents=True)
            subprocess.run(["git", "init", "-q", str(path)], check=True)
            subprocess.run(["git", "-C", str(path), "remote", "add", "origin", origin], check=True)
            paths.append(str(path))
        # Third row points at a swept worktree of the example-app checkout: resolve through the parent.
        self.append(row(repo=paths[0]), row(repo=paths[1]),
                    row(repo=paths[0] + "/.claude/worktrees/gone-since"))
        out = self.run_script()
        self.assertIn("per repo: announce-bot: 5, hov-stack: 1", out)
        self.assertNotIn("example-app", out)
        self.env["PRO_LANE_RESOLVE_REMOTES"] = "0"
        out = self.run_script()
        self.assertIn("example-app: 2", out, "heuristic fallback keys on the checkout directory name")

    def test_weekly_report_wiring_reads_and_gates_the_counter(self):
        # Mirrors harness-weekly-stash.test.sh g1-g3: a counter that is printed but
        # never read, or read but not OR-ed into the notify gate, would never toast.
        weekly = (SCRIPT.parent / "harness-weekly.sh").read_text()
        self.assertIn('python3 "$SCRIPTS/pro-lane-report.py" 2>&1', weekly)
        self.assertIn("PROLANE=$(grep -oE 'pro-lane-flagged:[0-9]+' \"$REPORT\" | head -1 | cut -d: -f2)", weekly)
        gate = [line for line in weekly.splitlines() if line.startswith("if [ \"${WARNS:-0}\" -gt 0 ]")]
        self.assertEqual(len(gate), 1)
        self.assertIn('[ "${PROLANE:-0}" -gt 0 ]', gate[0])
        self.assertIn("${PROLANE:-0} Pro-lane flag(s)", weekly)

    def test_weak_model_label_is_flagged(self):
        self.append(row(model="gpt-mini something"))
        out = self.run_script()
        self.assertIn("weak-model denylist", out)


if __name__ == "__main__":
    unittest.main()
