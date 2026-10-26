---
title: "A ready flip or body edit leaves the cancelled run's check rows at the same head; judge CI by the deciding run per workflow and event"
date: 2026-10-05
category: integration-issues
module: pr-owner-ci-current-check-runs
problem_type: integration_issue
component: development_workflow
symptoms:
  - "The PR owner parked a members-app change as 'CI is red' one poll after its own body edit (adding a `Closes` line) cancelled the ready-for-review run; a later run at the same head went fully green"
  - "The owner dispatched a CI fix session for a cancelled 'Schema Release Gate Readback' row on a members-app change; the fixer re-ran it green without moving the head and the loop parked `fixer-no-change`"
  - "An agent's `gh pr checks` wait on a members-app change showed a pass from the cancelled draft-time run while the live ready-event run was still in progress"
  - "At one head, `commits/<sha>/check-runs` and `statusCheckRollup` list every job up to four times, cancelled and failed copies included"
  - "After the filter shipped, owners on four members-app changes still sent fix sessions for a superseded run's cancelled rows; later reads of the same heads dropped those rows"
root_cause: wrong_api
resolution_type: code_fix
severity: high
retire_when: "GitHub collapses superseded check suites, so a head whose earlier run a concurrency group cancelled lists only the newest run's rows; check acme-org/announce-bot PR 4201 at 7f734ce, whose raw check-runs held 11 cancelled rows on 2026-10-05"
related_components:
  - pr-owner.sh
  - pro-gate-loop.sh
  - gate-check.sh
  - loop_quality/effects.py
tags: [check-runs, status-check-rollup, gh-pr-checks, cancel-in-progress, superseded-check-suite, ready-for-review, pr-owner, ci-read]
---

# A ready flip or body edit leaves the cancelled run's check rows at the same head; judge CI by the deciding run per workflow and event

**Status, 2026-10-18.** The PR owner this lesson was learned on was removed by #1873 on 2026-10-17. Every `pr-owner.sh` citation below (`ready_flip`, `owner_merge`, `merge_wait_ci`, `merge_ci_retry`, and the `CI_SHAPE=partial` case in `pr-owner.test.sh`) is pre-removal history. Those line numbers date from the 2026-10-05 tree and had already drifted by `dd68bf5a^`. The lesson itself still applies. The filter (`scripts/lib/ci-current-check-runs.{jq,sh}`) and its readers `gate-check.sh`, the Stop hook's `currentRollup` and the standalone `wait_ci` in `pro-gate-loop.sh` are live. The `--owner-state` branches in `pro-gate-loop.sh` stay, but nothing outside its tests launches them. Part 3, the settle hold, has no live caller, because nothing passes `settle` or `hold` now. Under Merge-and-end (`CLAUDE.md`) the authoring session's own CI wait is the reader the Prevention section is for.

## Problem

Take a repository whose workflows run on `ready_for_review` or `edited` under a `concurrency` group with `cancel-in-progress`. A `pull_request_target` workflow that fires on those types counts too. On such a repository, marking a PR ready or editing its body starts a new workflow run at the **same head SHA**, and the concurrency group cancels the older run.

GitHub keeps every check suite the commit has had. `commits/<sha>/check-runs`, `gh pr view --json statusCheckRollup` and `gh pr checks` all list the cancelled run's rows beside the live run's. That breaks readers in two directions:
- **Scoring every row reads the head red.** A cancelled row counts as red, and so does an aggregate job that failed because its needs were cancelled, even when the newest run is green.
- **Picking one row per name can keep a stale pass.** A draft-time green that no longer describes the head reads as green.

