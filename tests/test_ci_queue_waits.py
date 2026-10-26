#!/usr/bin/env python3
"""Unit tests for scripts/ci-queue-waits.py.

Pins the two traps its docstring names, with synthetic API payloads shaped
like the real ones (these are arithmetic fixtures, not live proof):

  - a first-attempt run whose run-level fields say "no wait" but whose job
    waited ten minutes must report ten minutes, because the script must never
    read run_started_at;
  - a re-run (run_attempt 2) must be excluded from sampling entirely, so its
    jobs are never fetched;
  - --run-counts counts a re-run once, from its original attempt (dotfiles
    #1634): the listing's latest-attempt status, conclusion and jobs never
    decide it, and later attempts are reported apart, never counted;
  - a runs listing at GitHub's 1,000-row cap is refused, and --until bounds
    the created range;
  - skipped jobs and jobs missing a timestamp never count as a wait;
  - the percentile and threshold arithmetic on a known list: p50, p90, p99
    and max from one order statistic, ordered at every sample size;
  - sampling spans the window at every length, newest run included;
  - the run-level timing field is never even requested;
  - main's success path (--json, the default window) and its failure exit;
  - the gh boundary with subprocess.run replaced: the exact argv, one JSON
    object per line, the failure path, and the URL and jq shapes fetch_runs
    and fetch_jobs build. The live gh contract (compact one-line objects under
    --jq; the created qualifier filters by date) is not exercised here.
"""
from __future__ import annotations

import contextlib
import io
import json
import runpy
import subprocess
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parents[0]
SCRIPT = REPO_ROOT / "scripts" / "ci-queue-waits.py"


def load_module():
    return runpy.run_path(str(SCRIPT))


def job(label, created, started, completed=None, conclusion="success", name="j"):
    return {
        "name": name,
        "labels": [label],
        "created_at": created,
        "started_at": started,
        "completed_at": completed,
        "conclusion": conclusion,
    }


class FakeGh:
    """Stands in for gh_lines(path, jq): serves runs, per-run jobs and
    attempt-1 run objects, and records every jobs and attempt request so a
    test can assert a run was never fetched. `latest_jobs` overrides what a
    run's latest-attempt jobs path (`/runs/N/jobs`) serves, so a test can
    tell it apart from `/runs/N/attempts/1/jobs`."""

    def __init__(self, runs, jobs_by_run, attempts=None, latest_jobs=None):
        self.runs = runs
        self.jobs_by_run = jobs_by_run
        self.attempts = attempts or {}
        self.latest_jobs = latest_jobs or {}
        self.job_requests = []
        self.job_paths = []
        self.attempt_requests = []

    def __call__(self, path, jq):
        if "/actions/workflows/" in path:
            return list(self.runs)
        run_id = int(path.split("/actions/runs/")[1].split("/")[0])
        if "/attempts/" in path and "/jobs" not in path:
            self.attempt_requests.append(run_id)
            return [self.attempts[run_id]]
        self.job_requests.append(run_id)
        self.job_paths.append(path)
        if "/attempts/" not in path and run_id in self.latest_jobs:
            return list(self.latest_jobs[run_id])
        return list(self.jobs_by_run.get(run_id, []))


class JobWaitTests(unittest.TestCase):
    def setUp(self):
        self.m = load_module()

    def test_wait_is_started_minus_created_in_minutes(self):
        w = self.m["job_wait_minutes"](job("light", "2026-09-21T21:00:00Z", "2026-09-21T21:12:30Z"))
        self.assertAlmostEqual(w, 12.5)

    def test_skipped_job_never_queued(self):
        self.assertIsNone(self.m["job_wait_minutes"](job("light", "2026-09-21T21:00:00Z", "2026-09-21T21:12:30Z", conclusion="skipped")))

    def test_missing_timestamp_is_not_a_wait(self):
        self.assertIsNone(self.m["job_wait_minutes"](job("light", "2026-09-21T21:00:00Z", None)))
        self.assertIsNone(self.m["job_wait_minutes"](job("light", None, "2026-09-21T21:12:30Z")))
        self.assertIsNone(self.m["job_wait_minutes"](job("light", "not-a-timestamp", "2026-09-21T21:12:30Z")))

    def test_first_attempt_defaults_when_field_absent(self):
        self.assertTrue(self.m["is_first_attempt"]({"id": 1}))
        self.assertTrue(self.m["is_first_attempt"]({"id": 1, "run_attempt": 1}))
        self.assertFalse(self.m["is_first_attempt"]({"id": 1, "run_attempt": 2}))


