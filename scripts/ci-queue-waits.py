#!/usr/bin/env python3
"""Job-level CI queue wait per runner label, measured the only way that works.

Run on demand when CI feels slow, before any lane-sizing or runner-width
decision. Never schedule it: no decision consumes a weekly row (creation gate,
harness/ci-fleet-topology.md "Measuring queue wait"). Retire it when
ARC or the runners manifest exposes per-label queue wait directly, or when the
jobs API stops carrying `created_at` and `started_at`.

Why job level and first attempts only (both traps were hit on 2026-09-23 and
produced a wrong verdict in docs/ideation/2026-09-22-agentic-pipeline-throughput-ideation.html):

  1. On a run's first attempt GitHub sets `run_started_at` equal to
     `created_at`, so run-level "queue wait" is zero by construction. The only
     nonzero run-level values come from re-runs, where `created_at` is the
     original event and `run_started_at` the retry, which reads as a wait of
     hours or days. All 87 sampled "long waits" that day were attempt 2 or 3.
  2. A run's duration attributes every job's minutes to every label the
     workflow uses, so a dual-labelled workflow's heavy-job minutes land on
     the light pool.

The clean measure is per job: `started_at - created_at` on jobs of
first-attempt runs, grouped by the job's `labels`. Skipped jobs never queued
and are excluded.

Usage (three modes, mutually exclusive; no mode flag means queue waits):
  ci-queue-waits.py --target OWNER/REPO:workflow.yml [--target ...] \
      [--since YYYY-MM-DD] [--until YYYY-MM-DD[THH:MM:SSZ]] [--sample N] [--json]
  ci-queue-waits.py --run-counts --target ... [--since ...] [--until ...] [--core-job NAME] [--json]
  ci-queue-waits.py --ready-outcomes --target ... [--since ...] [--max-prs N] [--json]

`--until` closes the runs listing's created range (inclusive; both run modes).
A date-only bound covers that whole UTC day: on 2026-10-14 `created=2026-09-22..2026-09-22`
returned the same 39 runs as `2026-09-22T00:00:00Z..2026-09-22T23:59:59Z`.
GitHub returns at most 1,000 runs for a created-filtered listing and stops
there without an error, so a listing of 1,000 rows is refused as possibly
truncated: split the window with `--since` and `--until`.

`--sample N` takes N first-attempt completed runs at evenly spaced positions
across the window, oldest and newest included, instead of only the newest
runs. Each sampled run costs one jobs API call. Output is a per-label table
(p50/p90/p99/max wait in minutes, jobs over 2/5/30 minutes, pod-minutes) plus
the UTC hours and days that carry the long waits, so a burst reads as a burst.

`--run-counts` measures how often the suite jobs actually ran. Every run in
the window whose original attempt completed is counted once, from that
attempt (dotfiles#1634): the listing reports a re-run with its latest
attempt's status and conclusion, so a re-run's original comes from the
attempts endpoint, and every counted run's jobs from `/attempts/1/jobs`.
Counted runs split into suite-executing (the `--core-job` job concluded
anything but `skipped` in the original attempt) and scope-only, then
suite-executing runs per pull_request branch (branches, p50, p90, max),
push-event suite runs, and cancelled suite runs (original attempt cancelled)
in total, per ISO week, and how many of them were re-run (the countermetric:
a run cancelled before its suites ran is not counted). Re-runs and their later
attempts are reported apart and never counted. It reads every counted run's
jobs, one call each, plus one attempts call per re-run, and ignores
`--sample`. The queue-wait sampler keeps its own rule: first attempts only.

`--ready-outcomes` measures how ready heads fared: PRs closed at or after
`--since`, and from each one's PR-owner merged comment (a body that starts with
`<!-- pr-owner-merged/v1 -->`) the summed `Ready outcomes:` line, with the
red-at-ready rate R/F and mismatch rate M/F. It costs one comments call per
PR, so `--max-prs` caps the scan and the output says how many PRs the cap
dropped. The closed-PR listing itself is paginated in full; only the comments
calls are capped.

dotfiles#1598 R15 is the consumer of both new modes (before and after numbers
for CI once per ready head, plus the countermetric).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone

# The run-level timing fields (run_started_at, updated_at) are not even
# projected: trap 1 above. Only the job timestamps are read.
RUN_FIELDS = "{id, run_attempt, conclusion, status, event, created_at, head_branch}"
JOB_FIELDS = "{name, labels, created_at, started_at, completed_at, conclusion}"
# GitHub returns at most this many runs for a listing filtered by `created`,
# with no error (2026-10-14: total_count 1,257, 1,000 rows served).
LISTING_CAP = 1000


def parse_ts(value):
    """GitHub API timestamps are `YYYY-MM-DDTHH:MM:SSZ`; anything else is None."""
    if not value:
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def is_first_attempt(run):
    """A run without `run_attempt` is attempt 1 (older API payloads omit it)."""
    return (run.get("run_attempt") or 1) == 1


def job_wait_minutes(job):
    """Queue wait of one job, or None when it never queued (skipped) or the
    payload lacks either timestamp."""
    if job.get("conclusion") == "skipped":
        return None
    created, started = parse_ts(job.get("created_at")), parse_ts(job.get("started_at"))
    if created is None or started is None:
        return None
    return (started - created).total_seconds() / 60


def job_run_minutes(job):
    started, completed = parse_ts(job.get("started_at")), parse_ts(job.get("completed_at"))
    if started is None or completed is None or completed <= started:
        return 0.0
    return (completed - started).total_seconds() / 60


def label_key(job):
    return ",".join(job.get("labels") or []) or "?"


def sample_evenly(items, n):
    """n items at evenly spaced positions, first and last included, so the
    sample spans the list at every length; n <= 0 means all. (A fixed stride
    of len // n is 1 whenever n < len < 2n and kept only the oldest n.)"""
    if n <= 0 or len(items) <= n:
        return list(items)
    if n == 1:
        return [items[-1]]
    last = len(items) - 1
    return [items[round(i * last / (n - 1))] for i in range(n)]


def percentile(sorted_values, q):
    """Nearest-rank-below order statistic: the element at index
    int(q * (n - 1)) of an ascending list, q in [0, 1]; None on empty. No
    interpolation, so every figure is a wait that actually happened, and the
    published 2026-09 baseline's p90/p99 were computed exactly this way.
    pro-lane-report.py carries its own percentile(values, pct): 0-100 scale,
    sorts internally, rounds to the nearest index. The two are not
    interchangeable and their figures are not directly comparable; they stay
    separate on purpose, because a shared helper would change one script's
    published numbers."""
    if not sorted_values:
        return None
    return sorted_values[int(q * (len(sorted_values) - 1))]


def summarize(jobs_by_label):
    """jobs_by_label: {label: [job dicts]} -> {label: stats dict}. Pure."""
    out = {}
    for label, jobs in jobs_by_label.items():
        waits = [w for w in (job_wait_minutes(j) for j in jobs) if w is not None]
        if not waits:
            continue
        s = sorted(waits)
        out[label] = {
            "jobs": len(s),
            "p50": round(percentile(s, 0.5), 2),
            "p90": round(percentile(s, 0.9), 2),
            "p99": round(percentile(s, 0.99), 2),
            "max": round(s[-1], 2),
            "over_2": sum(1 for w in s if w > 2),
            "over_5": sum(1 for w in s if w > 5),
            "over_30": sum(1 for w in s if w > 30),
            "pod_minutes": round(sum(job_run_minutes(j) for j in jobs if job_wait_minutes(j) is not None), 1),
        }
    return out


def long_wait_buckets(jobs, threshold=5.0):
    """UTC hour and day histograms of jobs whose wait exceeds `threshold`."""
    by_hour, by_day = Counter(), Counter()
    for j in jobs:
        w = job_wait_minutes(j)
        if w is None or w <= threshold:
            continue
        started = parse_ts(j.get("started_at"))
        by_hour[started.hour] += 1
        by_day[started.date().isoformat()] += 1
    return {"by_hour": dict(sorted(by_hour.items())), "by_day": dict(sorted(by_day.items()))}


def gh_lines(path, jq, runner=None):
    """`gh api --paginate PATH --jq JQ`, one JSON object per output line.
    `runner` stands in for subprocess.run under test; looked up at call time
    so a patched subprocess.run is honoured on the default path too."""
    proc = (runner or subprocess.run)(
        ["gh", "api", "--paginate", path, "--jq", jq],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"gh api {path}: {proc.stderr.strip()[:300]}")
    return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]


