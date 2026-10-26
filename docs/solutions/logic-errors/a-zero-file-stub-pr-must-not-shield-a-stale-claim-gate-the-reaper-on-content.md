---
title: "A zero-file stub PR must not shield a stale claim; gate the reaper on content, not existence"
date: 2026-09-28
category: logic-errors
module: claim-reap-content-gate
problem_type: logic_error
component: development_workflow
severity: high
symptoms:
  - "A stale claim (an issue labelled `claimed` past its 48h TTL) stayed shielded forever because any open PR referencing the issue counted as evidence of life, even a zero-file draft opened only so CI could run"
  - "Four zero-file draft PRs opened on 2026-09-08 (dotfiles #1075, #1081, #1082, #1083) shielded their claims for over 489 hours while nobody worked them"
  - "A draft PR going green within seconds of its first push, with a +0/-0 diff, was the empty start commit's CI run, not evidence of work"
  - "Once the draft PR was deferred to the branch's first content push, 'no open PR' stopped meaning abandoned, so existence was the wrong signal in both directions"
root_cause: logic_error
resolution_type: code_fix
related_components:
  - "claim-reap.sh"
  - "wt-new.sh"
  - "pr-open-if-missing.sh"
  - "gh-dedup-check.sh"
tags: ["claim-reap", "stub-pr", "liveness-signal", "content-gate", "worktree", "github-pr", "wt-new", "fail-closed"]
---

# A zero-file stub PR must not shield a stale claim; gate the reaper on content, not existence

> **Retired machinery (2026-10-18).** `claim-reap.sh`, the dedup pre-flight
> and the issue-claim `Released:` protocol were removed in dotfiles #1900 and
> #1902 (fleet teardown moves 7a and 7b). The `claim-reap.sh` and `wt-new.sh`
> line citations below describe the code as of PR #1440 and no longer
> resolve; the content-over-existence reasoning is unchanged.

## Problem

dotfiles' stale-claim reaper (`scripts/claim-reap.sh`) shielded a claimed
GitHub issue from release as long as any open PR referenced it, and treated "no
open PR" as abandoned. Because `wt-new.sh` used to open every draft PR on an
empty start commit so CI could run, a zero-file stub PR satisfied the
"open PR exists" test forever without ever doing the work the claim was for.

## Symptoms

- A `changedFiles: 0` draft PR going green within seconds of push, diff `+0/-0`,
  was the trivial empty-start-commit shape, not evidence of real work
  (per this session's conclusion, corroborated by `scripts/wt-new.sh`
  no longer creating that commit at all; see Solution).
- Per this session's report, four such stubs opened 2026-09-08 (dotfiles PRs
  #1075, #1081, #1082, #1083) lived past 489 hours, each shielding a claimed
  issue that nobody was working.
- `harness/gh-tracking-and-claims.md:253-254` documents a related live
  case: "two PRs carrying only the year 2026 shielded the members app's issue #2026 for 17
  days". GitHub's PR search loose-matches bare numbers, so a PR that merely
  contained the digits of an issue number, unrelated to it, could shield a
  claim the same way an empty stub could.
- Net effect: a starved claim pool. Issues stayed labelled `claimed` while no
  session was actually working them, and nothing in the reaper consulted the
  `Released:` marker convention (`scripts/wt-new.sh:68`) because
  nothing ever posted one: the existence check never failed, so release
  never fired.

## What Didn't Work

- **Shield on PR existence.** Any open PR, regardless of content, kept the
  claim alive. This is exactly the bug: a PR is an artifact the harness itself
  mints for process reasons (so CI has something to run against), not proof
  that the referenced work happened.
- **Treat "no open PR" as abandoned.** Once `wt-new.sh` was changed to defer
  opening the draft PR to the branch's first content push
  (`scripts/wt-new.sh:673`, `scripts/pr-open-if-missing.sh`),
  a claim with real, unpushed local work but no PR yet would have looked
  identical to an abandoned one under the old rule. Existence in either
  direction (PR present, PR absent) stopped being a valid signal.