class SummaryArithmeticTests(unittest.TestCase):
    def setUp(self):
        self.m = load_module()

    def test_percentiles_thresholds_and_pod_minutes(self):
        base = "2026-09-21T21:00:00Z"
        waits = [0, 1, 3, 6, 40]  # minutes
        jobs = [job("heavy", base, f"2026-09-21T21:{w:02d}:00Z", f"2026-09-21T21:{w + 10:02d}:00Z") for w in waits]
        jobs.append(job("heavy", base, "2026-09-21T21:05:00Z", conclusion="skipped"))  # excluded
        s = self.m["summarize"]({"heavy": jobs})["heavy"]
        self.assertEqual(s["jobs"], 5)
        self.assertEqual(s["p50"], 3.0)
        self.assertEqual(s["p90"], 6.0)  # index int(0.9 * 4) = 3 of [0, 1, 3, 6, 40]
        self.assertEqual(s["p99"], 6.0)  # index int(0.99 * 4) = 3: nearest rank below, no interpolation
        self.assertEqual(s["max"], 40.0)
        self.assertEqual(s["over_2"], 3)
        self.assertEqual(s["over_5"], 2)
        self.assertEqual(s["over_30"], 1)
        self.assertEqual(s["pod_minutes"], 50.0)  # five jobs, ten minutes each; the skipped one adds nothing

    def test_percentile_is_nearest_rank_below(self):
        p = self.m["percentile"]
        self.assertIsNone(p([], 0.9))
        self.assertEqual(p([7.0], 0.0), 7.0)
        self.assertEqual(p([7.0], 0.99), 7.0)
        four = [1.0, 2.0, 3.0, 4.0]
        self.assertEqual(p(four, 0.0), 1.0)
        self.assertEqual(p(four, 1.0), 4.0)
        self.assertEqual(p(four, 0.5), 2.0)  # int(0.5 * 3) = 1
        self.assertEqual(p(four, 0.9), 3.0)  # int(0.9 * 3) = 2
        self.assertEqual(p(four, 0.99), 3.0)  # int(0.99 * 3) = 2
        self.assertEqual(p([1.0, 5.0, 9.0], 0.5), 5.0)  # odd length: the median

    def test_percentiles_are_ordered_on_a_two_job_label(self):
        # p50 on its own index (s[len // 2]) reported 100.0 here while p90
        # was 1.0; every figure must come from the same order statistic.
        base = "2026-09-21T21:00:00Z"
        jobs = [job("heavy", base, "2026-09-21T21:01:00Z"), job("heavy", base, "2026-09-21T22:40:00Z")]
        s = self.m["summarize"]({"heavy": jobs})["heavy"]
        self.assertEqual((s["p50"], s["p90"], s["p99"], s["max"]), (1.0, 1.0, 1.0, 100.0))
        self.assertLessEqual(s["p50"], s["p90"])
        self.assertLessEqual(s["p90"], s["p99"])
        self.assertLessEqual(s["p99"], s["max"])

    def test_label_with_only_skipped_jobs_is_omitted(self):
        s = self.m["summarize"]({"light": [job("light", "2026-09-21T21:00:00Z", "2026-09-21T21:01:00Z", conclusion="skipped")]})
        self.assertEqual(s, {})

    def test_long_wait_buckets_use_the_job_start_hour(self):
        jobs = [
            job("heavy", "2026-09-21T21:50:00Z", "2026-09-21T22:03:00Z"),  # 13 min, lands in hour 22
            job("heavy", "2026-09-21T21:50:00Z", "2026-09-21T21:52:00Z"),  # 2 min, below threshold
        ]
        b = self.m["long_wait_buckets"](jobs)
        self.assertEqual(b["by_hour"], {22: 1})
        self.assertEqual(b["by_day"], {"2026-09-21": 1})

    def test_sample_evenly_spans_the_list(self):
        sample = self.m["sample_evenly"]
        items = list(range(100))
        self.assertEqual(sample(items, 10), [0, 11, 22, 33, 44, 55, 66, 77, 88, 99])
        self.assertEqual(sample(items, 0), items)
        self.assertEqual(sample(items, -3), items)
        self.assertEqual(sample([1, 2], 5), [1, 2])
        self.assertEqual(sample(items, 1), [99])  # a single pick is the newest run

    def test_sample_evenly_keeps_the_newest_runs_under_twice_the_sample(self):
        # A fixed stride of len // n is 1 whenever n < len < 2n, which kept
        # only the oldest n runs: at the default sample of 150, a window of
        # 151 to 299 runs silently lost its newest runs and any burst in them.
        sample = self.m["sample_evenly"]
        for length in (151, 250, 299, 300, 301, 1000):
            picked = sample(list(range(length)), 150)
            self.assertEqual(len(picked), 150, length)
            self.assertEqual(picked[0], 0, length)
            self.assertEqual(picked[-1], length - 1, length)
            self.assertEqual(picked, sorted(set(picked)), length)  # strictly increasing, no repeats


