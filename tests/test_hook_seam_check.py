#!/usr/bin/env python3
"""Tests for scripts/hook-seam-check.py.

The load-bearing case is StaleSeamTests.test_planted_negative_tool_calls_after_beat:
it is the issue's declared planted negative. If the checker is ever gutted to
return healthy unconditionally, that test must fail. A green suite with it
removed, skipped, or passing vacuously is a failed run under the zero-run-green
rule.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path

CLAUDE = Path(__file__).resolve().parents[1]
CHECKER = CLAUDE / "scripts" / "hook-seam-check.py"
WEEKLY = CLAUDE / "scripts" / "harness-weekly.sh"

_spec = importlib.util.spec_from_file_location("hook_seam_check_module", CHECKER)
HSC = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(HSC)


def iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace("+00:00", "Z")


DEFAULT_CWD = "/home/user/SITES/repo"


def tool_call_record(epoch: float, cwd: str = DEFAULT_CWD) -> str:
    return json.dumps(
        {
            "type": "assistant",
            "timestamp": iso(epoch),
            "cwd": cwd,
            "message": {
                "id": "msg_1",
                "model": "claude-opus-5",
                "content": [{"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}],
            },
        }
    )


def text_record(epoch: float, cwd: str = DEFAULT_CWD) -> str:
    return json.dumps(
        {
            "type": "assistant",
            "timestamp": iso(epoch),
            "cwd": cwd,
            "message": {"id": "msg_2", "content": [{"type": "text", "text": "hello"}]},
        }
    )


class SeamCheckBase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.projects = root / "projects"
        self.seam = root / "seam"
        self.projects.mkdir()
        self.seam.mkdir()
        self.addCleanup(self._tmp.cleanup)

    def write_session(self, slug: str, records: list[str], mtime: float | None = None) -> Path:
        d = self.projects / slug
        d.mkdir(exist_ok=True, parents=True)
        p = d / "session-a.jsonl"
        p.write_text("\n".join(records) + "\n", encoding="utf8")
        if mtime is not None:
            os.utime(p, (mtime, mtime))
        return p

    def write_beat(self, cwd: str, mtime: float) -> Path:
        """Mirror the heartbeat: opaque hashed filename, real cwd in the body.

        Uses the production key_for() rather than reimplementing the hash. A
        hand-rolled copy here is what let the JS and Python sides drift apart
        unnoticed once already; CrossLanguageContractTests pins the real pair.
        """
        p = self.seam / f"{HSC.key_for(cwd)}.beat"
        p.write_text(
            json.dumps({"ts": int(mtime * 1000), "ppid": 1, "guard": "loop-guard", "cwd": cwd})
            + "\n"
        )
        os.utime(p, (mtime, mtime))
        return p

    def scan(self, window_min: int = 30, grace_sec: int = 300) -> dict:
        return HSC.scan(self.projects, self.seam, window_min, grace_sec)


class StaleSeamTests(SeamCheckBase):
    def test_planted_negative_tool_calls_after_beat(self):
        """PLANTED NEGATIVE. Tool calls kept happening well past the last guard
        beat — the seam is not dispatching and the checker must say so."""
        now = time.time()
        self.write_session("-home-user-repo", [tool_call_record(now - 10)], mtime=now - 10)
        self.write_beat(DEFAULT_CWD, now - 900)  # 890s of unguarded tool calls

        result = self.scan(grace_sec=300)

        self.assertEqual(len(result["stale"]), 1, "a dead seam must be flagged")
        self.assertEqual(result["stale"][0]["cwd"], DEFAULT_CWD)
        self.assertGreater(result["stale"][0]["lag_sec"], 300)
        self.assertEqual(result["healthy"], 0)

    def test_healthy_when_beat_keeps_up_with_tool_calls(self):
        now = time.time()
        self.write_session("-home-user-repo", [tool_call_record(now - 30)], mtime=now - 30)
        self.write_beat(DEFAULT_CWD, now - 25)

        result = self.scan()

        self.assertEqual(result["stale"], [])
        self.assertEqual(result["healthy"], 1)

    def test_lag_inside_grace_is_not_flagged(self):
        """A beat trailing tool activity by less than the grace window is normal
        jitter, not a dead seam — flagging it would train the alarm away."""
        now = time.time()
        self.write_session("-home-user-repo", [tool_call_record(now - 10)], mtime=now - 10)
        self.write_beat(DEFAULT_CWD, now - 100)

        result = self.scan(grace_sec=300)

        self.assertEqual(result["stale"], [])
        self.assertEqual(result["healthy"], 1)

    def test_stale_results_are_ranked_by_lag(self):
        now = time.time()
        self.write_session("-a", [tool_call_record(now - 5, "/cwd/a")], mtime=now - 5)
        self.write_beat("/cwd/a", now - 600)
        self.write_session("-b", [tool_call_record(now - 5, "/cwd/b")], mtime=now - 5)
        self.write_beat("/cwd/b", now - 3600)

        result = self.scan()

        self.assertEqual([r["cwd"] for r in result["stale"]], ["/cwd/b", "/cwd/a"])


class NeverBeatEscalationTests(SeamCheckBase):
    """Activity with NO beat must not park in `unknown` forever.

    Only `stale` feeds seam-flagged:N, so a seam dead from its very first tool
    call used to be permanently invisible.
    """

    def test_sustained_activity_with_no_beat_escalates_to_stale(self):
        now = time.time()
        # A beat for some OTHER cwd proves the heartbeat was installed and live
        # well before this session's activity began.
        self.write_beat("/some/other/project", now - 40 * 3600)
        self.write_session(
            "-dead-from-the-start",
            [tool_call_record(now - 30 * 3600, "/cwd/dead"), tool_call_record(now - 60, "/cwd/dead")],
            mtime=now - 60,
        )

        result = self.scan(window_min=10080)

        self.assertEqual(len(result["stale"]), 1, "a never-beating seam must escalate")
        self.assertEqual(result["stale"][0]["cwd"], "/cwd/dead")
        self.assertEqual(result["stale"][0]["reason"], "never-beat")

    def test_a_short_session_with_no_beat_stays_unknown(self):
        """A session that only just started has not proven anything yet."""
        now = time.time()
        self.write_beat("/some/other/project", now - 40 * 3600)
        self.write_session("-fresh", [tool_call_record(now - 60, "/cwd/fresh")], mtime=now - 60)

        result = self.scan(window_min=10080)

        self.assertEqual(result["stale"], [])
        self.assertEqual(len(result["unknown"]), 1)

    def test_no_escalation_before_the_heartbeat_was_ever_installed(self):
        """With zero beats anywhere, absence proves nothing -- this is the
        post-deploy state, and alarming on it would fire on every project."""
        now = time.time()
        self.write_session(
            "-predates-deploy",
            [tool_call_record(now - 30 * 3600, "/cwd/old"), tool_call_record(now - 60, "/cwd/old")],
            mtime=now - 60,
        )

        result = self.scan(window_min=10080)

        self.assertEqual(result["stale"], [])
        self.assertEqual(len(result["unknown"]), 1)

    def test_no_escalation_for_activity_predating_the_first_known_beat(self):
        """The session was already running before the heartbeat shipped."""
        now = time.time()
        self.write_beat("/some/other/project", now - 60)  # heartbeat only just installed
        self.write_session(
            "-straddles-deploy",
            [tool_call_record(now - 30 * 3600, "/cwd/old"), tool_call_record(now - 30, "/cwd/old")],
            mtime=now - 30,
        )

        result = self.scan(window_min=10080)

        self.assertEqual(result["stale"], [])
        self.assertEqual(len(result["unknown"]), 1)


class ForgedBeatTests(SeamCheckBase):
    def test_a_beat_whose_filename_does_not_match_its_cwd_is_ignored(self):
        """Without this the body is trusted verbatim, so one arbitrary file write
        marks any project healthy -- a forged all-clear on a safety control."""
        now = time.time()
        forged = self.seam / "0000000000000000dead.beat"
        forged.write_text(json.dumps({"ts": 1, "ppid": 1, "cwd": DEFAULT_CWD}) + "\n")
        os.utime(forged, (now - 5, now - 5))
        self.write_session("-repo", [tool_call_record(now - 10)], mtime=now - 10)

        result = self.scan()

        self.assertEqual(result["healthy"], 0, "a forged beat must not confer health")
        self.assertEqual(HSC.read_beats(self.seam), {})

    def test_a_genuine_beat_is_still_accepted(self):
        now = time.time()
        self.write_beat(DEFAULT_CWD, now - 5)
        self.write_session("-repo", [tool_call_record(now - 10)], mtime=now - 10)

        self.assertEqual(self.scan()["healthy"], 1)


class MalformedRecordTests(SeamCheckBase):
    def test_a_record_that_parses_to_a_non_dict_does_not_crash_the_scan(self):
        now = time.time()
        d = self.projects / "-repo"
        d.mkdir()
        p = d / "session-a.jsonl"
        p.write_text('"just a string"\n42\n' + tool_call_record(now - 10) + "\n", encoding="utf8")
        os.utime(p, (now - 10, now - 10))
        self.write_beat(DEFAULT_CWD, now - 900)

        result = self.scan()

        self.assertEqual(len(result["stale"]), 1)

    def test_an_assistant_record_with_null_message_does_not_crash_the_scan(self):
        """dict.get('message', {}) returns None, not {}, when the key exists with
        a null value -- the chained .get() then raised AttributeError and aborted
        the entire run, which harness-weekly read as a clean zero."""
        now = time.time()
        d = self.projects / "-repo"
        d.mkdir()
        p = d / "session-a.jsonl"
        null_msg = json.dumps(
            {"type": "assistant", "timestamp": iso(now - 20), "cwd": DEFAULT_CWD, "message": None}
        )
        p.write_text(null_msg + "\n" + tool_call_record(now - 10) + "\n", encoding="utf8")
        os.utime(p, (now - 10, now - 10))
        self.write_beat(DEFAULT_CWD, now - 900)

        result = self.scan()

        self.assertEqual(len(result["stale"]), 1)


class CrossLanguageContractTests(SeamCheckBase):
    """The JS writer and the Python reader agree on the beat format.

    Every other test in this file builds beats with a Python helper, so the two
    real implementations never meet. That gap is not theoretical: when the JS
    side moved off sha1 to an inline hash, the Python reader kept computing sha1
    and would have rejected every beat in production while the whole suite
    stayed green. These tests drive the ACTUAL node writer.
    """

    HEARTBEAT = (
        Path(__file__).resolve().parents[1] / "hooks" / "lib" / "seam-heartbeat.js"
    )

    def _node_beat(self, cwd: str) -> subprocess.CompletedProcess:
        script = (
            f"const hb=require({json.dumps(str(self.HEARTBEAT))});"
            f"process.exitCode = hb.beat({json.dumps(cwd)}) ? 0 : 1;"
        )
        return subprocess.run(
            ["node", "-e", script],
            capture_output=True,
            text=True,
            env={**os.environ, "CLAUDE_SEAM_DIR": str(self.seam)},
            check=True,
        )

    def test_key_for_matches_the_js_implementation_exactly(self):
        for cwd in (
            "/home/user/hov-stack",
            "/home/user/SITES/acme-agency/.claude/worktrees/acme-agency-plan",
            "/a/b",
            "/a-b",
            "/tmp/sp ace/and+plus",
        ):
            out = subprocess.run(
                [
                    "node",
                    "-e",
                    f"process.stdout.write(require({json.dumps(str(self.HEARTBEAT))})"
                    f".keyFor({json.dumps(cwd)}))",
                ],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
            self.assertEqual(out, HSC.key_for(cwd), f"key mismatch for {cwd}")

    def test_real_js_writer_pairs_with_the_real_python_reader(self):
        cwd = "/home/user/SITES/acme-agency/.claude/worktrees/acme-agency-plan"
        self._node_beat(cwd)

        beats = HSC.read_beats(self.seam)

        self.assertIn(cwd, beats, "the reader must recognise a beat the writer produced")

    def test_a_real_js_beat_makes_a_live_session_read_healthy(self):
        cwd = "/home/user/SITES/repo-under-test"
        now = time.time()
        self.write_session("any-dir-name", [tool_call_record(now - 10, cwd)], mtime=now - 10)
        self._node_beat(cwd)

        result = self.scan()

        self.assertEqual(result["healthy"], 1)
        self.assertEqual(result["stale"], [])
        self.assertEqual(result["unknown"], [])

    def test_writer_leaves_no_temp_debris_the_pruner_cannot_see(self):
        self._node_beat("/home/user/hov-stack")
        leftovers = [p.name for p in self.seam.iterdir() if p.suffix == ".tmp"]
        self.assertEqual(leftovers, [])


class CwdKeyingTests(SeamCheckBase):
    def test_pairing_ignores_the_project_directory_name_entirely(self):
        """REGRESSION. The first cut derived Claude Code's project-slug from cwd
        by replacing path separators. Measured against the live corpus that is
        wrong: CC also folds `.` to `-` (current), while older dirs preserve `.`
        and `+` — so a worktree cwd `.../.claude/worktrees/x` produced
        `...-.claude-worktrees-x` against a real dir of `...--claude-worktrees-x`,
        silently unpairing EVERY worktree session. Pairing is on the cwd carried
        by the records, so the directory name can be anything at all."""
        now = time.time()
        cwd = "/home/user/SITES/acme-agency/.claude/worktrees/acme-agency-plan"
        self.write_session(
            "a-directory-name-matching-no-slug-scheme",
            [tool_call_record(now - 10, cwd)],
            mtime=now - 10,
        )
        self.write_beat(cwd, now - 900)

        result = self.scan(grace_sec=300)

        self.assertEqual(len(result["stale"]), 1, "must pair on cwd, not on directory name")
        self.assertEqual(result["stale"][0]["cwd"], cwd)

    def test_two_directories_for_one_cwd_are_merged(self):
        """CC renamed its slug scheme mid-2026, so one cwd can own an old dir and
        a new one. The newest tool call across both is what counts."""
        now = time.time()
        cwd = "/home/user/SITES/acme-health"
        self.write_session("-old-scheme-.claude-x", [tool_call_record(now - 4000, cwd)], mtime=now - 20)
        self.write_session("-new-scheme--claude-x", [tool_call_record(now - 10, cwd)], mtime=now - 10)
        self.write_beat(cwd, now - 5)

        result = self.scan()

        self.assertEqual(result["healthy"], 1)
        self.assertEqual(result["stale"], [])

    def test_paths_that_would_collide_under_slugging_stay_distinct(self):
        """`/a/b` and `/a-b` both slugify to `-a-b`; hashing keeps them apart."""
        now = time.time()
        self.write_session("d1", [tool_call_record(now - 10, "/a/b")], mtime=now - 10)
        self.write_session("d2", [tool_call_record(now - 10, "/a-b")], mtime=now - 10)
        self.write_beat("/a/b", now - 5)  # only ONE of the two is healthy

        result = self.scan()

        self.assertEqual(result["healthy"], 1)
        self.assertEqual([r["cwd"] for r in result["unknown"]], ["/a-b"])


class UnknownStateTests(SeamCheckBase):
    def test_activity_without_any_beat_is_unknown_not_stale(self):
        """Sessions that started before the heartbeat shipped have hooks cached
        from the old module and cannot beat. Counting that as a failure would
        alarm on every project immediately after deploy."""
        now = time.time()
        self.write_session("-home-user-repo", [tool_call_record(now - 10)], mtime=now - 10)

        result = self.scan()

        self.assertEqual(result["stale"], [])
        self.assertEqual(len(result["unknown"]), 1)
        self.assertIsNone(result["unknown"][0]["last_beat"])


class QuietSessionTests(SeamCheckBase):
    def test_no_recent_tool_calls_proves_nothing(self):
        """A recently-written transcript with no recent tool call gives the
        checker nothing to compare against — silence, not a verdict."""
        now = time.time()
        self.write_session("-home-user-repo", [text_record(now - 10)], mtime=now - 10)
        self.write_beat(DEFAULT_CWD, now - 9000)

        result = self.scan()

        self.assertEqual(result["stale"], [])
        self.assertEqual(result["unknown"], [])
        self.assertEqual(result["healthy"], 0)

    def test_transcript_outside_the_window_is_ignored(self):
        now = time.time()
        old = now - 7200
        self.write_session("-home-user-repo", [tool_call_record(old)], mtime=old)
        self.write_beat(DEFAULT_CWD, old - 9000)

        result = self.scan(window_min=30)

        self.assertEqual(result["stale"], [])
        self.assertEqual(result["healthy"], 0)

    def test_missing_seam_dir_reports_not_deployed(self):
        result = HSC.scan(self.projects, self.seam / "does-not-exist", 30, 300)
        self.assertFalse(result["deployed"])
        self.assertEqual(result["stale"], [])


class CliOutputTests(SeamCheckBase):
    def _run(self, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                sys.executable,
                str(CHECKER),
                "--seam-dir",
                str(self.seam),
                "--projects-dir",
                str(self.projects),
                *extra,
            ],
            capture_output=True,
            text=True,
            check=True,
        )

    def test_json_mode_stdout_is_pure_json(self):
        """REGRESSION: the trailing seam-flagged line was printed after the JSON
        payload, so piping --json into json.load() raised 'Extra data'. Caught
        the first time it was actually piped anywhere."""
        now = time.time()
        self.write_session("-home-user-repo", [tool_call_record(now - 10)], mtime=now - 10)
        self.write_beat(DEFAULT_CWD, now - 900)

        out = self._run("--json").stdout
        payload = json.loads(out)  # must not raise

        self.assertEqual(payload["flagged"], 1)
        self.assertEqual(len(payload["stale"]), 1)
        self.assertEqual(payload["unverified"], 0)

    def test_text_mode_emits_the_trailing_counter_for_the_weekly_toast(self):
        now = time.time()
        self.write_session("-home-user-repo", [tool_call_record(now - 10)], mtime=now - 10)
        self.write_beat(DEFAULT_CWD, now - 900)

        out = self._run().stdout

        self.assertIn("seam-flagged:1", out)
        self.assertIn("STALE", out)

    def test_unknown_list_is_capped_not_enumerated(self):
        """A weekly run sees dozens of ephemeral scratch slugs; enumerating them
        all buries the STALE lines that matter."""
        now = time.time()
        for i in range(12):
            self.write_session(f"-tmp-scratch-{i}", [tool_call_record(now - 10, f"/tmp/scratch-{i}")], mtime=now - 10)

        out = self._run().stdout

        self.assertIn("unknown (12)", out)
        self.assertIn("and 7 more", out)
        self.assertIn("seam-flagged:0", out)

    def test_empty_existing_roots_are_unverified_not_clean(self):
        """PLANTED NEGATIVE: this used to report three zero counts and exit 0."""
        result = subprocess.run(
            [sys.executable, str(CHECKER), "--seam-dir", str(self.seam),
             "--projects-dir", str(self.projects), "--no-prune"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("examined 0 item(s), expected at least 1", result.stdout)
        self.assertIn("seam-unverified:1", result.stdout)
        self.assertNotIn("0 healthy, 0 stale, 0 unknown", result.stdout)

    def test_populated_corpus_with_quiet_window_stays_verified(self):
        old = time.time() - 7200
        self.write_session("-quiet", [tool_call_record(old)], mtime=old)
        out = self._run("--no-prune").stdout
        self.assertIn("seam-flagged:0", out)
        self.assertIn("seam-unverified:0", out)
        self.assertNotIn("refusing to report clean", out)

    def test_missing_seam_dir_keeps_not_deployed_message(self):
        result = subprocess.run(
            [sys.executable, str(CHECKER), "--seam-dir", str(self.seam / "missing"),
             "--projects-dir", str(self.projects), "--no-prune"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("heartbeat not deployed yet (no seam dir)", result.stdout)
        self.assertIn("seam-unverified:1", result.stdout)


class WeeklyConsumerTests(unittest.TestCase):
    def test_unverified_counter_is_gate_wired(self):
        """PLANTED NEGATIVE: emitting a counter without consuming it is silent."""
        source = WEEKLY.read_text(encoding="utf-8")
        self.assertIn("seam-unverified:[0-9]+", source)
        self.assertIn('${SEAM_UNVERIFIED:-0}" -gt 0', source)
        self.assertIn("hook-seam scan(s) unverified", source)


class PruneTests(SeamCheckBase):
    def test_stale_beat_files_are_reaped(self):
        """Slugs come from cwds, and worktrees/scratch repos are ephemeral here,
        so without pruning the beat dir grows without bound."""
        now = time.time()
        dead = self.write_beat("/tmp/gone-forever", now - 90 * 86400)
        live = self.write_beat("/home/user/hov-stack", now - 60)

        removed = HSC.prune_beats(self.seam, 45)

        self.assertEqual(removed, 1)
        self.assertFalse(dead.exists())
        self.assertTrue(live.exists(), "live beat must survive")

    def test_orphaned_temp_files_are_reaped(self):
        """`<key>.beat.<pid>.tmp` has Path.suffix '.tmp', not '.beat', so the beat
        filter never saw it and a guard killed mid-write leaked a file forever."""
        now = time.time()
        orphan = self.seam / "abcd1234abcd12340001.beat.999.tmp"
        orphan.write_text("{}")
        os.utime(orphan, (now - 7200, now - 7200))
        fresh_tmp = self.seam / "abcd1234abcd12340002.beat.998.tmp"
        fresh_tmp.write_text("{}")

        removed = HSC.prune_beats(self.seam, 45)

        self.assertEqual(removed, 1)
        self.assertFalse(orphan.exists(), "an hour-old temp file is debris")
        self.assertTrue(fresh_tmp.exists(), "a temp file mid-rename must survive")

    def test_scan_runs_before_prune_so_a_long_dead_seam_still_flags(self):
        """The reverse order deleted the frozen beat of a permanently dead seam,
        silently demoting the worst case from stale to unknown.

        Drives the CLI, not scan()/prune_beats() directly: the defect lives in
        main()'s CALL ORDER, so a test that invokes the two functions itself
        passes no matter which order main() uses. A first version of this test
        did exactly that and survived the mutation that reintroduced the bug.
        """
        now = time.time()
        self.write_session("-repo", [tool_call_record(now - 10)], mtime=now - 10)
        beat = self.write_beat(DEFAULT_CWD, now - 60 * 86400)  # older than the 45d threshold

        out = subprocess.run(
            [
                sys.executable,
                str(CHECKER),
                "--seam-dir",
                str(self.seam),
                "--projects-dir",
                str(self.projects),
                "--json",
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        payload = json.loads(out)

        self.assertEqual(payload["flagged"], 1, "must be seen before it is reaped")
        self.assertEqual(payload["stale"][0]["cwd"], DEFAULT_CWD)
        self.assertEqual(payload["pruned"], 1, "and reaped in the same run")
        self.assertFalse(beat.exists())

    def test_prune_is_a_noop_on_a_missing_directory(self):
        self.assertEqual(HSC.prune_beats(self.seam / "nope", 45), 0)

    def test_prune_never_removes_a_live_beat_and_cannot_fake_health(self):
        """A reaped beat must never be able to turn a stale verdict healthy."""
        now = time.time()
        self.write_session("-home-user-repo", [tool_call_record(now - 10)], mtime=now - 10)
        self.write_beat(DEFAULT_CWD, now - 900)

        HSC.prune_beats(self.seam, 45)
        result = self.scan(grace_sec=300)

        self.assertEqual(len(result["stale"]), 1, "pruning must not mask a dead seam")


class TailParsingTests(SeamCheckBase):
    def test_newest_tool_call_wins_over_older_ones(self):
        now = time.time()
        self.write_session(
            "-home-user-repo",
            [tool_call_record(now - 5000), text_record(now - 20), tool_call_record(now - 10)],
            mtime=now - 10,
        )
        self.write_beat(DEFAULT_CWD, now - 5)

        result = self.scan()

        self.assertEqual(result["healthy"], 1, "must compare against the NEWEST tool call")

    def test_malformed_lines_do_not_crash_the_scan(self):
        now = time.time()
        d = self.projects / "-home-user-repo"
        d.mkdir()
        p = d / "session-a.jsonl"
        p.write_text("{not json at all\n" + tool_call_record(now - 10) + "\n", encoding="utf8")
        os.utime(p, (now - 10, now - 10))
        self.write_beat(DEFAULT_CWD, now - 900)

        result = self.scan()

        self.assertEqual(len(result["stale"]), 1)

    def test_subagent_sidecar_transcripts_are_not_double_counted(self):
        """Subagent transcripts live in a <uuid>/subagents/ sidecar and share the
        parent's seam; the glob is non-recursive so they must not appear."""
        now = time.time()
        self.write_session("-home-user-repo", [tool_call_record(now - 10)], mtime=now - 10)
        side = self.projects / "-home-user-repo" / "session-a" / "subagents"
        side.mkdir(parents=True)
        sp = side / "agent-x.jsonl"
        sp.write_text(tool_call_record(now - 1, DEFAULT_CWD) + "\n", encoding="utf8")
        os.utime(sp, (now - 1, now - 1))
        self.write_beat(DEFAULT_CWD, now - 5)

        result = self.scan()

        self.assertEqual(result["healthy"], 1)
        self.assertEqual(result["stale"], [])


if __name__ == "__main__":
    unittest.main()