def fetch_runs(owner_repo, workflow, since, gh=gh_lines, until=None):
    created = f"{since}..{until}" if until else f"%3E%3D{since}"
    path = f"repos/{owner_repo}/actions/workflows/{workflow}/runs?per_page=100&created={created}"
    runs = gh(path, f".workflow_runs[] | {RUN_FIELDS}")
    if len(runs) >= LISTING_CAP:
        raise RuntimeError(f"{path}: {len(runs)} runs is GitHub's cap for a created-filtered listing, so the window "
                           "may be truncated; split it with --since and --until")
    return runs


def fetch_attempt(owner_repo, run_id, attempt, gh=gh_lines):
    """One attempt of a run, projected like a listing row."""
    path = f"repos/{owner_repo}/actions/runs/{run_id}/attempts/{attempt}"
    rows = gh(path, RUN_FIELDS)
    if len(rows) != 1:
        raise RuntimeError(f"gh api {path}: expected one run, got {len(rows)}")
    return rows[0]


def fetch_jobs(owner_repo, run_id, gh=gh_lines, attempt=None):
    """A run's jobs: its latest attempt's, or those of `attempt`."""
    scope = f"attempts/{attempt}/jobs" if attempt else "jobs"
    return gh(f"repos/{owner_repo}/actions/runs/{run_id}/{scope}?per_page=100", f".jobs[] | {JOB_FIELDS}")