class CollectTrapTests(unittest.TestCase):
    """The two traps from the docstring, end to end through collect()."""

    def setUp(self):
        self.m = load_module()

    def test_job_wait_is_reported_even_when_run_level_fields_say_zero(self):
        # Trap 1: run_started_at == created_at on a first attempt, yet the job
        # sat in the queue ten minutes. The script must report ten.
        runs = [{"id": 11, "run_attempt": 1, "status": "completed", "created_at": "2026-09-21T21:00:00Z", "run_started_at": "2026-09-21T21:00:00Z"}]
        jobs = {11: [job("heavy", "2026-09-21T21:00:00Z", "2026-09-21T21:10:00Z", "2026-09-21T21:20:00Z")]}
        gh = FakeGh(runs, jobs)
        result = self.m["collect"]("o/r", "w.yml", "2026-09-09", 0, gh=gh)
        self.assertEqual(result["labels"]["heavy"]["p50"], 10.0)
        self.assertEqual(result["sampled_runs"], 1)

    def test_reruns_are_never_sampled(self):
        # Trap 1, other face: a re-run's day-long run-level "wait" must not
        # enter the measurement at all, so its jobs are never even fetched.
        runs = [
            {"id": 1, "run_attempt": 1, "status": "completed", "created_at": "2026-09-21T21:00:00Z"},
            {"id": 2, "run_attempt": 2, "status": "completed", "created_at": "2026-09-20T21:00:00Z"},
            {"id": 3, "run_attempt": 1, "status": "in_progress", "created_at": "2026-09-22T21:00:00Z"},
        ]
        jobs = {
            1: [job("light", "2026-09-21T21:00:00Z", "2026-09-21T21:00:30Z")],
            2: [job("light", "2026-09-20T21:00:00Z", "2026-09-21T21:00:00Z")],  # would read as a 24 h wait
            3: [job("light", "2026-09-22T21:00:00Z", "2026-09-22T21:00:10Z")],
        }
        gh = FakeGh(runs, jobs)
        result = self.m["collect"]("o/r", "w.yml", "2026-09-09", 0, gh=gh)
        self.assertEqual(gh.job_requests, [1])
        self.assertEqual(result["reruns_excluded"], 1)
        self.assertEqual(result["first_attempt_completed"], 1)
        self.assertEqual(result["labels"]["light"]["max"], 0.5)

    def test_dual_labelled_workflow_keeps_each_job_on_its_own_label(self):
        # Trap 2: heavy-job minutes must not be attributed to the light label.
        runs = [{"id": 5, "run_attempt": 1, "status": "completed", "created_at": "2026-09-21T21:00:00Z"}]
        jobs = {5: [
            job("light", "2026-09-21T21:00:00Z", "2026-09-21T21:00:06Z", "2026-09-21T21:01:06Z", name="gate"),
            job("heavy", "2026-09-21T21:00:00Z", "2026-09-21T21:08:00Z", "2026-09-21T21:28:00Z", name="suite"),
        ]}
        result = self.m["collect"]("o/r", "w.yml", "2026-09-09", 0, gh=FakeGh(runs, jobs))
        self.assertEqual(result["labels"]["light"]["pod_minutes"], 1.0)
        self.assertEqual(result["labels"]["heavy"]["pod_minutes"], 20.0)
        self.assertEqual(result["labels"]["heavy"]["over_5"], 1)
        self.assertEqual(result["labels"]["light"]["over_5"], 0)

    def test_render_names_every_label(self):
        runs = [{"id": 5, "run_attempt": 1, "status": "completed", "created_at": "2026-09-21T21:00:00Z"}]
        jobs = {5: [job("linux-x64-light", "2026-09-21T21:00:00Z", "2026-09-21T21:00:06Z", "2026-09-21T21:01:06Z")]}
        result = self.m["collect"]("o/r", "w.yml", "2026-09-09", 0, gh=FakeGh(runs, jobs))
        text = self.m["render"](result)
        self.assertIn("linux-x64-light", text)
        self.assertIn("1 sampled", text)


class FakeRunner:
    """Stands in for subprocess.run: records argv, returns a canned result."""

    def __init__(self, stdout="", stderr="", returncode=0):
        self.calls = []
        self.stdout, self.stderr, self.returncode = stdout, stderr, returncode

    def __call__(self, argv, **kwargs):
        self.calls.append(list(argv))
        return subprocess.CompletedProcess(argv, self.returncode, self.stdout, self.stderr)


class RoutingRunner(FakeRunner):
    """FakeRunner that serves one body for the workflow-runs path and another
    for a run's jobs path, so main() can run to completion."""

    def __init__(self, runs_stdout, jobs_stdout):
        super().__init__()
        self.runs_stdout, self.jobs_stdout = runs_stdout, jobs_stdout

    def __call__(self, argv, **kwargs):
        self.calls.append(list(argv))
        body = self.runs_stdout if "/actions/workflows/" in argv[3] else self.jobs_stdout
        return subprocess.CompletedProcess(argv, 0, body, "")


def recording_gh(seen):
    def gh(path, jq):
        seen.append((path, jq))
        return []
    return gh


