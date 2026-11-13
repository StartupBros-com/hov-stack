---
title: "Merging a plugin version bump is the ship moment: merged, tagged and staged is not reviewed"
date: "2026-10-17"
last_updated: "2026-11-13"
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
  - "A PR's manifest entry pins a release that is still a draft, as a plugin's first listing does, so the merge publishes it and posts its Tool Drop card to members"
  - "A VERSION bump's release notes carry `## Highlights` bullets between 141 and 180 characters"
symptoms:
  - "gh pr view <n> --json reviews,comments reports zero reviews and zero comments on a merged PR that added over a thousand lines"
  - "Every automated signal is green (tests, auto-release, staged draft) while the tagged build carries a defect a user hits on the first documented command"
  - "The review skill stops with 'PR is closed/merged; not reviewing' when handed the merged PR URL"
  - "A review finding arrives after the staged draft was repinned, published and announced, so it can only ship as the next patch"
  - "`check-release-notes.sh` prints `release notes OK` for Highlights bullets that the members' Tool Drop card cuts at 140 characters"
  - "The go that releases a card-posting merge was given before the card lines reached their final wording"
tags: [release-train, code-review, staged-draft, ce-code-review, detached-worktree, repin-reconcile, tool-drop-card, release-notes, highlights, marketplace-listing, member-facing-copy]
related_components:
  - hov-marketplace-repin-reconcile
  - auto-release-draft-first
---

# Merging a plugin version bump is the ship moment: merged, tagged and staged is not reviewed

## Context