def window(result):
    """`since X`, or `since X until Y` when the listing's range was closed."""
    return f"since {result['since']}" + (f" until {result['until']}" if result.get("until") else "")


def collect(owner_repo, workflow, since, sample, gh=gh_lines, until=None):
    """Measure one workflow. Only first-attempt, completed runs are sampled;
    the run-level timing fields are never read."""
    runs = fetch_runs(owner_repo, workflow, since, gh=gh, until=until)
    first = [r for r in runs if is_first_attempt(r) and r.get("status") == "completed"]
    first.sort(key=lambda r: r.get("created_at") or "")
    chosen = sample_evenly(first, sample)
    jobs_by_label = defaultdict(list)
    all_jobs = []
    for run in chosen:
        for job in fetch_jobs(owner_repo, run["id"], gh=gh):
            jobs_by_label[label_key(job)].append(job)
            all_jobs.append(job)
    return {
        "target": f"{owner_repo}:{workflow}",
        "since": since,
        "until": until,
        "runs_in_window": len(runs),
        "first_attempt_completed": len(first),
        "reruns_excluded": sum(1 for r in runs if not is_first_attempt(r)),
        "sampled_runs": len(chosen),
        "labels": summarize(jobs_by_label),
        "long_waits_over_5_min": long_wait_buckets(all_jobs),
    }


def render(result):
    lines = [
        f"== {result['target']} {window(result)}: {result['runs_in_window']} runs, "
        f"{result['first_attempt_completed']} first-attempt completed, {result['reruns_excluded']} re-runs excluded, "
        f"{result['sampled_runs']} sampled ==",
        f"{'label':32} {'jobs':>5} {'p50':>6} {'p90':>6} {'p99':>7} {'max':>7} {'>2m':>4} {'>5m':>4} {'>30m':>5} {'pod_min':>8}",
    ]
    for label, s in sorted(result["labels"].items(), key=lambda kv: -kv[1]["jobs"]):
        lines.append(
            f"{label:32} {s['jobs']:>5} {s['p50']:>6.1f} {s['p90']:>6.1f} {s['p99']:>7.1f} {s['max']:>7.1f} "
            f"{s['over_2']:>4} {s['over_5']:>4} {s['over_30']:>5} {s['pod_minutes']:>8.0f}"
        )
    lw = result["long_waits_over_5_min"]
    lines.append(f"jobs waiting >5 min by UTC hour: {lw['by_hour']}")
    lines.append(f"jobs waiting >5 min by day: {lw['by_day']}")
    return "\n".join(lines)