class GhBoundaryTests(unittest.TestCase):
    """The gh api boundary: argv, parsing, failure, and the queries the two
    fetchers build. subprocess.run is replaced, so this pins the script's side
    of the contract, not GitHub's."""

    def setUp(self):
        self.m = load_module()

    def test_gh_lines_argv_and_one_object_per_line(self):
        runner = FakeRunner(stdout='{"id": 1}\n\n{"id": 2}\n')
        rows = self.m["gh_lines"]("repos/o/r/x", ".x[] | {id}", runner=runner)
        self.assertEqual(rows, [{"id": 1}, {"id": 2}])
        self.assertEqual(runner.calls, [["gh", "api", "--paginate", "repos/o/r/x", "--jq", ".x[] | {id}"]])

    def test_gh_lines_failure_names_the_path_and_stderr(self):
        runner = FakeRunner(stderr="HTTP 404: Not Found", returncode=1)
        with self.assertRaises(RuntimeError) as ctx:
            self.m["gh_lines"]("repos/o/r/x", ".x", runner=runner)
        self.assertIn("repos/o/r/x", str(ctx.exception))
        self.assertIn("404", str(ctx.exception))

    def test_fetch_runs_query_is_date_bounded_and_url_encoded(self):
        seen = []
        self.m["fetch_runs"]("acme-org/announce-bot", "workflow.yml", "2026-09-09", gh=recording_gh(seen))
        path, jq = seen[0]
        self.assertEqual(path, "repos/acme-org/announce-bot/actions/workflows/workflow.yml/runs?per_page=100&created=%3E%3D2026-09-09")
        self.assertNotIn(">", path)
        self.assertTrue(jq.startswith(".workflow_runs[] | {"))
        for field in ("id", "run_attempt", "status", "created_at"):
            self.assertIn(field, jq)
        self.assertNotIn("run_started_at", jq)  # trap 1: the run-level timing field is never requested

    def test_fetch_runs_until_bounds_the_created_range(self):
        seen = []
        self.m["fetch_runs"]("o/r", "w.yml", "2026-09-22", gh=recording_gh(seen), until="2026-10-06T08:15:22Z")
        self.assertEqual(seen[0][0], "repos/o/r/actions/workflows/w.yml/runs?per_page=100&created=2026-09-22..2026-10-06T08:15:22Z")

    def test_fetch_runs_refuses_a_listing_at_githubs_cap(self):
        # A created-filtered listing returns at most 1,000 runs (observed
        # 2026-10-14: total_count 1,257, 1,000 rows), so 1,000 rows means the
        # window may have been cut short without any error from GitHub.
        rows = [{"id": i} for i in range(1000)]
        with self.assertRaises(RuntimeError) as ctx:
            self.m["fetch_runs"]("o/r", "w.yml", "2026-09-22", gh=lambda path, jq: rows)
        self.assertIn("--until", str(ctx.exception))
        self.assertEqual(len(self.m["fetch_runs"]("o/r", "w.yml", "2026-09-22", gh=lambda path, jq: rows[:999])), 999)

    def test_fetch_attempt_and_attempt_jobs_paths(self):
        seen = []

        def gh(path, jq):
            seen.append((path, jq))
            return [{"id": 4242, "run_attempt": 1}]

        self.assertEqual(self.m["fetch_attempt"]("o/r", 4242, 1, gh=gh)["run_attempt"], 1)
        self.m["fetch_jobs"]("o/r", 4242, gh=gh, attempt=1)
        self.assertEqual(seen[0][0], "repos/o/r/actions/runs/4242/attempts/1")
        self.assertNotIn("run_started_at", seen[0][1])
        self.assertEqual(seen[1][0], "repos/o/r/actions/runs/4242/attempts/1/jobs?per_page=100")
        with self.assertRaises(RuntimeError):
            self.m["fetch_attempt"]("o/r", 4242, 1, gh=lambda path, jq: [])

    def test_fetch_jobs_query_names_the_run_and_the_job_fields(self):
        seen = []
        self.m["fetch_jobs"]("acme-org/announce-bot", 4242, gh=recording_gh(seen))
        path, jq = seen[0]
        self.assertEqual(path, "repos/acme-org/announce-bot/actions/runs/4242/jobs?per_page=100")
        self.assertTrue(jq.startswith(".jobs[] | {"))
        for field in ("labels", "created_at", "started_at", "completed_at", "conclusion"):
            self.assertIn(field, jq)

    def test_default_path_reaches_gh_and_main_reports_its_failure(self):
        # No gh override anywhere: collect() must go through gh_lines to
        # subprocess.run, and a gh failure must come back as main()'s exit 1.
        runner = FakeRunner(stderr="gh: not logged in", returncode=1)
        err = io.StringIO()
        with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stderr(err):
            rc = self.m["main"](["--target", "o/r:w.yml", "--since", "2026-09-09"])
        self.assertEqual(rc, 1)
        self.assertEqual(runner.calls[0][:3], ["gh", "api", "--paginate"])
        self.assertIn("not logged in", err.getvalue())

    def test_main_json_output_round_trips_on_the_default_path(self):
        runner = RoutingRunner(
            runs_stdout='{"id": 7, "run_attempt": 1, "status": "completed", "created_at": "2026-09-21T21:00:00Z"}\n',
            jobs_stdout='{"name": "gate", "labels": ["light"], "created_at": "2026-09-21T21:00:00Z", '
                        '"started_at": "2026-09-21T21:00:30Z", "completed_at": "2026-09-21T21:02:30Z", "conclusion": "success"}\n',
        )
        out = io.StringIO()
        with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stdout(out):
            rc = self.m["main"](["--target", "o/r:w.yml", "--since", "2026-09-09", "--json"])
        self.assertEqual(rc, 0)
        results = json.loads(out.getvalue())
        self.assertEqual(results[0]["target"], "o/r:w.yml")
        self.assertEqual(results[0]["sampled_runs"], 1)
        self.assertEqual(results[0]["labels"]["light"]["max"], 0.5)
        self.assertEqual(len(runner.calls), 2)  # one runs page, one jobs call

    def test_main_default_window_is_fourteen_days_and_renders_the_table(self):
        runner = RoutingRunner(runs_stdout="", jobs_stdout="")
        out = io.StringIO()
        day_before = datetime.now(timezone.utc).date()
        with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stdout(out):
            rc = self.m["main"](["--target", "o/r:w.yml"])
        day_after = datetime.now(timezone.utc).date()
        self.assertEqual(rc, 0)
        since = runner.calls[0][3].split("created=%3E%3D")[1]
        self.assertIn(since, {(d - timedelta(days=14)).isoformat() for d in (day_before, day_after)})
        self.assertIn(f"== o/r:w.yml since {since}: 0 runs", out.getvalue())


