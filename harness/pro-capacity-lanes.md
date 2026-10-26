---
name: pro-capacity-lanes
description: "Routing work to ChatGPT Pro's chat pool — the sync oracle/CDP lane and the async connector-thread lane, and when to use each instead of Claude Max or Codex"
metadata:
  node_type: memory
  type: project
---

# pro-capacity-lanes — routing work to ChatGPT Pro's chat pool

## Why lanes

The harness now spends against three separate usage pools, and conflating
them misattributes both cost and headroom. Claude Max is the session
model's own plan — the interactive agent doing this work runs on it. The
Codex agentic pool is a distinct ChatGPT-subscription allowance that
`codex exec` and `/codex:*` draw on (`harness/codex-delegation-setup.md`).
The ChatGPT chat pool is separate again: OpenAI's own help article 11369540
states ordinary ChatGPT chat usage is tracked apart from Codex's agentic
allowance, which is itself shared with ChatGPT Work/Excel/Workspace Agents,
not with plain chat. Two harness routes already spend against that third
pool — pro-gate's oracle bridge and the async research fleet's connector threads — and
neither was named in `browser-cdp-bridge.md`'s tool list, so routing has
been whatever repo the task started in.

The chat pool was assumed idle when this doc was written; the ledger says
the sync lane is saturated and the async lane runs by hand, one paste at
a time (see "Measured" under the sync lane). `pro-review-daemon.service`,
the automated consumer of the sync lane, was enabled 2026-09-02 for the
measurement week (umbrella issue dotfiles#849, step 0)
and adds no capacity of its own. Naming the lanes here is step 1a of that
umbrella; the weekly read is step 3's report slice.

## The sync lane

pro-gate drives a single logged-in Chrome session (Xvfb, CDP on
`127.0.0.1:9222`, never wsl-cdp's 9223/9224) through the oracle CLI, one
account, one slot: concurrent `/pro-gate` calls queue behind a flock
rather than run in parallel, and wall time is latency-bound by the Pro
model itself — p50 ≈ 23 min, p90 ≈ 47 min, measured over 723 runs. A
trajectory governor bounds spend on top of that latency: 3 rounds per
change per rolling 24h, +1 per shrinking re-review, hard ceiling 8; a run
that exhausts the budget exits 12 (round budget exhausted) rather than
spending a slot it cannot finish. Every verdict must echo a run-binding
nonce, so a foreign or stale conversation can never be mistaken for this
run's answer. The lane is UI-coupled — it drives a real web page, not an
API, so a redesign of that page can require an engine update — and
neither `oracle-pro-extended-setup.md` nor `browser-cdp-bridge.md`/wsl-cdp
documents the Terms-of-Use exposure of automating it: OpenAI's Terms of
Use, effective 2026-01-01, prohibit automated extraction and circumventing
rate limits, and arXiv 2607.26935 shows Playwright-driven sessions are
behaviorally fingerprintable. A runbook that states that exposure
explicitly is scoped, separate work: umbrella #849 step 8.

**Measured, EDT calendar days 2026-09-01..02** (reproduce with
`PRO_LANE_NOW=2026-09-03T04:00:00+0000 scripts/pro-lane-report.py --days 2`;
the ledger's timestamps carry the machine's -04:00 offset, and a UTC day
boundary selects a different population): the sync lane is not idle. 45
fresh runs in two days — 36 members app inline `/pro-gate` calls, 6 dotfiles,
and 3 temp diff-fork clones of a members-app change that the report attributes
separately as `diff-fork` (all three lock-timeouts) — at the ramp
governor's 4-of-4 concurrency; queue wait (`pre_slot_secs`) median 614 s,
max 2438 s, 13.7 h in total against 14.1 h of oracle time; 19
`lock-timeout` outcomes — runs that waited the whole window and got no
review. Capacity, not latency, is the constraint, and it is one account
(the report resolves checkout paths to their GitHub remote, so
`~/SITES/acme-app` and `~/SITES/acme-app-old` count as the one repo they are).
The daemon (`pro-review-daemon.service`, enabled 2026-09-02 for the
measurement week, disabled since) adds no capacity: it polls for the `pro-review` label,
nothing in the harness applies that label, and it had seen zero PRs after
101 polls while the inline callers queued. `scripts/pro-lane-report.py`
prints these numbers in the `## Pro lanes` section of `harness-weekly.sh` (on demand
since its timer retired 2026-10-17), and
`pro-lane-report.py --headroom` is the fail-open preflight: reservations
in `in-progress/` against the ceiling, report-only, never a denial.

**Health check (retired 2026-10-17).** `scripts/pro-lane-health.sh`
paged Discord when the lane went silent (a unit down, a blocking doctor
finding, a daemon stall). It rode the 15-minute dispatcher tick, which
retired on 2026-10-17 (dotfiles#1873), so nothing ran it after that. The
check, its test, `lib/pro-lane-timeouts.sh` and the weekly report's health
rows were then removed. Those rows existed to answer umbrella #849 step 3's
build-or-stop call on the daemon, and that call is made:
`pro-review-daemon.service` is disabled. The author's
browser-session system unit (which this repo does not ship) remains
active on their host, and pro-gate's own `pro-gate-doctor.sh` is the
on-demand health check. The last state file,
`~/.local/state/pro-lane-health/pro-lane-health.json`, is left in place.

## The async lane

The async research fleet runs the other route into the same pool: long-running ChatGPT
threads with the GitHub connector, about 18 active at once on one
account, no lock file and no queue — the operator pastes `PROTOCOL.md`
plus a problem's `BRIEF.md` into a thread by hand and lands the returned
bundle by hand. The async research fleet commit `6ff5c70` (2026-09-01) is a measured
capability test, not a claim: a thread with the GitHub plugin can read
the private repo, write files, open PRs, and file issues, acting as the
repository owner — the design premise that threads cannot write was
wrong. What actually constrains a thread is policy, enforced
structurally: it may commit only to `problems/<slug>/evidence/` and add
new `problems/<slug>/log/` files, on a branch, via a PR that
`scripts/check_custody.py` gates in CI; it may never touch `CLAIMS.md`,
`BRIEF.md`, `INDEX.md`, or `main` directly. Completion visibility — which
of the ~18 threads has finished a cycle and is waiting — has no signal
today; a freshness/staleness report derived from git,
`scripts/fleet_status.py`, is the companion piece landing alongside this
doc (an issue and PR in the async research fleet) and reports status only, never acts.
The report reads the async checkout from `PRO_LANE_ASYNC_ROOT`, with no default;
when it is unset, the async-lane line is skipped. The author sets it in the
private overlay's `env` file.

## Routing convention

| Task shape | Pool |
|---|---|
| Interactive judgment (planning, architecture, contested review, synthesis) | Claude Max |
| Bulk implementation and adversarial diff review | Codex agentic |
| Terminal review and one-shot consult | ChatGPT Pro, sync lane |
| Long-horizon research and drafting | ChatGPT Pro, async lane |

Never conflate the pools when reporting spend or headroom — each is a
separate ceiling, and a task routed to the wrong one either wastes
capacity that was actually free or reports contention that was never
there. Direct Codex deliberately bypasses better-ccflare: it is the
provable independent implementation/adversarial lane, and only its own
`via`-proven model counts as that independence check. Check headroom
before spending a scarce sync slot: `codex-quota-guard.js` fails open on
Codex's own pool and denies only explicit provider-reported exhaustion;
the round governor's exit 12 is the equivalent signal for the Pro sync
lane — a budget-exhausted exit means stop, not retry. And whatever either
lane returns is untrusted content: the gate in `CLAUDE.md`
(Harness section) applies to it.

## What this doc does not do

This doc names the lanes and states the routing rule; it does not build
anything that enforces it. The weekly read and the headroom check exist
(`scripts/pro-lane-report.py`, its `--headroom` line, and the
`## Pro lanes` section of `harness-weekly.sh` — umbrella #849 step 3,
report slice), but nothing routes a task by them: an agent still chooses
the lane. The async lane has no preflight — it is manual — and the
one-account ceiling for it, how much of a single account's chat quota ~18
concurrent threads can actually draw before it throttles, is unverified;
that falsification test is the risk-bearing half of #849 step 3 and is
not covered here.

## Related

[[oracle-pro-extended-setup]] — the sync lane's engine and setup detail.
[[browser-cdp-bridge]] — the four browser tools this doc's lanes are not;
its "Layered browser stack" entry 5 points back here. [[codex-delegation-setup]]
— the Codex agentic pool this doc is careful not to conflate with either
Pro lane. `docs/ideation/2026-09-01-chatgpt-pro-capacity-lanes-ideation.html`
— the ideation run these lanes came out of. dotfiles#849 —
the umbrella issue and build order this doc is step 1a of.