On 2026-09-20 seven follow-up PRs from a harness vet landed the same afternoon and each got the inward lenses the harness requires for doctrine and hook changes. The two skill-tuner code PRs (#53 adapter isolation, #54 the `claude plugin eval` reader, 1,213 added lines between them) got none: no GitHub review and no review-skill run, because the session's brief was "knock out all PRs" and the merge was the finish line. Auto-release tagged the result v0.9.0 and staged a draft within seconds. When the operator asked whether any of it needed `/ce-code-review`, the answer was yes for exactly that pair, and the review returned "Ready with fixes" with five findings confirmed by an independent validator, three by running the code: the reader's text report printed the literal words "candidate vs baseline", two spellings of one result file bypassed its same-arm refusal, errored runs and a wrong `casesTotal` fed the verdict as clean scores, the new `neutral_ids` routing option had no test, and the `tune` skill's step 5 still pointed at the id-visible battery config its own doctrine said to avoid. None of this was visible from green CI (197 tests passed on that head), and the first symptom a user would have met was the first command in the README.

That incident ran on the old release train, which had two human steps after the tag: merge the repin card, dispatch "Publish staged release". The review landed while v0.9.0 was still a draft, so the fix replaced it before anyone published.

hov-marketplace#209 removed both human steps. The reconciler (`repin-reconcile`) now sees the staged draft, opens the bot's own pin-only repin PR, requests auto-merge on it once it proves the PR changes only the marketplace manifest, and publishes the draft the merged card pins. The publish fires the plugin's release train, which announces to `#tool-drops`. The recipe, `docs/release/plugin-release-recipe.md` (in this repository, which hov-marketplace became when it was renamed hov-stack), says: "Merging the version bump is the ship moment. No step after it is a human step". Its "Holding a release back" section says a release is held back only while its card has not landed.

So merging the VERSION bump is the ship moment. Since hov-stack#456 (merged 2026-11-06) a finished Release run wakes the reconciler, which opens the card at once; the card merges when its required checks pass, and the push that merge makes publishes the draft. pro-gate v0.65.6 went from staged draft (15:48Z) to published (16:16Z) in 28 minutes on 2026-11-06, with no hand dispatch. Before #456 nothing woke the reconciler when a draft was staged, so the wait was the delayed schedule, from minutes to a few hours (on 2026-10-17 the hourly schedule ran 2.2 to 5.3 hours apart). The four-ticks-an-hour schedule from hov-marketplace#210 is now the fallback.

A first listing is the same ship moment. hov-stack#563 (merged 2026-11-13T06:08:38Z) added hov's first marketplace entry, pinned at `hov--v0.1.7`, a release that was still a draft. The push from that merge ran the reconciler. Its "Publish staged releases the card on main already pins" step logged `published now hov: hov--v0.1.7 (releaseId 443845890)` at 06:09:42Z (Repin reconcile run 43376647853), and publishing fired the release train, which announces a release to members as a Tool Drop card (release-train run 43376768315 started at 06:09:44Z and logged `"status":"announced"`). No human step sat between the merge and that announce, so the merge was also the send of member-facing copy. The PR's body opened with "Merging this publishes hov 0.1.7 to members and posts its Tool Drop card. Hold it until the operator OKs the card preview." By the shipping session's account, the operator's first go came before they had seen the card lines in their final wording. The session turned auto-merge off (`auto_merge_disabled` at 05:57:42Z on the PR timeline), filed #564 under the `external-send` category of `scripts/escalation-exceptions.json`, showed the final lines, and merged on the next go.

The same release showed that the checks here pass Highlights the card cuts. Per #563's body, the card has a "140-character cut". The members site's renderer (in that site's repository, not this one) strips markdown, links, mentions, list markers, conventional-commit prefixes and a trailing `(vX.Y.Z)` from each `## Highlights` bullet. It then cuts the bullet at 140 graphemes with the ellipsis inside the 140 (`WHATS_NEW_MAX_BULLET_CHARS = 140`) and shows at most three bullets. This repository allows 180 instead: `release/scripts/check-release-notes.sh:106` fails a bullet only above 180 UTF-16 units, `release/scripts/tool-drop-announce.sh:170` cuts at 180, and the recipe says "at most 180 characters each" (`docs/release/plugin-release-recipe.md:385`). hov 0.1.7's three Highlights in `plugins/hov/docs/release-notes/v0.1.7.md` are 164, 152 and 160 characters after that stripping. The checker passes them with `release notes OK`, and by its code the renderer would cut all three. #563's body records that the lines "were shortened in the draft body", and the published release body's lines are 137, 140 and 140 characters. The tagged notes file kept the longer wording, so the published release body and the notes file differ on purpose.

Those are the Tool Drop card's "What's new" lines. The marketplace card's own copy (`card.tagline`, `card.rows`, `card.run`) is a different field with the manifest validator's limits, 1-180 characters for each row (`docs/release/plugin-release-recipe.md:351`). The 140 cut applies to Highlights only.

## Guidance

The review rule is the operator's merge-and-end ruling of 2026-10-17 (global instructions, "Worktree & Branch Lifecycle", bullet "Merge-and-end"): one `/pro-gate` review runs only when the diff touches billing, auth, migrations or CI (`.github/`, runner or workflow config); every other diff gets no review tier; `/review-adversarial-first`, `/ce-code-review` and `/codex:adversarial-review` run only when the operator names them. This doc adds no gate to that rule.

What it records is the consequence of the train. Merged, tagged and staged is not reviewed, and after the merge nothing in the train waits for a person. A review the operator names for a range only changes what ships if it finishes before the VERSION-bump merge. A finding that arrives later, as v0.9.0's did, arrives after publish under today's train and ships as the next patch.

The same holds for the card text. A merge that publishes a release also posts member-facing copy, and the merge is the last point where that copy can change. Two consequences follow, and neither is a new gate:

- When a go is what releases such a merge, ask for it with the card lines in their final wording, as they will render: at most three, each 140 characters or under after stripping. A go given before a wording change does not cover the new wording. If auto-merge is already on when the wording changes, turn it off until a go covers the final lines. A session that cannot wait holds the merge with a needs-human `external-send` issue, as #564 did.
- Fix the length in the notes file, in the bump PR. Keep each Highlights bullet at 140 characters or under after the card's stripping until `check-release-notes.sh` enforces that itself. Editing the draft body, as 0.1.7 did, works only while the merge is held. On a routine bump the reconciler publishes with nobody reading the draft first; pro-gate v0.65.6 went from staged draft to published in 28 minutes. Lowering the checker to 140 tightens the rule for every plugin author, and this doc does not make that decision.

Reviewing a range that is already merged has three mechanics worth knowing:

1. The review skill refuses merged PRs through its PR path (`state: MERGED -> stop`). Run it on the committed range instead: add a detached worktree of the reviewed repository at the tag's commit (`git worktree add --detach`, placed inside that repository's own worktrees directory, the one wt-new uses, so the write guard treats it as isolated), then run the skill's `base:` path with the previous release as the base. Stage `files.txt` and `full.diff` in the run directory and tell every reviewer the absolute checkout root plus `git -C <root>`, because subagents inherit the session cwd, which is the launchpad, not the checkout. The session's worktree tool cannot register another repository's worktree; the placement above is enough.
2. The result never moves a tag. Recovery is the next patch version: a VERSION bump plus release notes. Auto-release tags and stages it, and the reconciler repins to it, auto-merges the card and publishes. It also closes the repin PRs the new card superseded, which used to be a manual step (hov-marketplace#166 was closed by hand in the v0.9.1 case). To hold a release back before it ships, use the recipe's "Holding a release back" levers before the card lands. Their order matters: turn the reconciler off and close the open card before deleting the draft, because a queued auto-merge still merges and pins a release that no longer exists.
3. The cross-model lane can be unavailable on the day. The Codex peer failed with a provider usage limit and no artifact; the recovery rules route that to the in-process adversarial reviewer, and Coverage says so. That is a degraded lens, not a skipped review.

After the publish, verify the announce from the exact Release-train run log, never from the workflow's conclusion: look for `"status":"announced"` versus `does not yet list` (recipe step 6). The local preflight, the release-notes checker and `git show` on the tagged blobs, is the related doc below.

## Why This Matters

The train is built so that a merge is the ship signal. Tag, stage, repin, card merge, publish and announce are all automatic now, so "merged" feels like "done", and every later signal (tag, draft, green Release workflow) confirms the feeling without adding evidence about the code. The one thing the train never runs is a review. Under the old train the two human steps left a window to catch a bad draft; that window is now the Release run's wake-up plus the card's required checks, 28 minutes for pro-gate v0.65.6, with nobody watching it. The cost of a review is one run; the cost of skipping it in September was a tagged build whose headline feature printed a placeholder string, and today the same miss would be a published, announced catalog entry that needs a patch release to fix. The card is the one output of the train that members read, and the checker's `release notes OK` does not mean its lines render whole.

## When to Apply

- Deciding whether to name a review for a plugin range: the decision point is before the VERSION-bump merge, because the merge is when it ships.
- A merged range with no review receipt whose behavior is user-facing (a CLI, a reader of external files, a doctrine an agent follows): review it with the detached-checkout `base:` path and ship any fix as the next patch.
- A review that has to happen after the merge: use that path rather than skipping because the PR path refuses.
- Not for the seven doctrine and fixture PRs that already carried refute-by-default lenses; the gap was the pair that had nothing.
- A PR whose manifest entry pins a release that is still a draft, such as a plugin's first listing: the merge publishes it and posts its card.
- Writing or reviewing a VERSION bump's release notes: count each Highlights bullet against the card's 140, not the checker's 180.

## Examples

Before: `gh pr view 54 -R StartupBros-com/skill-tuner --json reviews,comments` returned `reviews=0 comments=0`; `gh release list` showed v0.9.0 as a draft; `tune.py compare --plugin-eval ... --delta 0.1` on the shipped fixture printed `- score paired across 3 cases (candidate vs baseline)`.

After: the review run directory holds `validator-verdicts.json` with five `confirmed` entries; v0.9.1 prints `(.../plugin-eval-aggregate-result.json@with vs .../plugin-eval-aggregate-result.json@without)` and refuses the same file spelled two ways; `gh release list` shows v0.9.1 as latest, v0.9.0 as a tag with no release, and the marketplace manifest pins 0.9.1. Issue skill-tuner#55 and PR #56 carried the fix.

Both outputs are history from the old train, where v0.9.0 was still a draft when the finding arrived. Under today's train the same finding would arrive after publish and ship as the patch.

The vet note that started the workstream records the correction under its Outcome section: `docs/vets/2026-09-20-claude-plugin-eval-harness-vet.md`.

First listing, 2026-11-13: #563's timeline shows `auto_merge_disabled` at 05:57:42Z and the merge at 06:08:38Z. #564 (`needs-human: External message send (PR #563)`) closed at 06:07:15Z, and Repin reconcile run 43376647853 logged the publish at 06:09:42Z. `bash release/scripts/check-release-notes.sh plugins/hov/docs/release-notes/v0.1.7.md` prints `release notes OK` for Highlights of 164, 152 and 160 characters, counted after the card's stripping (the third is 162 before it). The published release body's lines are 137, 140 and 140 characters.

## Related

- `run-the-release-notes-checker-locally-and-verify-tagged-blobs-with-git-show.md` (the other release preflight: confirm the tagged blob holds the fix)
- `docs/release/plugin-release-recipe.md` (the current train and its hold-back levers; its Highlights rule still says 180)
- `automate-a-release-step-by-converging-on-observed-state-and-re-reading-before-publish.md` (how the reconciler lands the card and publishes, the chain that ends in the member card)
- `serving-plugins-from-a-monorepo-with-git-subdir-marketplace-entries.md` (the `git-subdir` manifest entries a listing adds)
- hov-marketplace#209 (automated the repin merge and the publish)
- Memory: `ce-code-review-merged-range-via-detached-checkout`, `auto-release-stages-a-draft-from-the-first-version-bump-merge`