class TargetParsingTests(unittest.TestCase):
    def test_target_shape(self):
        m = load_module()
        self.assertEqual(m["parse_target"]("acme-org/announce-bot:workflow.yml"), ("acme-org/announce-bot", "workflow.yml"))
        with self.assertRaises(Exception):
            m["parse_target"]("acme-app:workflow.yml")
        with self.assertRaises(Exception):
            m["parse_target"]("acme-org/announce-bot")
        # Both halves land in an API path: a query or path separator in the
        # workflow part would reshape the request.
        for bad in ("acme-org/announce-bot:workflow.yml?per_page=1", "acme-org/announce-bot:a/b.yml", "Startup Bros/acme-app:w.yml"):
            with self.assertRaises(Exception):
                m["parse_target"](bad)
        self.assertEqual(m["parse_target"]("o/r:12345")[1], "12345")  # a numeric workflow id is a valid API operand


CORE = "Harness suites (core)"


def run(rid, branch, event="pull_request", conclusion="success", created="2026-09-21T10:00:00Z", **extra):
    return {"id": rid, "run_attempt": 1, "status": "completed", "event": event,
            "head_branch": branch, "conclusion": conclusion, "created_at": created, **extra}


def core(conclusion="success", name=CORE):
    return job("heavy", "2026-09-21T10:00:00Z", "2026-09-21T10:00:30Z", conclusion=conclusion, name=name)


def skipped_drafts(first_id, branch, n=2):
    """n draft-payload runs: core job skipped, only the aggregate ran."""
    runs = [run(first_id + i, branch, conclusion="failure") for i in range(n)]
    jobs = {r["id"]: [core("skipped"), core("failure", name="Harness suites (draft)")] for r in runs}
    return runs, jobs