CORE_JOB = "Harness suites (core)"
OWNER_MARKER = "<!-- pr-owner-merged/v1 -->"
# One anchored line the PR owner writes in its merged comment; older comments
# lack it. Trailing spaces and a CR are tolerated, nothing else is.
READY_LINE_RE = re.compile(
    r"^Ready outcomes: (\d+) ready flip\(s\), (\d+) red at ready, (\d+) red after a green local record\.[ \t\r]*$",
    re.MULTILINE,
)


def iso_week(created_at):
    """`YYYY-Www` of a created_at timestamp, or "unknown" when it will not parse."""
    ts = parse_ts(created_at)
    if ts is None:
        return "unknown"
    year, week, _ = ts.isocalendar()
    return f"{year}-W{week:02d}"


def is_suite_executing(jobs, core_job):
    """True when the core job exists and concluded anything but `skipped`. A
    run with no job of that name is not suite-executing."""
    return any(j.get("name") == core_job and j.get("conclusion") != "skipped" for j in jobs)


def original_attempt(owner_repo, run, gh=gh_lines):
    """The run as its first attempt left it. The listing reports a re-run with
    its latest attempt's number, status and conclusion, so a re-run's original
    comes from the attempts endpoint; an attempt-1 row is its own original."""
    if is_first_attempt(run):
        return run
    return {**run, **fetch_attempt(owner_repo, run["id"], 1, gh=gh)}


def collect_run_counts(owner_repo, workflow, since, core_job, gh=gh_lines, until=None):
    """Suite-executing run counts for one workflow, each run counted once from
    its original attempt (dotfiles#1634). Dropping a re-run, the rule before,
    took a run that did execute out of the denominator; counting each attempt
    would make a same-head retry read as another push. Every counted run's
    jobs are read (no sampling): a sample would blur exactly the draft/ready
    split being counted."""
    runs = fetch_runs(owner_repo, workflow, since, gh=gh, until=until)
    per_branch, cancelled_by_week = Counter(), Counter()
    counted = executing = push = other = reruns = extra = cancelled_rerun = 0
    for listed in runs:
        run = original_attempt(owner_repo, listed, gh=gh)
        if run.get("status") != "completed":
            continue
        counted += 1
        later = (listed.get("run_attempt") or 1) - 1
        if later:
            reruns, extra = reruns + 1, extra + later
        if not is_suite_executing(fetch_jobs(owner_repo, run["id"], gh=gh, attempt=1), core_job):
            continue
        executing += 1
        if run.get("event") == "pull_request":
            per_branch[run.get("head_branch") or "?"] += 1
        elif run.get("event") == "push":
            push += 1
        else:
            other += 1
        if run.get("conclusion") == "cancelled":
            cancelled_by_week[iso_week(run.get("created_at"))] += 1
            if later:
                cancelled_rerun += 1
    counts = sorted(per_branch.values())
    return {
        "target": f"{owner_repo}:{workflow}",
        "since": since,
        "until": until,
        "core_job": core_job,
        "original_attempt_completed": counted,
        "rerun_runs": reruns,
        "extra_attempts": extra,
        "suite_executing": executing,
        "scope_only": counted - executing,
        "pr_suite_runs": sum(counts),
        "pr_branches": len(counts),
        "pr_runs_per_branch": {"p50": percentile(counts, 0.5), "p90": percentile(counts, 0.9), "max": counts[-1] if counts else None},
        "push_suite_runs": push,
        "other_event_suite_runs": other,
        "cancelled_suite_runs": sum(cancelled_by_week.values()),
        "cancelled_suite_runs_rerun": cancelled_rerun,
        "cancelled_by_week": dict(sorted(cancelled_by_week.items())),
    }


