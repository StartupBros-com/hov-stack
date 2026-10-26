# CI fleet topology: queue width, force-pushes, and the live check

Demoted from CLAUDE.md on 2026-09-19 by the /rent-check audit (issue #1209, refs #1202 item 21):
the always-on line keeps the rule and points here for the incident and the procedure. The fleet
the incident describes changed shape on 2026-09-04/05, so the worked example below is history,
not the current topology.

## Ceremony Test (required of any new process artifact, evidence-regime section 1)

- **Consumer:** any agent about to push to, cancel, or wait on a PR whose required check runs on
  a shared runner label, reached through the one CLAUDE.md Worktree Lifecycle bullet that links
  here. Not a human-read-only doc.
- **Defect it exists for:** the 2026-07-29 incident below (four pushes, zero completions, the
  wanted PR starved), plus the rule's own admission that a cached topology example rots: the
  fleet changed on 2026-09-04/05 and the always-on line still described the old one.
- **Gate:** none; no hook can see runner width. The lever is the always-on rule plus the live
  check in this doc.
- **Delete when:** the fleet table below is next found stale against `runners.manifest`, or the
  CLAUDE.md link is removed. Rewrite or retire; do not leave it standing.

## The rule

Never force-push an in-flight PR. Before assuming a required check's queue is single-slot, or
assuming it no longer is, check the job's live `runs-on:` label against the runners that carry that
label today. On a width-one label, keep one PR in that queue at a time. Batch edits into one push.
When a queue is deep, land the unblocking PR first and leave the rest alone.

## Why: the 2026-07-29 incident, moved from CLAUDE.md

Moved whole from the CLAUDE.md bullet it replaced; the only edits are the two em-dashes rendered
as a colon and a period.

Single-slot merge gates: one PR in that queue at a time, and never force-push to an in-flight PR.
Where a required check has exactly one capable runner, every extra in-flight PR is subtracted from
the others, and a force-push is worse than no push: it takes a slot, then `cancel-in-progress`
kills it, completing nothing. Measured 2026-07-29: four pushes to one PR burned four slot-cycles
for zero completions while the PR the operator was actually waiting on sat behind them. CI topology
drifts (runners get added, retired, relabelled). Before assuming a queue is single-slot *or* that
it no longer is, check the job's live `runs-on:`-label-to-runner mapping rather than trusting a
cached example. Batch edits into one push; when a queue is deep, land the unblocking PR first and
leave the rest alone.

Cancelling queued runs to clear a path is almost never a net win either: those branches re-run
later and retake the slot. The only cancellations that help are genuinely superseded runs, where
the run's `head_sha` is no longer the branch tip. CLAUDE.md keeps that check inline.

## The fleet since 2026-09-04/05

Every CI route in the three orgs runs on one ARC/k3s cluster or on hosted overflow (a CI
topology memory note, confidence 0.95, last validated 2026-09-05). An ARC scale
set's width is its `maxRunners` in the author's infrastructure repository `ops/arc/helm/values-<set>.yaml`. The prose
in `ops/github-runners/runners.manifest` can lag it: on 2026-10-17 the manifest still said
`maxRunners 2` for `linux-x64-light`, whose values file has said 6 since 2026-09-11.

| `runs-on:` label | Runner | Width |
|---|---|---|
| `linux-x64` | PR pool on the k3s runner | 4 concurrent pods by CPU request (five-wide reintroduced the members app's Supabase reset race) |
| `linux-x64-light` | no-Docker light pool: 3 pods on the k3s runner, 3 on a light-runner laptop | `maxRunners: 6` (a private infrastructure change); 3 while the laptop sleeps, when its pods wait Pending |
| `deploy-linux-x64` | credentialed lane on a deploy host | not recorded in the memory note; read `runners.manifest` |
| `linux-arm64` | ARM64 runner | not recorded in the memory note; read `runners.manifest` |

So the "single-slot" premise no longer holds for the general PR pool: a burst of PRs on
`linux-x64` queues four wide rather than serializing. Whether any other lane is width one is read
from its values file, not assumed. A job that dies with a step still `in_progress` and no failed step
is a vanished runner (node maintenance), not a flake. Auto-merge-armed PRs drop later commits; open
a new PR instead. The fleet's contract, runbook, and knobs live in the author's infrastructure repository
`ops/arc/README.md` and `ops/github-runners/README.md`. dotfiles' own `harness-tests.yml` ran on
`linux-x64` (dotfiles #973) until dotfiles #1104 moved every job to `linux-x64-light` on
2026-09-10, so its suites queue three to six wide.

## The live check

1. Read the job's label: `grep -n 'runs-on:' .github/workflows/<workflow>.yml`.
2. List the runners carrying that label and how many can run at once. For the ARC fleet that is
   the scale set's `maxRunners` in the author's infrastructure repository `ops/arc/helm/values-<set>.yaml`, not the
   manifest's prose; for a hosted label it is the org's concurrency limit.
3. Before cancelling anything, compare the run's `head_sha` with the branch tip:
   `gh api repos/<owner>/<repo>/branches/<branch> --jq .commit.sha`. Cancel only when they differ.
4. When width is one, treat every extra in-flight PR on that label as subtracted from the one you
   are waiting on, keep one PR in that queue, and never push to an in-flight PR more than once per
   wave.

Re-audit trigger: any change to the ARC scale-set widths, a new `runs-on:` label in a workflow, or
a queue that behaves single-slot on a label this table says is wider.

## Measuring queue wait

Measure per job, on first-attempt runs, grouped by the job's own `labels`:
`scripts/ci-queue-waits.py --target OWNER/REPO:workflow.yml --since YYYY-MM-DD`. Run it on
demand when CI feels slow and before any lane-width decision. It is deliberately not scheduled:
no decision consumes a weekly row, so a standing report fails the creation gate above.
Delete when: ARC or `runners.manifest` exposes per-label queue wait directly, or the jobs API
stops carrying `created_at` and `started_at`. Rewrite or retire the script and this section
together; do not leave either standing.

Two run-level fields look like queue-wait measures and are not; both produced a wrong verdict on
2026-09-23 (retracted in `docs/ideation/2026-09-22-agentic-pipeline-throughput-ideation.html`):

- `run_started_at - created_at` is zero on a first attempt by construction. The only nonzero
  values come from re-runs, where `created_at` is the original event and `run_started_at` the
  retry, so a retry a day later reads as a 26-hour wait. All 87 sampled "long waits" were attempt
  2 or 3.
- A run's duration lands on every label its workflow uses, so a workflow with `light` gate jobs
  and `heavy` suite jobs attributes the suite's minutes to the light pool.

Baseline, 2026-09-09 to 2026-09-22, 300 runs (170 of the members app's `workflow.yml`, 130 of dotfiles'
`harness-tests.yml`) and 1,684 jobs sampled: `light` and `linux-x64-light` jobs wait 0.1 min at
p50 and under 1 min at p90 (max 3.6 and 5.6); `heavy` jobs wait 0.2 at p50, 4.7 at p90, 12.8 max,
with 54 of 62 long waits on the evening of 2026-09-21. The other six jobs were dotfiles `Harness
suites` runs on `linux-x64` early in the window (p50 5.9, max 59.5 min): too few to size a lane,
and the same burst shape as `heavy`.
No pool is chronically contended. The amd64 heavy lane queues in bursts and is held at 4 wide by
the members app's Supabase reset race, not by hardware. The fleet's felt latency is run duration (the members app first-attempt p90
26.5 min) and the cancel-and-restart cycle (50% of the members app first-attempt runs, 14% of dotfiles',
cancelled by the next push), not queueing.

The baseline was derived by the same session that made the retracted error and has not been
independently re-derived. Three refute-by-default lenses reviewed the correction on 2026-09-23 and
checked the script's two API mechanisms live (compact one-line `--jq` output; the `created`
qualifier filters by date) but did not recompute the per-label figures. After the topic review the
same day, the original scratch script was re-executed over its saved run lists: it reproduced every
figure above and accounted for all 1,684 jobs. That is re-execution by the same session, not an
independent derivation. Re-running the shipped script over 2026-09-09 to 2026-09-22 is the check;
its sampler now spans the window at every length, so its 300-run sample will differ slightly from
the original's.