class RunCountsTests(unittest.TestCase):
    """--run-counts, through collect_run_counts and render_run_counts. Fixtures
    are arithmetic, shaped like the API rows; the live payloads are not read."""

    def setUp(self):
        self.m = load_module()

    def collect(self, runs, jobs, attempts=None, latest_jobs=None):
        gh = FakeGh(runs, jobs, attempts, latest_jobs)
        result = self.m["collect_run_counts"]("o/r", "w.yml", "2026-09-09", CORE, gh=gh)
        return result, gh

    def test_ae13_skipped_core_jobs_are_scope_only_and_named_in_the_output(self):
        drafts, djobs = skipped_drafts(100, "feat-x")  # two skipped runs on the branch...
        runs = drafts + [run(1, "feat-x")]  # ...and one that ran the suites
        jobs = {**djobs, 1: [core()]}
        d2, dj2 = skipped_drafts(200, "feat-y")
        result, gh = self.collect(runs + d2, {**jobs, **dj2})
        self.assertEqual(result["suite_executing"], 1)
        self.assertEqual(result["scope_only"], 4)
        self.assertEqual(result["pr_branches"], 1)  # feat-y only has skipped runs, so it is no branch here
        self.assertEqual(len(gh.job_requests), 5)  # no sampling: every run's jobs were read
        self.assertEqual(result["original_attempt_completed"], 5)
        self.assertEqual(gh.attempt_requests, [])  # no re-runs, so no attempts call
        text = self.m["render_run_counts"](result)
        self.assertIn("since 2026-09-09", text)
        self.assertIn("5 runs whose original attempt completed", text)
        self.assertIn("1 suite-executing", text)
        self.assertIn("4 scope-only", text)

    def test_cancelled_counts_only_when_the_core_job_did_not_skip(self):
        runs = [
            run(1, "a", conclusion="cancelled", created="2026-09-21T10:00:00Z"),  # core ran: counts, week 39
            run(2, "a", conclusion="cancelled", created="2026-09-22T10:00:00Z"),  # core ran: counts, week 39
            run(3, "b", conclusion="cancelled", created="2026-09-28T10:00:00Z"),  # core ran: counts, week 40
            run(4, "c", conclusion="cancelled", created="2026-09-14T10:00:00Z"),  # core skipped: not counted
        ]
        jobs = {1: [core("cancelled")], 2: [core("success")], 3: [core("cancelled")], 4: [core("skipped")]}
        result, _ = self.collect(runs, jobs)
        self.assertEqual(result["cancelled_suite_runs"], 3)
        self.assertEqual(result["cancelled_by_week"], {"2026-W39": 2, "2026-W40": 1})
        self.assertEqual(result["scope_only"], 1)

    def test_per_branch_p50_p90_max_and_push_runs_kept_apart(self):
        # Branch counts 1, 2, 3, 5 -> sorted [1, 2, 3, 5]: p50 index 1 = 2,
        # p90 index int(0.9 * 3) = 2 = 3, max 5.
        runs, jobs, rid = [], {}, 0
        for branch, n in (("a", 1), ("b", 2), ("c", 3), ("d", 5)):
            for _ in range(n):
                rid += 1
                runs.append(run(rid, branch))
                jobs[rid] = [core()]
        for _ in range(2):  # push runs: counted apart, never in the per-branch figures
            rid += 1
            runs.append(run(rid, "main", event="push"))
            jobs[rid] = [core()]
        result, _ = self.collect(runs, jobs)
        self.assertEqual(result["pr_branches"], 4)
        self.assertEqual(result["pr_suite_runs"], 11)
        self.assertEqual(result["pr_runs_per_branch"], {"p50": 2, "p90": 3, "max": 5})
        self.assertEqual(result["push_suite_runs"], 2)
        self.assertEqual(result["suite_executing"], 13)
        text = self.m["render_run_counts"](result)
        self.assertIn("11 across 4 branches; per branch p50 2, p90 3, max 5", text)
        self.assertIn("push suite runs: 2", text)

    def test_run_without_a_core_job_is_scope_only(self):
        result, _ = self.collect([run(1, "a")], {1: [core(name="Some other job")]})
        self.assertEqual((result["suite_executing"], result["scope_only"]), (0, 1))
        result, _ = self.collect([run(2, "a")], {2: []})
        self.assertEqual((result["suite_executing"], result["scope_only"]), (0, 1))
        self.assertEqual(result["pr_runs_per_branch"], {"p50": None, "p90": None, "max": None})
        self.assertIn("p50 n/a", self.m["render_run_counts"](result))

    def test_a_rerun_counts_once_from_its_original_attempt(self):
        # dotfiles#1634. Run 2 was cancelled (its core job too) and re-run to
        # green, so the listing says attempt 2, success. Run 4's third attempt
        # is still running, but its first completed. Run 3's first attempt is
        # still running, so it stays outside the denominator.
        runs = [
            run(1, "a"),
            {**run(2, "a"), "run_attempt": 2, "conclusion": "success"},
            {**run(3, "a"), "status": "in_progress", "conclusion": None},
            {**run(4, "b"), "run_attempt": 3, "status": "in_progress", "conclusion": None},
        ]
        attempts = {2: {**run(2, "a"), "conclusion": "cancelled"}, 4: run(4, "b")}
        jobs = {1: [core()], 2: [core("cancelled")], 4: [core()]}
        result, gh = self.collect(runs, jobs, attempts=attempts)
        # Keys that predate the fix first, so a pre-fix run fails on a count.
        self.assertEqual(result["suite_executing"], 3)
        self.assertEqual(result["pr_suite_runs"], 3)
        self.assertEqual(result["pr_runs_per_branch"], {"p50": 1, "p90": 1, "max": 2})
        self.assertEqual(result["cancelled_suite_runs"], 1)  # the original attempt's, not the green re-run's
        self.assertEqual(result["cancelled_by_week"], {"2026-W39": 1})
        self.assertEqual(result["original_attempt_completed"], 3)
        self.assertEqual((result["rerun_runs"], result["extra_attempts"]), (2, 3))
        self.assertEqual(result["cancelled_suite_runs_rerun"], 1)
        self.assertEqual(gh.attempt_requests, [2, 4])  # the attempts endpoint is read only for re-runs
        self.assertEqual(gh.job_requests, [1, 2, 4])  # run 3 is never fetched
        for path in gh.job_paths:
            self.assertTrue(path.endswith("/attempts/1/jobs?per_page=100"), path)
        text = self.m["render_run_counts"](result)
        self.assertIn("2 re-run, 3 later attempts not counted", text)
        self.assertIn("cancelled suite runs: 1 (1 of them re-run;", text)

    def test_a_rerun_whose_original_skipped_the_core_job_stays_scope_only(self):
        # The original attempt ran only the scope job; the latest attempt's
        # jobs say the core job ran. The original decides.
        runs = [{**run(5, "c"), "run_attempt": 2, "conclusion": "success"}]
        attempts = {5: {**run(5, "c"), "conclusion": "failure"}}
        result, _ = self.collect(runs, {5: [core("skipped")]}, attempts=attempts, latest_jobs={5: [core()]})
        self.assertEqual((result["suite_executing"], result["scope_only"]), (0, 1))
        self.assertEqual((result["original_attempt_completed"], result["rerun_runs"]), (1, 1))