- **The same confusion, failing the other way (session history).** On
  2026-08-27 a one-line change to the draft-PR body `wt-new.sh` generates,
  from `Closes #N` to `Refs #N` (PR #486), left finished work's issue open
  because the reaper only removes the `claimed` label and never closes an
  issue itself; the reaper then released the finished issue as stale and the
  dispatcher re-dispatched it. It was reverted the same session (PR #488) and
  PR #482 made the closing keyword an explicit caller choice. Existence of a
  label or a PR was already a bad proxy for "work is happening" a month
  before the stub-PR case, in the opposite direction.
- **Count commits, not files, as content.** `claim-reap.sh:23` calls out AE5:
  "a two-commit zero-diff PR still reaps". An empty commit is a commit, so
  counting commits would have let a stub PR pad itself with no-op commits and
  keep shielding forever.
- **Dedup repo clones by returning early from the second clone.** A linked git
  worktree is registered in exactly one clone's `git worktree list` registry
  (`scripts/claim-reap.sh:130-137`, the comment above
  `local_work_on_branch`). An earlier version deduped by GitHub slug and only
  consulted the first clone found, which hid a second clone's dirty or ahead
  worktree and let its PR reap out from under live local work (pro-gate P1 on
  PR #1440, pinned by test cases `x1`/`x2` at
  `tests/claim-reap.test.sh:754-788`).
- **Release an all-reap claim without reading its recorded `Branch:`.** A
  claim's only open PR can be an old stub on a branch the session already
  moved away from, while the branch actually recorded in the claim comment
  carries live work in a worktree or on origin. Releasing as soon as every
  listed PR reaped, without checking that recorded branch, would have
  released a claim with real unshipped work (pro-gate P1 on PR #1440, pinned
  by `w1` to `w4` at `tests/claim-reap.test.sh:701-752`).
- **Match bare `#N` substrings.** GitHub's PR search loose-matches numbers
  (the members-app case above, and a live case recorded at
  `scripts/claim-reap.sh:338-339` where `"#143 in:body"` matched an IP
  octet `203.0.113.143`). Matching on substring let a foreign repo's `#N`, or
  an unrelated number, shield or reap under this claim's name (pro-gate P1 on
  PR #1440, pinned by `v5a`/`v5b` at `tests/claim-reap.test.sh:677-696`).

## Solution

The reaper now rules on content everywhere it used to rule on existence
(PR #1440, merged 2026-09-28; the empty start commit itself was removed by
PR #1436).

Per open PR referencing the claim (`scripts/claim-reap.sh:378-390`):

| Verdict | Gate |
|---|---|
| `shield-content` | `changedFiles > 0`, the sole content gate |
| `shield-age` | zero files, but younger than `CLAIM_TTL_HOURS` (default 48) |
| `flag-local` | zero files, past grace, and a worktree in any clone on this host is ahead of the PR head or dirty: real work GitHub cannot see; never closed |
| `reap` | zero files, past grace, no local work: the PR gets a rollback comment naming `gh pr reopen N`, then is closed; the branch is left untouched |

Per claim, the aggregate (`scripts/claim-reap.sh:395-435`, and for the
no-PR path `:441-467`):

| Verdict | Gate |
|---|---|
| `released` | every open PR reaped, and the recorded `Branch:` (when none of those PRs carried it) has no local or remote work; or no open PR and the recorded branch has neither |
| `kept` | at least one PR shields by content or age |
| `flag-local` | no shield, but a head branch or the recorded `Branch:` has a dirty or ahead worktree on this host |
| `flag-remote` | no shielding PR, and the recorded `Branch:` has changed files ahead of the default branch on origin |

The header states the rule at `scripts/claim-reap.sh:16-18`:

```
# VERDICTS ... Content, not existence, shields
# a claim: the issue-first wt-new.sh opens a draft PR only on the branch's first
# content push, and a zero-file PR is the immortal-stub shape this exists to end.
```

Supporting mechanics:

- **Release marker before label removal.** `release_claim()` posts the
  `Released:` issue comment first and only removes the `claimed` label if
  that comment succeeded (`scripts/claim-reap.sh:189-207`), matching
  the protocol `wt-new.sh`'s `is_live($rels)` jq predicate consults
  (`scripts/wt-new.sh:361`). A label removed without the marker starves
  re-claims until the TTL expires: observed on the claim for dotfiles#676,
  reported as issue #688 and fixed by PR #700 on 2026-08-30, which decided
  the marker-first ordering this rewrite preserves (session history).
- **Every-clone worktree walk.** `local_work_on_branch()` iterates every
  checkout collected for a slug (`SLUG_REPOS`), not just the first one found,
  because a linked worktree lives in one clone's registry only
  (`scripts/claim-reap.sh:130-152`).
- **This-repo token filter.** PRs are kept in a claim's loop only when they
  name this repo's `#N` at a token boundary, or `owner/repo#N` /
  `github.com/owner/repo/issues/N` qualified to this slug
  (`scripts/claim-reap.sh:346-353`).
- **All-reap `Branch:` check.** When every listed PR reaps, `rule_on_branch()`
  is run on the claim's recorded branch before any release, exactly as a
  PR-less claim is ruled (`scripts/claim-reap.sh:404-417`).
- **Fail closed on read failure.** A failed `gh` call, unreadable comment or
  timestamp, non-numeric `changedFiles`, a PR list that fills
  `PR_SEARCH_LIMIT`, or a non-404 compare failure skips the claim with a WARN
  and leaves counters untouched (`scripts/claim-reap.sh:410-411`,
  `:445-446`, referencing dotfiles#395).

Live verification: per this session's report, a `DRY_RUN=0` run on
2026-09-28 closed the four stub PRs and released 49 claims across 9 repos,
with all 54 verdict lines identical to a prior `DRY_RUN=1` run at the same
head (0 flagged, 0 WARN): the byte-identical-verdicts property the header at
`scripts/claim-reap.sh:48` asserts by design.

## Why This Works

The root cause was an existence test applied to an artifact the harness
itself creates for process reasons. `wt-new.sh` opens a draft PR so CI has
something to run against, not because work happened, so "a PR exists" can
never be evidence that work happened, no matter how the artifact is
generated. The only things that constitute evidence are changed files on
GitHub (`changedFiles`, read straight from `gh pr view`/`gh pr list`, not
inferred from commit count or CI status), and local or remote work outside
GitHub's view (a worktree ahead or dirty in some clone, or a branch ahead of
default on origin). Both are checked directly, not proxied through an
artifact's presence. Reaping only closes the PR and never touches the branch
(`reap_pr()`, `scripts/claim-reap.sh:230-259`, and the comment posted
on close names `gh pr reopen N`), so a reap is reversible: any real work that
was somehow missed is still sitting on the branch and can be reopened into
review, rather than being destroyed by the reaper's own mistake.

## Prevention

For any reaper, sweeper, dedup check, or liveness test that consults GitHub
or local worktrees to answer "is this being worked on":

- **Gate on `changedFiles`, not commit count or PR/issue existence.** An
  empty commit is still a commit; a stub PR is still an open PR. Read the
  diff, not the artifact's presence (`scripts/claim-reap.sh:378-381`).
- **Walk every clone's worktree registry, not just the first one found when
  deduping by repo identity.** A linked worktree is registered in exactly
  one clone (`scripts/claim-reap.sh:130-137`, pinned by tests `x1`/`x2`).
- **Match issue and PR references to the exact target repo**, not a bare
  number: GitHub's search API loose-matches digits anywhere in title, body,
  and branch name (pinned by tests `v5a`/`v5b`).
- **Post a release or completion marker before removing any label or status**
  that another process treats as the liveness signal, so a failure between
  the two steps degrades to "still claimed", never to "silently
  unreclaimable" (`scripts/claim-reap.sh:189-207`).
- **Fail closed on any truncated list, timeout, or unreadable field.** A
  fabricated "found nothing" is the exact input that authorizes an unsafe
  release or close; skip the item instead (dotfiles#395, applied throughout
  `scripts/claim-reap.sh` and mirrored in
  `scripts/gh-dedup-check.sh:118-124`).
- **Keep a `DRY_RUN=1` run in the verification ledger and diff its verdict
  lines against the `DRY_RUN=0` run at the same head** before trusting a new
  content-based rule; the header (`scripts/claim-reap.sh:48`) makes
  byte-identical verdict lines a design invariant specifically so this
  comparison is possible.
- **`scripts/gh-dedup-check.sh` was the next consumer with this gap**
  when this was written (retired with the claim pre-flight in dotfiles #1902);
  the lesson stands for any similar scan.
  Its local-branch scan only checks one root, either `ROOT` (default
  `$HOME/SITES`) or a single `--checkout` path
  (`scripts/gh-dedup-check.sh:29`, `:86-89`), and never walks multiple
  clones under multiple roots the way `claim-reap.sh`'s
  `local_work_on_branch()` did, so a second clone's local branch for the
  same issue number was not found.

## Related Issues

- dotfiles #1428: the work-spec issue; implemented by PR #1436 (issue-first
  claims, the draft PR deferred to the first content push) and PR #1440 (the
  reaper rules on content; flagged claims reach the weekly toast). Plan:
  `docs/plans/2026-09-27-2139-feat-issue-first-claims-content-reap-plan.md`.
- dotfiles #688 / PR #700: the release-marker race this rewrite builds on.
- dotfiles #1449: the timer follow-up, closed 2026-09-28 by PR #1455, which
  added `claim-reap.timer` (`DRY_RUN=0`, Mondays at 08:30, withheld from
  auto-enable and enabled per host). The reaper and its timer were retired
  with the issue-claim system in dotfiles #1902 (2026-10-18).
- `docs/solutions/logic-errors/a-run-ledgers-mtime-is-not-a-liveness-signal-for-an-idle-dispatcher.md`:
  the same shape in another subsystem, a proxy artifact mistaken for the real
  state.
- `docs/solutions/logic-errors/search-results-must-not-feed-the-search-corpus.md`:
  the admission-time half of the same claim pipeline (`gh-dedup-check.sh`),
  a different defect.
- `docs/solutions/logic-errors/fail-closed-gate-on-monotonically-degrading-input-becomes-a-permanent-latch.md`:
  another self-latching gate, unrelated mechanism.
- `docs/solutions/integration-issues/agent-view-refuses-to-close-squash-merged-worktrees.md`:
  the closeout half of the worktree lifecycle, sharing the rule that an answer
  which could not be obtained is never read as a yes.