def render_run_counts(r):
    b = r["pr_runs_per_branch"]
    fig = lambda v: "n/a" if v is None else str(v)
    return "\n".join([
        f"== {r['target']} {window(r)}: {r['original_attempt_completed']} runs whose original attempt completed, "
        f"each counted once ({r['rerun_runs']} re-run, {r['extra_attempts']} later attempts not counted); "
        f"{r['suite_executing']} suite-executing ('{r['core_job']}' not skipped in the original attempt), "
        f"{r['scope_only']} scope-only ==",
        f"pull_request suite runs: {r['pr_suite_runs']} across {r['pr_branches']} branches; "
        f"per branch p50 {fig(b['p50'])}, p90 {fig(b['p90'])}, max {fig(b['max'])}",
        f"push suite runs: {r['push_suite_runs']} (other events: {r['other_event_suite_runs']})",
        f"cancelled suite runs: {r['cancelled_suite_runs']} ({r['cancelled_suite_runs_rerun']} of them re-run; by the "
        f"original attempt's conclusion, and a cancelled run whose core job skipped is not counted); "
        f"by ISO week: {r['cancelled_by_week']}",
        f"scope-only runs: {r['scope_only']}",
    ])


def fetch_closed_prs(owner_repo, gh=gh_lines):
    path = f"repos/{owner_repo}/pulls?state=closed&per_page=100&sort=updated&direction=desc"
    return gh(path, ".[] | {number, closed_at}")


def fetch_issue_comments(owner_repo, number, gh=gh_lines):
    return gh(f"repos/{owner_repo}/issues/{number}/comments?per_page=100", ".[] | {body}")


def parse_ready_line(body):
    """(F, R, M) from the owner's `Ready outcomes:` line, or None."""
    m = READY_LINE_RE.search(body or "")
    return tuple(int(g) for g in m.groups()) if m else None


def rate(num, den):
    """num/den, or None when den is 0: never a division by zero, shown as n/a."""
    return None if not den else num / den


def collect_ready_outcomes(owner_repo, since, max_prs, gh=gh_lines):
    """Ready-flip outcomes for the PRs of one repo closed at or after `since`
    (the string compare is exact: both are ISO-ordered). Newest closed first,
    so the cap drops the oldest. `max_prs` <= 0 means no cap."""
    closed = [p for p in fetch_closed_prs(owner_repo, gh=gh) if (p.get("closed_at") or "") >= since]
    closed.sort(key=lambda p: p["closed_at"], reverse=True)
    scanned = closed if max_prs <= 0 else closed[:max_prs]
    with_line, no_line = [], []
    flips = red_ready = red_after = 0
    for pr in scanned:
        bodies = [c.get("body") or "" for c in fetch_issue_comments(owner_repo, pr["number"], gh=gh)]
        owner = [b for b in bodies if b.startswith(OWNER_MARKER)]
        if not owner:
            continue
        parsed = [p for p in (parse_ready_line(b) for b in owner) if p]
        if not parsed:
            no_line.append(pr["number"])
            continue
        f, rr, m = parsed[-1]  # the latest owner comment carrying the line
        with_line.append(pr["number"])
        flips, red_ready, red_after = flips + f, red_ready + rr, red_after + m
    return {
        "repo": owner_repo,
        "since": since,
        "prs_closed_in_window": len(closed),
        "prs_scanned": len(scanned),
        "dropped_by_cap": len(closed) - len(scanned),
        "owner_merged_comments": len(with_line) + len(no_line),
        "with_ready_outcomes_line": len(with_line),
        "no_ready_outcomes_line": no_line,
        "ready_flips": flips,
        "red_at_ready": red_ready,
        "red_after_green_local": red_after,
        "red_at_ready_rate": rate(red_ready, flips),
        "mismatch_rate": rate(red_after, flips),
    }