class ReadyOutcomesTests(unittest.TestCase):
    """--ready-outcomes, with gh stubbed per path."""

    LINE_A = "Ready outcomes: 2 ready flip(s), 1 red at ready, 1 red after a green local record."
    LINE_B = "Ready outcomes: 1 ready flip(s), 0 red at ready, 0 red after a green local record."
    LINE_0 = "Ready outcomes: 0 ready flip(s), 0 red at ready, 0 red after a green local record."

    def setUp(self):
        self.m = load_module()

    def gh(self, prs, comments):
        seen = []

        def gh(path, jq):
            seen.append(path)
            if "/pulls?" in path:
                return list(prs)
            return [{"body": b} for b in comments.get(int(path.split("/issues/")[1].split("/")[0]), [])]
        gh.seen = seen
        return gh

    def prs(self, *numbers, closed="2026-09-20T10:00:00Z"):
        return [{"number": n, "closed_at": closed} for n in numbers]

    def collect(self, prs, comments, max_prs=200):
        return self.m["collect_ready_outcomes"]("o/r", "2026-09-09", max_prs, gh=self.gh(prs, comments))

    def test_sums_rates_and_lists_comments_without_the_line(self):
        marker = self.m["OWNER_MARKER"]
        prs = self.prs(1, 2, 3, 4) + [{"number": 9, "closed_at": "2026-09-01T00:00:00Z"}]  # 9 closed before the window
        comments = {
            1: ["hello", f"{marker}\nmerged.\n{self.LINE_A}\n"],
            2: [f"{marker}\n{self.LINE_B}"],
            3: [f"{marker}\nmerged, older comment without the line"],
            4: [f"> quoting the owner:\n{self.LINE_A}"],  # no marker at the start: not the owner, not counted
            9: [f"{marker}\n{self.LINE_A}"],
        }
        gh = self.gh(prs, comments)
        r = self.m["collect_ready_outcomes"]("o/r", "2026-09-09", 200, gh=gh)
        self.assertEqual(r["prs_closed_in_window"], 4)  # PR 9 excluded
        self.assertFalse(any("/issues/9/" in p for p in gh.seen))
        self.assertEqual(r["owner_merged_comments"], 3)
        self.assertEqual(r["with_ready_outcomes_line"], 2)
        self.assertEqual(r["no_ready_outcomes_line"], [3])
        self.assertEqual((r["ready_flips"], r["red_at_ready"], r["red_after_green_local"]), (3, 1, 1))
        self.assertAlmostEqual(r["red_at_ready_rate"], 1 / 3)
        self.assertAlmostEqual(r["mismatch_rate"], 1 / 3)
        text = self.m["render_ready_outcomes"](r)
        self.assertIn("4 PRs closed in window", text)
        self.assertIn("no ready-outcomes line: [3]", text)
        self.assertIn("R/F (denominator: ready flips): 1/3 = 0.33", text)
        self.assertIn("M/F (denominator: ready flips): 1/3 = 0.33", text)

    def test_quoted_line_alone_is_not_an_owner_comment(self):
        r = self.collect(self.prs(4), {4: [f"see: {self.LINE_A}", f"<!-- other-marker -->\n{self.LINE_A}"]})
        self.assertEqual(r["owner_merged_comments"], 0)
        self.assertEqual(r["ready_flips"], 0)

    def test_zero_flips_prints_na_and_does_not_raise(self):
        r = self.collect(self.prs(1), {1: [f"{self.m['OWNER_MARKER']}\n{self.LINE_0}"]})
        self.assertEqual(r["with_ready_outcomes_line"], 1)
        self.assertIsNone(r["red_at_ready_rate"])
        self.assertIsNone(r["mismatch_rate"])
        text = self.m["render_ready_outcomes"](r)
        self.assertIn("R/F (denominator: ready flips): n/a", text)
        self.assertIn("M/F (denominator: ready flips): n/a", text)
        empty = self.collect([], {})  # nothing closed at all
        self.assertIn("n/a", self.m["render_ready_outcomes"](empty))

    def test_cap_drops_the_oldest_and_says_so(self):
        prs = [{"number": n, "closed_at": f"2026-09-{10 + n:02d}T00:00:00Z"} for n in (1, 2, 3)]
        gh = self.gh(prs, {})
        r = self.m["collect_ready_outcomes"]("o/r", "2026-09-09", 2, gh=gh)
        self.assertEqual((r["prs_closed_in_window"], r["prs_scanned"], r["dropped_by_cap"]), (3, 2, 1))
        self.assertEqual(sorted(p for p in gh.seen if "/issues/" in p),
                         ["repos/o/r/issues/2/comments?per_page=100", "repos/o/r/issues/3/comments?per_page=100"])
        self.assertIn("1 dropped by --max-prs cap", self.m["render_ready_outcomes"](r))

    def test_closed_pr_query_shape(self):
        gh = self.gh([], {})
        self.m["fetch_closed_prs"]("o/r", gh=gh)
        self.assertEqual(gh.seen, ["repos/o/r/pulls?state=closed&per_page=100&sort=updated&direction=desc"])


