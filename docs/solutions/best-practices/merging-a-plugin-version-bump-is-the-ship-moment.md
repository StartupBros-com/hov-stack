---
title: "Merging a plugin version bump is the ship moment: merged, tagged and staged is not reviewed"
date: "2026-10-17"
category: best-practices
module: plugin-release-review-gate
problem_type: best_practice
component: development_workflow
severity: high
resolution_type: workflow_improvement
applies_when:
  - "A catalog plugin's VERSION-bump PR is about to merge, or just merged, and its range since the last published tag has no review receipt"
  - "An operator-named review (ce-code-review, review-adversarial-first, codex adversarial review) of that range has not finished yet"
  - "The code review has to run after the merge, because the PRs are already MERGED and the review skill's PR path refuses that state"
  - "A review of an already-tagged build confirms defects and the fix must ship without moving the tag"
symptoms:
  - "gh pr view <n> --json reviews,comments reports zero reviews and zero comments on a merged PR that added over a thousand lines"
  - "Every automated signal is green (tests, auto-release, staged draft) while the tagged build carries a defect a user hits on the first documented command"
  - "The review skill stops with 'PR is closed/merged; not reviewing' when handed the merged PR URL"
  - "A review finding arrives after the staged draft was repinned, published and announced, so it can only ship as the next patch"
tags: [release-train, code-review, staged-draft, ce-code-review, detached-worktree, repin-reconcile]
related_components:
  - hov-marketplace-repin-reconcile
  - auto-release-draft-first
---

# Merging a plugin version bump is the ship moment: merged, tagged and staged is not reviewed

## Context

