#!/usr/bin/env python3
"""Weekly pipeline-mix visibility (report-only): is the review pipeline working
on the products, or on itself, and what does a gated issue cost in Pro rounds.

Why this exists: over 2026-09-04..07 the wrapper loop drove 30 gated merges and
13 were the loop hardening itself, each defect found by the gate reviewing the
previous fix. Two chains never converged and were stopped by a human reading
the findings. Nothing surfaced either fact while it happened; the operator
found out by asking for an audit. Both numbers already live in records the
harness keeps: merged-PR file lists (GitHub) and charged review rounds per
round key (the pro-gate ledger). This prints them weekly (dotfiles#1045).

Both numbers are scoped to the GATED cohort -- merges the review lane actually
handled, identified by a pro-gate ledger round key or the dispatcher's
`loop-run` label -- and the cost half counts CHARGED rounds, not invocations:
the producer stamps `kind: fresh` before it knows whether the run ever reached
the model, so the outcome/reason enum is what separates a paid review from a
lock-timeout.

Report-only in the spend-report sense: reads the ledger and the GitHub API,
writes nothing, labels nothing, spends no slot. Output contract matches its
siblings: human lines, [WARN]-bracketed findings, a trailing
`pipeline-mix-flagged:N` counter for the toast gate, and an unbracketed
`WARN ...` line when a feed is dead, because a mix report that silently
reports nothing is the failure mode it exists to prevent.
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

# Round keys are `<owner>-<repo>-<pr>`, and both the owner and the repo carry
# hyphens (`acme-org-trading-app-194`), so a key cannot be split on
# the hyphen alone: doing that printed `fund#194` for trading-app. Strip a
# known owner prefix, then the trailing PR number; what remains is the repo.
OWNER_PREFIXES = ("StartupBros-com-", "StartupBros-", "acme-org-")

# The pipeline's own surface: the three drivers and their suites in hov-stack,
# and the whole pro-gate repository, which IS the review runtime.
#
# The suite half is a NAMING RULE, not a list of filenames, because a list
# drifts from the tree the day a suite is added and that drift is silent. It
# already had: the shipped enumeration named three suites while the tree held
# three more for the SAME three drivers -- claude-loop-budget-stop,
# claude-loop-cut-short and claude-loop-quality-mode all drive
# bin/claude-loop.sh. is_self() requires EVERY changed path to match, so
# a merge hardening the driver together with its own regression test read as
# product work, and a week of two pipeline-only merges beside one product merge
# reported 33% instead of 67% -- under the 40% threshold, so the warning this
# report exists to raise never fired (dotfiles#1046 pro-gate round 3).
#
# This repo names a driver's suites `<driver>[-<aspect>].test.sh`, so match
# that. The three stems stay exact and are NOT prefixes of each other's
# families: `dispatcher-tick` does not admit dispatcher-ledger or
# dispatcher-status, which test different drivers. Suites that merely drive one
# of these binaries as scaffolding keep their own names and stay correctly
# outside this surface -- discord-notify.test.sh (subject: discord-notify.sh)
# and loop-quality-integration.test.sh (subject: loop-quality.py) both invoke
# claude-loop.sh without being regression suites for it.
#
# Which components belong on this surface at all -- the dispatcher's
# ledger/status scripts, loop-quality -- is a definition of the metric rather
# than a defect in it, and is open for the operator's call in dotfiles#1060.
SELF_PATHS = re.compile(
    r"^(scripts/(pro-gate-loop|dispatcher-tick)\.sh"
    r"|bin/claude-loop\.sh"
    r"|tests/(pro-gate-loop|claude-loop|dispatcher-tick)(-[a-z0-9-]+)?\.test\.sh)$"
)
SELF_REPOS = ("pro-gate",)

# Issue #1045 asks for the share among the LOOP-RUN merges, not among every
# merge: ordinary product and docs work in the same repositories is not the
# review pipeline working, and counting it only dilutes the number this report
# exists to raise. Cohort membership is the union of two provenance records the
# harness already keeps, because neither covers the fleet on its own -- announce-bot
# carries no `loop-run` label at all while contributing the most ledger round
# keys (32 in the audited week), and hov-stack #986/#1012 were gated by hand and
# carry a ledger round key with no label.
GATE_LABELS = ("loop-run",)

# `kind` alone does not mean "a review was charged". pg_finish() sets
# kind=fresh for EVERY non-harvest invocation before it knows the exit code, so
# a run that never reached the model lands in the ledger looking exactly like
# one that did. These are the outcomes the producer writes for a fresh
# invocation that provably submitted nothing: refused before the per-change
# lock (round-capped), never acquired a slot (lock-timeout), refused by the
# post-slot health gate before the first dispatch (deferred), refused on size
# (oversized), or died while resolving the repo/diff (bad-repo,
# diff-fetch-failed, other -- exits 2 and 3, whose every call site precedes
# prompt assembly). A Cloudflare challenge proves no prompt reached the model
# and the producer refunds the round. Measured against the live ledger
# 2026-08-08..09-07: 77 of 738 fresh rows, and 5 round keys whose whole
# "charged" count came from rows like these.
UNCHARGED_OUTCOMES = frozenset((
    "lock-timeout", "round-capped", "deferred", "oversized",
    "bad-repo", "diff-fetch-failed", "cloudflare", "other",
))
# outcome=failed splits by the producer's closed `reason` enum. These two are
# the ones that prove no charge: refunded-unsubmitted is the value the engine
# built specifically to record a proven-unsubmitted round (22 more rows in the
# same window), and pre-dispatch is its fallback for a failure before any
# dispatch attempt. The remaining reasons (post-dispatch, salvage-empty,
# infra-error, browser-restart) all follow a real submission and stay counted.
UNCHARGED_REASONS = frozenset(("refunded-unsubmitted", "pre-dispatch"))
# Every repository the review lane serves. Both halves of this report read the
# same list: the first live run counted merges in four repositories while the
# round costs came from all five in the ledger, so announce-bot -- the heaviest
# consumer at 107 charged rounds over the audited weekend -- dominated the cost
# line while contributing nothing to the share. One list, both feeds.
DEFAULT_REPOS = (
    "StartupBros-com/hov-stack",
    "acme-org/trading-app",
    "StartupBros/hov-router",
    "StartupBros-com/pro-gate",
    "acme-org/announce-bot",
)


def env_number(name, default):
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def now_utc():
    pinned = os.environ.get("PIPELINE_MIX_NOW", "").strip()
    if pinned:
        return datetime.strptime(pinned, "%Y-%m-%dT%H:%M:%S%z")
    return datetime.now(timezone.utc)


def parse_ts(raw):
    """Both feeds stamp ISO-8601; the pro-gate ledger uses a local offset."""
    if not isinstance(raw, str) or not raw:
        return None
    try:
        stamped = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return stamped if stamped.tzinfo else stamped.replace(tzinfo=timezone.utc)


def ledger_path():
    home = os.environ.get("PRO_GATE_HOME") or os.path.join(os.path.expanduser("~"), ".pro-review-daemon")
    return os.environ.get("PIPELINE_MIX_LEDGER") or os.path.join(home, "ledger.jsonl")


def repo_of(key):
    """The repository a round key names, or "" when it does not name one."""
    head, sep, tail = key.rpartition("-")
    if not sep or not tail.isdigit():
        return ""
    for prefix in OWNER_PREFIXES:
        if head.startswith(prefix):
            return head[len(prefix):]
    return head


def charged(row):
    """Did this ledger row spend a Pro round?

    `kind` is the first gate: a harvest collects an existing result over CDP and
    never submits, so it is never a charge. It is not the LAST gate, which is
    what the first cut got wrong. pg_finish() assigns `kind=fresh` for every
    non-harvest invocation BEFORE it knows the exit code, so a lock-timeout or a
    round-cap refusal -- neither of which reaches the model -- is written with
    the same `kind` as a completed review. Counting on `kind` alone therefore
    measured invocations, not charges: four lock-timeouts on one PR reported
    "median 4" and a non-convergence warning for a chain that had bought no
    reviews at all. The charge test is the producer's own outcome/reason enum.

    Known-uncharged outcomes are excluded; everything else stays counted. The
    residue is deliberate: `throttle` on a nonzero exit and a fresh
    `in-progress` row can each go either way, and the producer records no
    evidence in these two fields that settles them (dotfiles#1053). Dropping
    them would understate a cost line whose whole job is to make cost visible.
    """
    if row.get("kind") != "fresh":
        return False
    outcome = row.get("outcome")
    if outcome in UNCHARGED_OUTCOMES:
        return False
    return not (outcome == "failed" and row.get("reason") in UNCHARGED_REASONS)


def read_ledger(path, since, until, allowed):
    """One pass over the pro-gate ledger for both halves of this report.

    Returns `(rounds, gated, malformed, unresolved)`:
      * `rounds` -- CHARGED review rounds per round key inside the window, for
        `allowed` repos, so the cost line and the share describe one fleet.
        Deduplicated by conversation marker; see ONE MARKER IS ONE CHARGE below.
      * `gated` -- every `(repo, pr)` the gate has EVER been invoked on, with no
        window and no charge test. Gate participation is not gate spend: a PR
        whose only ledger row is a lock-timeout was still admitted to the lane,
        and a PR gated the day before it merged has no in-window row at all, so
        windowing this set would drop merges that belong in the cohort.
      * `malformed` -- nonblank lines that did not decode to a JSON object.
        Counted and skipped here, but the caller has to SAY SO: a corrupt
        ledger's round counts and gated cohort are silently short, and a
        confident zero off a half-read feed is the exact failure mode this
        script exists to prevent (dotfiles#1046 pro-gate round 2).
      * `unresolved` -- in-window charged rows carrying no marker, so nothing
        names the conversation they paid for and they cannot be deduplicated.
        They stay counted, because dropping spend evidence understates the cost
        line, but they are reported separately since a duplicate hiding among
        them is invisible. Zero across the whole live ledger on 2026-09-07 (640
        charged rows, every one marked): the honest fallback, not the norm.
    `rounds` and `gated` are None when the ledger cannot be read at all.

    ONE MARKER IS ONE CHARGE. The producer's two reservation-redirect paths
    (oracle-review.sh, the pre-dispatch reconcile and the post-lock re-check)
    set `RUN_MARKER` to the marker of the conversation ALREADY generating and
    `pg_finish 9` without submitting anything -- while pg_finish() still stamps
    `kind=fresh`, because it assigns `kind` before it knows the exit code. Those
    rows pass charged(), so counting per row bills one Pro conversation several
    times over: on the live ledger for 2026-08-24..25, marker
    `pg-run-acme-org-announce-bot-1962-1787612345-3354518` carries three of
    them under one round key. Charges are therefore collapsed by marker across
    the WHOLE ledger and attributed to that marker's EARLIEST charged row,
    before the window is applied -- so a redirect can neither invent a charge
    nor drag a charge paid for last month into this week's report.
    """
    gated = set()
    malformed = 0
    first_charge = {}   # marker -> (earliest charged timestamp, round key)
    unmarked = []       # (timestamp, round key) for charged rows with no marker
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
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
                key = row.get("round_key") or row.get("pr") or "unknown"
                repo = repo_of(key)
                if allowed and repo not in allowed:
                    continue
                if repo:
                    gated.add((repo, key.rpartition("-")[2]))
                stamped = parse_ts(row.get("ts"))
                if stamped is None:
                    continue
                if not charged(row):
                    continue
                marker = row.get("marker") or ""
                if not marker:
                    unmarked.append((stamped, key))
                    continue
                prior = first_charge.get(marker)
                if prior is None or stamped < prior[0]:
                    first_charge[marker] = (stamped, key)
    except (FileNotFoundError, NotADirectoryError, PermissionError):
        return None, None, 0, 0
    # The window applies to the deduplicated charges, never to the raw rows.
    rounds = {}
    unresolved = 0
    for stamped, key in first_charge.values():
        if since <= stamped <= until:
            rounds[key] = rounds.get(key, 0) + 1
    for stamped, key in unmarked:
        if since <= stamped <= until:
            rounds[key] = rounds.get(key, 0) + 1
            unresolved += 1
    return rounds, gated, malformed, unresolved


def gh_merged(repo, since, timeout, limit):
    """Merged population metadata; file lists are fetched only for the cohort.

    Returns `(rows, truncated)`, or `(None, False)` when gh fails.

    `--limit` is a cap on the WHOLE result, not a page size, and gh reports no
    truncation of its own: at the shipped 100 it returned exactly 100 rows for
    windows that really held 163 (announce-bot) and 172 (hov-stack) on 2026-09-07, so
    a third of a normal week vanished from the share with nothing said. There is
    no cursor flag on `gh pr list` to page past it, so the cap is raised well
    above the observed volume AND compared against the returned count: a full
    response is indistinguishable from a truncated one, so it is reported as
    partial rather than believed. Keep this population read metadata-only:
    fetching files here paid for every merge before discarding the ungated ones
    (163 PRs with files took 10.9s in the audited week; dotfiles#1054).
    """
    argv = [
        "gh", "pr", "list", "--repo", repo, "--state", "merged", "--limit", str(limit),
        "--search", "merged:>=%s" % since.strftime("%Y-%m-%d"),
        "--json", "number,mergedAt,labels",
    ]
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None, False
    if done.returncode != 0:
        return None, False
    try:
        rows = json.loads(done.stdout or "[]")
    except ValueError:
        return None, False
    return rows, len(rows) >= limit


def gh_files(repo, number, timeout):
    """Changed paths for one cohort member, or None for an unreadable detail feed."""
    argv = ["gh", "pr", "view", str(number), "--repo", repo, "--json", "files"]
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode != 0:
        return None
    try:
        data = json.loads(done.stdout)
    except ValueError:
        return None
    files = data.get("files") if isinstance(data, dict) else None
    # An empty list is valid; a missing/malformed list is unknown, not product
    # work. Let the caller mark the feed partial rather than dilute the share.
    if not isinstance(files, list) or any(
        not isinstance(f, dict) or not isinstance(f.get("path"), str) or not f["path"]
        for f in files
    ):
        return None
    return files


def in_window(row, since, until):
    stamped = parse_ts(row.get("mergedAt"))
    return stamped is not None and since <= stamped <= until


def load_prs(repos, since, until, timeout, limit, gated):
    """Merged PRs per repo, from a fixture when one is supplied, else from gh.

    The live feed first establishes the merged population, then fetches paths
    only for in-window members of the ledger/label cohort. Fixtures already
    carry paths and need no enrichment.

    Returns `(per_repo_rows, failed, truncated)`. `failed` and `truncated` are
    both partial-feed conditions: one repo could not be fully read, the other
    answered an unknown fraction. A fixture is complete by construction.
    """
    fixture = os.environ.get("PIPELINE_MIX_PR_JSON", "").strip()
    if fixture:
        with open(fixture, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return {repo: [r for r in data.get(repo, []) if in_window(r, since, until)] for repo in repos}, [], []
    out, failed, truncated = {}, [], []
    for repo in repos:
        deadline = time.monotonic() + timeout
        rows, capped = gh_merged(repo, since, timeout, limit)
        if rows is None:
            failed.append(repo)
            continue
        if capped:
            truncated.append(repo)
        cohort = [r for r in rows if in_window(r, since, until) and is_gated(repo, r, gated)]
        for row in cohort:
            # Preserve the old per-repo budget across both stages, rather than
            # granting every detail request another full timeout.
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failed.append(repo)
                break
            files = gh_files(repo, row["number"], remaining)
            if files is None:
                failed.append(repo)
                break
            row["files"] = files
        else:
            # Publish a repo only after every member has readable paths; a
            # failed lookup must not turn an arbitrary prefix into its share.
            out[repo] = cohort
    return out, failed, truncated


def is_self(repo, row):
    """A merge is self-referential when it only touches the pipeline's surface."""
    if repo.split("/")[-1] in SELF_REPOS:
        return True
    paths = [f.get("path", "") for f in row.get("files", [])]
    return bool(paths) and all(SELF_PATHS.match(p) for p in paths)


def is_gated(repo, row, gated):
    """Did this merge go through the review lane at all?

    Issue #1045 asks for the share among LOOP-RUN merges. Filtering on the merge
    timestamp alone answered a different question: two gated pipeline-only
    merges beside eight ordinary product merges read as 20%, quietly under the
    warn threshold, when the gated cohort was 100% self-referential -- ordinary
    work concealing exactly the workload this report exists to surface.

    The union of two provenance records, because each misses what the other
    catches: the dispatcher's `loop-run` label does not exist in announce-bot at all,
    and hand-driven gate runs (hov-stack #986, #1012) carry a ledger round key
    and no label.
    """
    for label in row.get("labels") or []:
        if label.get("name") in GATE_LABELS:
            return True
    if gated is None:
        return False
    return (repo.split("/")[-1], str(row.get("number"))) in gated


def summarize(prs, rounds, rounds_warn, gated):
    total = self_count = 0
    per_repo = {}
    for repo, rows in prs.items():
        cohort = [r for r in rows if is_gated(repo, r, gated)]
        selfs = sum(1 for r in cohort if is_self(repo, r))
        per_repo[repo] = (len(cohort), selfs)
        total += len(cohort)
        self_count += selfs
    counts = sorted(rounds.items(), key=lambda kv: (-kv[1], kv[0])) if rounds else []
    values = [v for _, v in counts]
    return {
        "total": total,
        "self": self_count,
        "share": (self_count / total) if total else 0.0,
        "per_repo": per_repo,
        "worst": counts[:3],
        # A true median, not the upper of the two middle values: with one
        # four-round issue and one one-round issue, "median 4" would read as
        # though every issue cost four rounds.
        "median": statistics.median(values) if values else 0,
        "over": [k for k, v in counts if v > rounds_warn],
    }


def short(key):
    """`acme-org-trading-app-194` reads as `trading-app#194`."""
    head, sep, tail = key.rpartition("-")
    if not sep or not tail.isdigit():
        return key
    for prefix in OWNER_PREFIXES:
        if head.startswith(prefix):
            return "%s#%s" % (head[len(prefix):], tail)
    return "%s#%s" % (head, tail)


def render(summary, rounds_ok, failed, truncated, malformed, unresolved, days, share_warn, rounds_warn, limit):
    lines, flags = [], []
    if summary["total"]:
        lines.append("gated merges in %dd: %d, of which %d touch only the pipeline itself (%.0f%%)"
                     % (days, summary["total"], summary["self"], summary["share"] * 100))
        for repo, (total, selfs) in sorted(summary["per_repo"].items()):
            if total:
                lines.append("  %-16s %2d merged, %2d self-referential" % (repo.split("/")[-1], total, selfs))
    else:
        lines.append("gated merges in %dd: none" % days)
    # Column-0 WARN, not a bracketed finding: these say the FEED is incomplete,
    # which is the one thing this report must never report as a quiet zero.
    if failed:
        lines.append("WARN pipeline-mix: could not read merges for %s - the share is partial" % ", ".join(failed))
    if truncated:
        lines.append("WARN pipeline-mix: merge feed hit the %d-PR cap for %s - the share is partial"
                     % (limit, ", ".join(truncated)))
    if rounds_ok:
        worst = ", ".join("%s=%d" % (short(k), v) for k, v in summary["worst"]) or "none"
        # %g, not %d: a true median of an even count is a half step, and %d
        # silently floored 2.5 to 2, which reads as a cheaper lane than it is.
        lines.append("Pro rounds per gated issue: median %g, worst %s" % (summary["median"], worst))
        # A READABLE ledger is not a COMPLETE one. read_ledger() skips lines
        # that do not parse -- a torn write, a partial line from a crashed
        # producer -- and before this the report threw that count away: an
        # all-malformed ledger printed "median 0, worst none" and
        # pipeline-mix-flagged:0, i.e. a confident zero and nothing to toast on.
        # Column-0 WARN, like the other partial-feed lines, because that is the
        # shape harness-weekly's `^WARN` gate matches.
        if malformed:
            lines.append("WARN pipeline-mix: %d unreadable ledger row(s) skipped - the round counts and "
                         "the gated cohort are partial" % malformed)
        # Spend that cannot be tied to a conversation cannot be deduplicated
        # either, so these rounds are counted but not vouched for.
        if unresolved:
            lines.append("WARN pipeline-mix: %d charged round(s) carry no conversation marker - "
                         "a duplicate submission among them cannot be ruled out" % unresolved)
    else:
        lines.append("WARN pipeline-mix: pro-gate ledger missing - no round costs, "
                     "and the gated cohort falls back to the loop-run label alone")
    # A share computed from a feed that dropped an unknown number of merges is
    # not comparable to a threshold: capping a 120-merge product repo at 100
    # turns a true 40% into 44% and invents a warning. The counts still print;
    # only the verdict is withheld, and the WARN above says why.
    # A ledger that lost rows to a torn write is the same kind of incomplete
    # feed: it can drop gated-cohort members, so the share it produces is not
    # comparable to a threshold either.
    partial = bool(failed) or bool(truncated) or not rounds_ok or bool(malformed)
    if summary["total"] and summary["share"] > share_warn and not partial:
        flags.append("[WARN] pipeline-mix: %.0f%% of merges were the pipeline working on itself (over %.0f%%) - "
                     "check that intake is fed from the product backlog"
                     % (summary["share"] * 100, share_warn * 100))
    if summary["over"]:
        flags.append("[WARN] pipeline-mix: %d issue(s) past %d Pro rounds (%s) - a chain that does not converge is "
                     "a design question, not another patch"
                     % (len(summary["over"]), rounds_warn, ", ".join(short(k) for k in summary["over"][:5])))
    return lines, flags


def main(argv=None):
    parser = argparse.ArgumentParser(description="Weekly pipeline-mix report (report-only).")
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    days = args.days if args.days > 0 else 7
    until = now_utc()
    since = until - timedelta(days=days)
    repos = [r.strip() for r in os.environ.get("PIPELINE_MIX_REPOS", "").split(",") if r.strip()] or list(DEFAULT_REPOS)
    share_warn = env_number("PIPELINE_MIX_SELF_SHARE_WARN", 0.4)
    rounds_warn = int(env_number("PIPELINE_MIX_ROUNDS_WARN", 3))
    allowed = {r.split("/")[-1] for r in repos}
    # The cap still covers the whole merge population, not just the cohort.
    # Both fetch stages share the existing timeout budget for each repository.
    limit = int(env_number("PIPELINE_MIX_GH_LIMIT", 500))
    rounds, gated, malformed, unresolved = read_ledger(ledger_path(), since, until, allowed)
    prs, failed, truncated = load_prs(repos, since, until, env_number("PIPELINE_MIX_GH_TIMEOUT", 90), limit, gated)
    summary = summarize(prs, rounds or {}, rounds_warn, gated)
    if args.json:
        print(json.dumps({"summary": summary, "malformed": malformed, "unresolved": unresolved,
                          "failed": failed, "truncated": truncated}, indent=2))
        return 0
    lines, flags = render(summary, rounds is not None, failed, truncated, malformed, unresolved,
                          days, share_warn, rounds_warn, limit)
    for line in lines:
        print(line)
    for flag in flags:
        print(flag)
    print("pipeline-mix-flagged:%d" % len(flags))
    return 0


if __name__ == "__main__":
    sys.exit(main())