class ModeSelectionTests(unittest.TestCase):
    def setUp(self):
        self.m = load_module()

    def test_modes_are_mutually_exclusive(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as ctx:
            self.m["main"](["--target", "o/r:w.yml", "--run-counts", "--ready-outcomes"])
        self.assertEqual(ctx.exception.code, 2)
        self.assertIn("not allowed with", err.getvalue())

    def test_help_says_run_counts_ignores_sample(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit):
            self.m["main"](["--help"])
        self.assertIn("ignored by --run-counts", out.getvalue().replace("\n", " ").replace("  ", " "))

    def test_main_run_counts_json_and_text(self):
        runner = RoutingRunner(
            runs_stdout=json.dumps(run(7, "a")) + "\n",
            jobs_stdout=json.dumps(core()) + "\n",
        )
        out = io.StringIO()
        with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stdout(out):
            rc = self.m["main"](["--target", "o/r:w.yml", "--since", "2026-09-09", "--run-counts", "--json"])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out.getvalue())[0]["suite_executing"], 1)
        out = io.StringIO()
        with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stdout(out):
            self.assertEqual(self.m["main"](["--target", "o/r:w.yml", "--since", "2026-09-09", "--run-counts"]), 0)
        self.assertIn("1 suite-executing", out.getvalue())

    def test_until_is_validated_and_refused_with_ready_outcomes(self):
        # Each case names its own reason, so an unknown-flag rejection fails it.
        for argv, reason in ((["--until", "yesterday"], "YYYY-MM-DD"),
                             (["--until", "2026-10-06\n"], "YYYY-MM-DD"),  # `$` alone would let the newline into the query
                             (["--until", "2026-10-06", "--ready-outcomes"], "closed PRs")):
            err = io.StringIO()
            with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as ctx:
                self.m["main"](["--target", "o/r:w.yml", *argv])
            self.assertEqual(ctx.exception.code, 2, argv)
            self.assertIn(reason, err.getvalue())

    def test_main_run_counts_until_reaches_the_query_and_the_output(self):
        runner = RoutingRunner(runs_stdout=json.dumps(run(7, "a")) + "\n", jobs_stdout=json.dumps(core()) + "\n")
        argv = ["--target", "o/r:w.yml", "--since", "2026-09-22", "--until", "2026-10-06T08:15:22Z", "--run-counts"]
        out = io.StringIO()
        with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stdout(out):
            self.assertEqual(self.m["main"]([*argv, "--json"]), 0)
        self.assertTrue(runner.calls[0][3].endswith("created=2026-09-22..2026-10-06T08:15:22Z"), runner.calls[0][3])
        self.assertEqual(json.loads(out.getvalue())[0]["until"], "2026-10-06T08:15:22Z")
        out = io.StringIO()
        with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stdout(out):
            self.assertEqual(self.m["main"](argv), 0)
        self.assertIn("since 2026-09-22 until 2026-10-06T08:15:22Z", out.getvalue())

    def test_main_queue_waits_until_reaches_the_query_and_the_output(self):
        # The default mode takes --until too: a collect() that dropped it would
        # sample the open window while the header claimed the closed one.
        runner = RoutingRunner(runs_stdout=json.dumps(run(7, "a")) + "\n", jobs_stdout=json.dumps(core()) + "\n")
        argv = ["--target", "o/r:w.yml", "--since", "2026-09-22", "--until", "2026-10-06"]
        out = io.StringIO()
        with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stdout(out):
            self.assertEqual(self.m["main"]([*argv, "--json"]), 0)
        self.assertTrue(runner.calls[0][3].endswith("created=2026-09-22..2026-10-06"), runner.calls[0][3])
        self.assertEqual(json.loads(out.getvalue())[0]["until"], "2026-10-06")
        out = io.StringIO()
        with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stdout(out):
            self.assertEqual(self.m["main"](argv), 0)
        self.assertIn("== o/r:w.yml since 2026-09-22 until 2026-10-06: 1 runs", out.getvalue())

    def test_main_ready_outcomes_scans_each_repo_once(self):
        runner = RoutingRunner(runs_stdout="", jobs_stdout="")
        out = io.StringIO()
        with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stdout(out):
            rc = self.m["main"](["--target", "o/r:a.yml", "--target", "o/r:b.yml", "--since", "2026-09-09", "--ready-outcomes"])
        self.assertEqual(rc, 0)
        self.assertEqual(len(runner.calls), 1)
        self.assertIn("/pulls?state=closed", runner.calls[0][3])
        self.assertIn("0 PRs closed in window", out.getvalue())


if __name__ == "__main__":
    unittest.main()