On 2026-09-20 seven follow-up PRs from a harness vet landed the same afternoon and each got the inward lenses the harness requires for doctrine and hook changes. The two skill-tuner code PRs (#53 adapter isolation, #54 the `claude plugin eval` reader, 1,213 added lines between them) got none: no GitHub review and no review-skill run, because the session's brief was "knock out all PRs" and the merge was the finish line. Auto-release tagged the result v0.9.0 and staged a draft within seconds. When the operator asked whether any of it needed `/ce-code-review`, the answer was yes for exactly that pair, and the review returned "Ready with fixes" with five findings confirmed by an independent validator, three by running the code: the reader's text report printed the literal words "candidate vs baseline", two spellings of one result file bypassed its same-arm refusal, errored runs and a wrong `casesTotal` fed the verdict as clean scores, the new `neutral_ids` routing option had no test, and the `tune` skill's step 5 still pointed at the id-visible battery config its own doctrine said to avoid. None of this was visible from green CI (197 tests passed on that head), and the first symptom a user would have met was the first command in the README.

That incident ran on the old release train, which had two human steps after the tag: merge the repin card, dispatch "Publish staged release". The review landed while v0.9.0 was still a draft, so the fix replaced it before anyone published.

hov-marketplace#209 removed both human steps. The reconciler (`repin-reconcile`) now sees the staged draft, opens the bot's own pin-only repin PR, requests auto-merge on it once it proves the PR changes only the marketplace manifest, and publishes the draft the merged card pins. The publish fires the plugin's release train, which announces to `#tool-drops`. The recipe, which lives in the hov-marketplace repository (the plugin release recipe in its docs folder, not in this repo), says: "No step after the version-bump merge is human." and "To hold a release back, delete or re-draft it before the card lands, or disable `repin-reconcile`." Its step 1 says "Merging is the ship signal."

So merging the VERSION bump is the ship moment. A staged draft is now published after the reconciler's next scheduled run: that run opens its card, and the card's merge publishes it. Nothing wakes the reconciler when a draft is staged, and GitHub delays scheduled runs. On 2026-10-17 the hourly schedule ran 2.2 to 5.3 hours apart, so the wait runs from minutes to a few hours. hov-marketplace#210 raises the schedule to four ticks an hour, and dispatching `repin-reconcile` ships at once.

## Guidance

The review rule is the operator's merge-and-end ruling of 2026-10-17 (global instructions, "Worktree & Branch Lifecycle", bullet "Merge-and-end"): one `/pro-gate` review runs only when the diff touches billing, auth, migrations or CI (`.github/`, runner or workflow config); every other diff gets no review tier; `/review-adversarial-first`, `/ce-code-review` and `/codex:adversarial-review` run only when the operator names them. This doc adds no gate to that rule.

What it records is the consequence of the train. Merged, tagged and staged is not reviewed, and after the merge nothing in the train waits for a person. A review the operator names for a range only changes what ships if it finishes before the VERSION-bump merge. A finding that arrives later, as v0.9.0's did, arrives after publish under today's train and ships as the next patch.

Reviewing a range that is already merged has three mechanics worth knowing:

1. The review skill refuses merged PRs through its PR path (`state: MERGED -> stop`). Run it on the committed range instead: add a detached worktree of the reviewed repository at the tag's commit (`git worktree add --detach`, placed inside that repository's own worktrees directory, the one wt-new uses, so the write guard treats it as isolated), then run the skill's `base:` path with the previous release as the base. Stage `files.txt` and `full.diff` in the run directory and tell every reviewer the absolute checkout root plus `git -C <root>`, because subagents inherit the session cwd, which is the launchpad, not the checkout. The session's worktree tool cannot register another repository's worktree; the placement above is enough.
2. The result never moves a tag. Recovery is the next patch version: a VERSION bump plus release notes. Auto-release tags and stages it, and the reconciler repins to it, auto-merges the card and publishes. It also closes the repin PRs the new card superseded, which used to be a manual step (hov-marketplace#166 was closed by hand in the v0.9.1 case). To hold a release back before it ships, the recipe's path is to delete or re-draft the draft before the card lands, or to disable `repin-reconcile`.
3. The cross-model lane can be unavailable on the day. The Codex peer failed with a provider usage limit and no artifact; the recovery rules route that to the in-process adversarial reviewer, and Coverage says so. That is a degraded lens, not a skipped review.

After the publish, verify the announce from the exact Release-train run log, never from the workflow's conclusion: look for `"status":"announced"` versus `does not yet list` (recipe step 6). The local preflight, the release-notes checker and `git show` on the tagged blobs, is the related doc below.

## Why This Matters

The train is built so that a merge is the ship signal. Tag, stage, repin, card merge, publish and announce are all automatic now, so "merged" feels like "done", and every later signal (tag, draft, green Release workflow) confirms the feeling without adding evidence about the code. The one thing the train never runs is a review. Under the old train the two human steps left a window to catch a bad draft; that window is now only the wait for the reconciler's next scheduled run, minutes to a few hours, with nobody watching it. The cost of a review is one run; the cost of skipping it in September was a tagged build whose headline feature printed a placeholder string, and today the same miss would be a published, announced catalog entry that needs a patch release to fix.

## When to Apply

- Deciding whether to name a review for a plugin range: the decision point is before the VERSION-bump merge, because the merge is when it ships.
- A merged range with no review receipt whose behavior is user-facing (a CLI, a reader of external files, a doctrine an agent follows): review it with the detached-checkout `base:` path and ship any fix as the next patch.
- A review that has to happen after the merge: use that path rather than skipping because the PR path refuses.
- Not for the seven doctrine and fixture PRs that already carried refute-by-default lenses; the gap was the pair that had nothing.

## Examples

Before: `gh pr view 54 -R StartupBros-com/skill-tuner --json reviews,comments` returned `reviews=0 comments=0`; `gh release list` showed v0.9.0 as a draft; `tune.py compare --plugin-eval ... --delta 0.1` on the shipped fixture printed `- score paired across 3 cases (candidate vs baseline)`.

After: the review run directory holds `validator-verdicts.json` with five `confirmed` entries; v0.9.1 prints `(.../plugin-eval-aggregate-result.json@with vs .../plugin-eval-aggregate-result.json@without)` and refuses the same file spelled two ways; `gh release list` shows v0.9.1 as latest, v0.9.0 as a tag with no release, and the marketplace manifest pins 0.9.1. Issue skill-tuner#55 and PR #56 carried the fix.

Both outputs are history from the old train, where v0.9.0 was still a draft when the finding arrived. Under today's train the same finding would arrive after publish and ship as the patch.

The vet note that started the workstream records the correction under its Outcome section: `docs/vets/2026-09-20-claude-plugin-eval-harness-vet.md`.

## Related

- `run-the-release-notes-checker-locally-and-verify-tagged-blobs-with-git-show.md` (the other release preflight: confirm the tagged blob holds the fix)
- The plugin release recipe in the hov-marketplace repository's docs folder (the current train and its hold-back path; not in this repo)
- hov-marketplace#209 (automated the repin merge and the publish)
- Memory: `ce-code-review-merged-range-via-detached-checkout`, `auto-release-stages-a-draft-from-the-first-version-bump-merge`