The PR owner parked healthy PRs this way (issues #1595 and #1558). PR #1599 fixed it for the harness readers.

## Symptoms

- **a members-app change (issue #1595):**
  - At 13:54:21Z the owner ran `gh pr ready`. `merge_wait_ci` read green at once, because only the draft run's completed checks existed yet.
  - The owner then appended a `Closes` line for the linked issue to the body. That `edited` event cancelled the ready-for-review run.
  - The next poll read the `cancelled` rows as red, and the owner parked at 13:55:07Z.
  - A run created at 14:04:08Z went fully green, but the old rows never leave. On 2026-10-05 that head (`7f734ce`) listed 42 check runs across nine workflow runs: 11 `cancelled`, 4 `failure`, 4 `skipped` and 23 `success`. The four failures are `⚫️ Test` and `🧪 Test Run` in the two cancelled `Workflow` runs. `statusCheckRollup` reports the same counts plus one commit status.
- **a members-app change (issue #1558):**
  - A body edit seconds after a push cancelled "Schema Release Gate Readback" (run `37242282107`, `pull_request_target`).
  - The owner dispatched a CI fix session for that row. The fixer re-ran the cancelled run, which went green, without moving the head.
  - The loop then parked `fixer-no-change`. It was the third park of this class on that PR.
- **a members-app change** (papercut `gh-checks:stale-cancelled-run-row`): an agent's required-checks wait loop saw `gh pr checks` show `⚫️ Test pass 23s`. That row came from the cancelled draft-time run `37240523392`, while the live ready-event run `37240757664` was still `in_progress`.
- **a members-app change (issue #1388):** gate-check read check runs in API order and kept the last row per name. An older `cancelled` TypeScript row overwrote the current `success`.

## What Didn't Work

- **Treating every cancelled run as benign (session history).** A push that moves the head cancels the old run, and that run's `head_sha` is no longer the tip, so a reader keyed on the head never sees it (`harness/ci-fleet-topology.md`). A ready flip or body edit is different: it supersedes a run at the *same* SHA. The cancelled rows sit on the very head being read.
- **Keeping one row per check name.** API order is newest first, so "last wins" keeps the oldest row, a green or a cancellation that no longer describes the head. That is #1388's defect, and the filter's header names it (`scripts/lib/ci-current-check-runs.jq:7-8`).
- **Letting the newest run per workflow supersede older runs wholesale.** This was #1599's first revision, and its round-1 adversarial review found the flaw. An `edited` run whose jobs filter that action out skips every job. Letting it supersede hid a real failure in the earlier run at the same head. That is a false green, where the old count-every-suite reader at least read red.
- **Dropping a deciding run that lists no check run of its own.** #1599's CE review (Codex peer) found two such cases:
  - A green run with no jobs listed still dropped the suite it superseded, so an older failure became `[]`. `pro-gate-loop.sh`'s standalone wait reads `[]` as "this repository has no CI" after its grace (`scripts/pro-gate-loop.sh:1190-1192`).
  - A run that failed before any job, such as a startup failure or a run awaiting approval, vanished.

  Both were fixed before merge. The first now holds pending; the second reads red.
- **Standing in only for a deciding run that lists no check run.** #1599 merged this way, and an independent read on #1599 found the gap after merge:
  - GitHub creates a job's check run only once every job it `needs:` has finished. In four Harness Tests runs on 2026-10-06 UTC (runs 37392646092, 37392901231, 37393309782, 37393323350), each dependent job's `created_at` fell 0-1 s after its dependency's `completed_at`.
  - A poll in that hand-off saw the still-running run as nothing but its finished green setup job, with no pending row. `pr-owner.test.sh`'s `CI_SHAPE=partial` case merged at that poll against the merged filter.
  - A required check at the end of the chain should still block the merge itself, though no test covers that. `pro-gate-loop.sh`'s waits had no such backstop and read "CI green" there.
  - The fix: an unfinished deciding run whose listed check runs have all finished stands in as pending beside them.
  - A first version of that fix stood in for every unfinished run. A review of it found the stand-in's one row stayed `{in_progress, null}` for the run's whole life. The PR owner's stall clock restarts a row only when its status or conclusion changes (`pr-owner-state.sh:156-175`, `pr_owner_ci_track`), so a run unfinished past the 6 h bound would read as stalled while its jobs still moved. While a listed check run is pending it already holds the head, so the stand-in now steps aside for it, and a stand-in that comes back starts a fresh clock.

## Solution

PR #1599 shipped three parts.

**1. A shared filter** (`scripts/lib/ci-current-check-runs.jq`, sourced through `ci-current-check-runs.sh`). It reads two endpoints for the head: `commits/<sha>/check-runs` and `actions/runs?head_sha=<sha>`. It groups the workflow runs by `[workflow_id, event]`, and in each group it keeps the newest run by `[created_at, id]` that tested something (`:69-72`, `:82-83`):

```jq
def tested_something($checks):
  .check_suite_id as $suite |
  [$checks[] | select(.check_suite.id == $suite)] as $own |
  .status != "completed" or ($own | length) == 0 or any($own[]; .conclusion != "skipped");

[$workflows | group_by([.workflow_id, .event])[] | sort_by([.created_at, .id]) | reverse |
  (map(select(tested_something($checks))) | first) // first] as $latest |
```

How the filter treats each case:
- **Superseded suites:** a check run is dropped only when its suite belongs to a listed workflow run that a newer run superseded. Check runs from other apps pass through (`:85-86`).
- **An Actions suite no listed run claims** means the workflow-runs listing is incomplete, and the read gives no verdict (#1636). Five owner reads after #1599 kept a superseded run's cancelled rows as red: one members-app change twice and three others once each. An incomplete listing is the one way found for the filter to keep those rows; the cause is inferred. With the newer run missing, the cancelled run decides its group. With the older one missing, its suite passed through. Now the filter refuses such a pair (`ci-current-check-runs.jq:64-67`, `:75-78`). The shell helper reads both endpoints again, 3 reads 5 s apart, before it fails the read (`ci-current-check-runs.sh:11-44`). A read count that is not a number fails the read after one.
- **A deciding run that has not finished, with every listed check run finished,** stands in as one pending entry beside them (`:88-96`). A job that `needs:` another has no check run until that one finishes, so a run's listed jobs can all be green while the run is not done. While a listed check run is pending, that row holds the head and no stand-in joins it. A run that lists no job yet, such as one still queued, keeps one unchanged row, so one queued past the owner's 6 h stall bound reads as a stall, as it did when #1599 merged.
- **A finished deciding run with no check run listed** stands in too (`:97-103`). It is pending when the run finished green with no job listed, because GitHub lists skipped jobs too, so that is a listing gap. It is red with the run's conclusion when it finished failed.
- **Input:** it must be exactly two page arrays. Anything else is an error, never a shorter list (`:118-124`).

**2. The owner edits the body before the flip.** `owner_merge` appends the `Closes #N` reference before `ready_flip` runs `gh pr ready` (`scripts/pr-owner.sh:579-591`), so the flip's own run is the newest.

**3. A settle hold.** After a flip or an edit, `ready_flip` takes GitHub's `updatedAt` as the settle point and a local bound of `CI_CURRENT_SETTLE_SECS` (90 s; `pr-owner.sh:516-521`, `ci-current-check-runs.sh:10`). Until a workflow run created at or after that point is listed, one `queued` entry holds the head (`ci-current-check-runs.jq:108-112`). If the bound passes with no such run, the helper says so on stderr and reads the runs listed.

Every harness reader that polls remote check runs to gate a merge, a fix round or a loop stop goes through the filter. Draft waits may instead consume exact-head saved ready-red or local suite evidence (`pro-gate-loop.sh`, `owner_draft_wait_ci`):
- `pr-owner.sh` `merge_wait_ci` (`:388`; removed by #1873)
- `pro-gate-loop.sh` `wait_ci` (`:1183`), the owner wait (`:2401`) and the stall repair (`:2486`)
- `gate-check.sh` (`:152`)
- `scripts/lib/loop_quality/effects.py` (`:168-174`; removed by #1916, so the reader and its citation no longer exist)

One reader uses a coarser filter. The Stop hook's `classifyPr` (`hooks/Stop/verify-on-stop.js:691-704`) reads `statusCheckRollup` through `currentRollup` (`:645-685`), added by #1612. Per workflow name it keeps the entries of the highest run id that tested something. It groups by name rather than by workflow and event, and it has no stand-in for a run that lists no check yet. The hook only observes and grants no merge authority.

Checked live on 2026-10-05 at the head of a members-app change: the 42 raw rows came back as 15, one per job, all `success`. `tests/ci-current-check-runs.test.sh` passed 38 of 38 when #1599 merged, and 45 of 45 with the unfinished-run stand-in.

## Why This Works

- **What the group key encodes.** A concurrency group cancels an older run of the *same* workflow. Keying on the event as well means a run for one event never hides a run for another.
- **Why creation time picks the run.** Within a suite, the check-runs endpoint already keeps the latest attempt. Ordering by `created_at` rather than by the attempt's start means a re-run of a superseded run never displaces the run that replaced it (`.jq:16-18`).
- **Why skip-only runs don't count.** A run that tested nothing supersedes nothing (`.jq:20-23`). The deciding run is the newest one that ran a job, so a filtered-out `edited` run cannot hide an earlier failure.
- **Why the filter fails closed.** It drops evidence only when a newer run that tested the same head replaces it. Every other gap reads as pending or red, never as green or as an empty list. That includes a run that has so far listed only some of its jobs, which #1599 as merged did read as green. A listing that leaves an Actions suite unclaimed gives no verdict at all, because the filter cannot tell which run is current. One gap remains invisible. A listing can omit a new run that has no check run yet, and then the run it superseded still decides.
- **Why the hold closes the last race.** Right after a flip, only the draft run's checks exist, all complete. The hold makes the owner wait for the flip's run before trusting green, and the body edit moved before the flip means the owner no longer cancels the run it is waiting on.

## Prevention

- **Read a head's CI through `ci_current_check_runs` in any new harness reader.** Never use `statusCheckRollup`, `gh pr checks` or a raw check-runs list for this. A reader that bypasses the filter brings back both the false red and the stale green.
- **Do the same in ad-hoc agent waits.** Agents still use `gh pr checks` (a members-app change). Instead:

  ```bash
  source ~/.claude/scripts/lib/ci-current-check-runs.sh
  ci_current_check_runs <owner/repo> <head-sha> | jq -r '.[] | [.name, .status, (.conclusion // "-")] | @tsv'
  ```

  This ran against a members-app change and dotfiles#1599 on 2026-10-05. When either endpoint cannot be read, or the workflow-runs listing still leaves an Actions suite unclaimed after its rereads, the function exits non-zero and prints nothing; its stderr names the unclaimed suites. The pipeline's status is `jq`'s, so test for empty output. Treat empty output as unreadable, never as "no checks".
- **Never edit a PR body after the ready flip** on a repository that runs CI on `edited`. Edit it first, or expect a new run and settle before reading.
- **A read failure must never become an empty list.** An empty list means "no CI" to the standalone wait after its grace. The shipped wait only reaches that branch on a successful empty read (`pro-gate-loop.sh:1183-1192`), and the owner wait stops typed when reads keep failing (`:2401-2410`).
- **Recovery is separate from filtering.** A cancelled row that nothing superseded still reads red; the shared selector does not declare it benign. PR #1703 (Refs #1668) added a narrow repair path in both ordinary and typed-stop owner merges: at most two failed-only rerun requests per unchanged merge-candidate head for a classified infrastructure stall in a deciding ready `pull_request` run. Before requesting a rerun, the owner verifies the complete original attempt's failure set and run/head/event/suite/attempt identities, then persists the consumed budget and request intent before the effect. It requires a complete advanced attempt and matching current checks before green can decide the merge (`scripts/pr-owner.sh`, `merge_ci_retry` and `merge_ci_retry_checks`). #1873 removed that repair with `pr-owner.sh`; the one rerun now is the authoring session's own `gh run rerun --failed` under Merge-and-end. Old red cannot spend another request, and partial green cannot authorize a merge.
- **Not covered by that repair:**
  - Genuine test failures, manual cancellations, and unknown, partial or mismatched evidence remain ineligible. Ineligible or exhausted retries retain the original ordinary draft/fixer route or typed-stop park behavior. A no-change fixer still emits `fixer-no-change` without reconciling CI itself; the owner then applies its stop policy, which can merge a green current head when the last completed Pro review left no open P0, or park otherwise. General post-fixer CI reconciliation remained separate from #1703; #1558, which tracked it, was closed as moot on 2026-10-17 (see Related Issues).
  - The Stop hook's coarser filter, described under Solution: a `workflow_dispatch` run can supersede a `pull_request` run there, and a run that lists no check yet is invisible to it.

## Related Issues

- #1595 (closed by #1599): the owner parked on CI cancelled by its own body edit.
- #1636 (closed by #1651): after #1599, five owner reads still kept superseded cancelled rows, most likely through an incomplete workflow-runs listing; a read that leaves an Actions suite unclaimed is now a failed read.
- #1558 (closed not planned 2026-10-17 as moot once #1873 removed the owner; reopen only if it reappears in session-mode `pro-gate-loop.sh`): the `fixer-no-change` park. #1599 fixed the stale-row trigger. The general no-change-fixer re-read/grace behavior remains outside #1703's bounded infrastructure-stall repair; automatic reruns are no longer universally unimplemented.
- #1668 (closed by #1703): both owner merge modes can request up to two strictly classified failed-only reruns at the same merge-candidate head before their original failure fallback. This does not change the shared selector or resolve #1558 as a whole.
- #1388 (open): gate-check's last-row-per-name selection and argument-size transport. gate-check now reads through the filter.
- #1598 (closed by #1612): Harness Tests runs its suites once per ready head, which removes the draft-time run that leaves a stale pass on dotfiles itself. #1612 also put the Stop hook's rollup read behind `currentRollup`.
- `harness/ci-fleet-topology.md`: runs a push supersedes, the different-SHA case.