def render_ready_outcomes(r):
    def ratio(num, key):
        return "n/a" if r[key] is None else f"{num}/{r['ready_flips']} = {r[key]:.2f}"
    return "\n".join([
        f"== {r['repo']} since {r['since']}: {r['prs_closed_in_window']} PRs closed in window, {r['prs_scanned']} scanned, "
        f"{r['dropped_by_cap']} dropped by --max-prs cap ==",
        f"{r['owner_merged_comments']} had an owner merged comment, {r['with_ready_outcomes_line']} of those carried the ready-outcomes line",
        f"no ready-outcomes line: {r['no_ready_outcomes_line']}",
        f"ready flips F={r['ready_flips']}, red at ready R={r['red_at_ready']}, red after a green local record M={r['red_after_green_local']}",
        f"red-at-ready rate R/F (denominator: ready flips): {ratio(r['red_at_ready'], 'red_at_ready_rate')}",
        f"mismatch rate M/F (denominator: ready flips): {ratio(r['red_after_green_local'], 'mismatch_rate')}",
    ])


TARGET_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$")


def parse_target(text):
    """OWNER/REPO:workflow.yml. Both halves are interpolated into an API path,
    so only path-safe characters are accepted (no '/', '?', '&' or '#' in the
    workflow part)."""
    if not TARGET_RE.match(text):
        raise argparse.ArgumentTypeError(f"--target wants OWNER/REPO:workflow.yml, got {text!r}")
    owner_repo, workflow = text.split(":", 1)
    return owner_repo, workflow


UNTIL_RE = re.compile(r"\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}Z)?")


def parse_until(text):
    """A date or a UTC timestamp. It is interpolated into the listing query,
    so nothing else is accepted (fullmatch: `$` would admit a trailing
    newline)."""
    if not UNTIL_RE.fullmatch(text):
        raise argparse.ArgumentTypeError(f"--until wants YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ, got {text!r}")
    return text


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--target", action="append", type=parse_target, required=True, help="OWNER/REPO:workflow.yml (repeatable)")
    ap.add_argument("--since", default=None, help="YYYY-MM-DD, default 14 days ago")
    ap.add_argument("--until", type=parse_until, default=None, help="YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ, inclusive end of the runs listing's created range (both run modes); default open")
    ap.add_argument("--sample", type=int, default=150, help="first-attempt runs to sample per target (0 = all); ignored by --run-counts, which reads every run")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--run-counts", action="store_true", help="count suite-executing runs per branch, push, cancelled and scope-only instead of queue waits")
    mode.add_argument("--ready-outcomes", action="store_true", help="sum the PR owner's ready-outcomes lines over PRs closed in the window")
    ap.add_argument("--core-job", default=CORE_JOB, help="job name that marks a run suite-executing when not skipped (--run-counts)")
    ap.add_argument("--max-prs", type=int, default=200, help="closed PRs whose comments are read, newest first (0 = all); the output says how many the cap dropped (--ready-outcomes)")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of the table")
    args = ap.parse_args(argv)
    if args.until and args.ready_outcomes:
        ap.error("--until bounds the runs listing; --ready-outcomes reads closed PRs and does not take it")
    since = args.since or (datetime.now(timezone.utc).date().toordinal() - 14)
    if isinstance(since, int):
        since = datetime.fromordinal(since).date().isoformat()
    results = []
    if args.ready_outcomes:
        repos = list(dict.fromkeys(owner_repo for owner_repo, _ in args.target))  # one scan per repo
        jobs = [(lambda repo=repo: collect_ready_outcomes(repo, since, args.max_prs)) for repo in repos]
        shown = render_ready_outcomes
    elif args.run_counts:
        jobs = [(lambda t=t: collect_run_counts(t[0], t[1], since, args.core_job, until=args.until)) for t in args.target]
        shown = render_run_counts
    else:
        jobs = [(lambda t=t: collect(t[0], t[1], since, args.sample, until=args.until)) for t in args.target]
        shown = render
    for job in jobs:
        try:
            results.append(job())
        except RuntimeError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
    if args.json:
        print(json.dumps(results, indent=1))
    else:
        print("\n\n".join(shown(r) for r in results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
