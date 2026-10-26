---
title: "Automate a human release step by converging on observed state, and re-read live state right before the irreversible write"
date: "2026-10-17"
category: best-practices
module: hov-marketplace-repin-reconcile
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "Replacing a human step in a release or deploy chain (merging a generated PR, publishing a draft, flipping a flag) with a scheduled or triggered job"
  - "A job decides from a snapshot it read earlier in the run, then performs a write that cannot be taken back (publish, announce, tag, merge)"
  - "Matching a GitHub App's pull requests or comments by author login"
  - "A reviewer asserts an API field's exact spelling or shape with confidence, and the fix depends on it"
retire_when: "hov-marketplace stops landing and publishing from its reconciler (repin-reconcile.yml no longer runs scripts/repin-land.sh and scripts/repin-publish.sh)"
tags: [release-train, repin-reconcile, idempotency, toctou, github-app, gh-cli, auto-merge, staged-draft]
related_components:
  - hov-marketplace-repin-reconcile
  - auto-release-draft-first
---

# Automate a human release step by converging on observed state, and re-read live state right before the irreversible write

## Context

Until hov-marketplace#209 (merged 2026-10-18 UTC), the plugin release train stopped twice for a person after the tag. Someone merged the bot's repin PR, the marketplace card that pins the new release. Then someone dispatched "Publish staged release" for the draft. Only the merge was ever automated, and only briefly: the pr-owner fleet merged bot repin PRs on their checks from dotfiles#1834 until dotfiles#1873 retired the fleet on 2026-10-17. Nothing ever automated the publish. After the retirement every pro-gate VERSION bump ended as a draft; v0.65.0 sat unpublished while its repin PR (hov-marketplace#206) was clean and unmerged.

The human step had already failed in other ways (session history, 2026-10-14 to 10-15):

- The v0.63.2 repin (hov-marketplace#201) was handed to a PR owner whose terminal Pro review ran on the installed 0.62.0 runtime. That runtime rejected a grounded answer because of the very bug 0.63.x fixed. A release that fixes the reviewer cannot be promoted through a review by that reviewer. The operator then ruled that bot repin PRs merge on the ruleset's required checks with no Pro round, provided the diff is only the card tuple (dotfiles#1832).
- A session cited repin #199 as precedent for "repin PRs merge on checks alone". It was wrong: #198 had carried a clean adversarial round and a Pro SHIP. The rulesets API (`rules/branches/main`) and the PR's comment history settled it.
- hov-marketplace#202's review raised a P2: the recipe now told people to merge repin PRs without a review, while the workflow header still gave a security reason for "a reviewed PR". The header of `.github/workflows/repin-reconcile.yml` now carries the reconciled reason. The bot App has contents and pull-request write on that repository only. Auto-merge is requested only after `scripts/repin-land.sh` proves the diff. The merge still waits for the required checks and every ruleset on main.
- Promotion waited for someone to notice a draft. No token without push access can even list a draft (hov-marketplace#168).

#209 put both steps into the scheduled reconciler. Its design, and the one Pro round on it, produced the three lessons below. What the merge now means for review is a separate doc (Related) and is not repeated here.

## Guidance

Every file path in this doc is in the hov-marketplace repository, as of the #209 merge; none is in this repo.

### 1. Converge on observed state; do not chain events

An event chain (merge fires tag, tag fires stage, a person fires publish) cannot be re-run safely, so it grows defences against retrying instead of making a retry harmless. #209 moved both steps into a reconciler, and each run follows the same loop:

1. Read the current state.
2. Compute the card that state calls for.
3. Act only on the difference.

The reconciler runs on a schedule (cron `23 * * * *` at #209; four ticks an hour, `8,23,38,53 * * * *`, since hov-marketplace#210 merged on 2026-10-18), on a push to main that touches `.claude-plugin/marketplace.json`, and on manual dispatch. Each of its actions is built so that a second run is a no-op:

- **Content-addressed branch.** The repin branch is `repin/auto-<key>`, where the key is the first 12 hex of sha256(plan, main's HEAD sha). The reconcile step in `repin-reconcile.yml` computes it. The same drift on the same main always gives the same branch, so a second run finds the PR already open and opens nothing. Main's sha is in the key because the required checks demand an up-to-date branch. Once main moves, the old PR can never merge, so the next run opens a fresh one.
- **Merge only what you can prove you produced.** `scripts/repin-land.sh` requests auto-merge only on an open PR whose head branch starts with `repin/auto-`, that the bot App opened, that is not cross-repository, that changes exactly `.claude-plugin/marketplace.json`, and whose manifest blob at the PR head equals the blob this run computed (`EXPECTED_BLOB`). It runs `gh pr merge --auto --squash --match-head-commit <head>`, so the merge is pinned to the proven head and still waits for every check and ruleset. A PR already queued for auto-merge is left alone.
- **Close what the new state supersedes.** The same script closes every other bot repin PR, with a comment, and deletes its branch. With no drift it closes all of them. Merging an older repin after a newer one would downgrade the card. hov-marketplace#130 asked for this closing step and was still open on 2026-10-17.
- **Publish only what main pins.** `scripts/repin-publish.sh` touches only the release that a card pins by `releaseId`. It re-checks everything the per-repository publish workflow checked: the tag, the version, the tag commit, and that the commit is on the default branch. It also waits while assets are still uploading, publishing only when every asset is uploaded and the count is at least the last published release's. A superseded or abandoned draft can never match a card, so it is left alone.

### 2. Re-read live state right before the irreversible write

The publish step reads main's manifest at the commit the run checked out (`git show "${GITHUB_SHA}:.claude-plugin/marketplace.json"`). By the time the PATCH that publishes a draft runs, that snapshot can be stale: a newer repin, or a revert that holds a release back, may have merged since the run started. A publish cannot be taken back. It fires the plugin's release train, which announces to `#tool-drops`. A stale snapshot can therefore publish and announce a release the catalog no longer pins. This was the valid P1 from #209's Pro round, and #209 fixed it before merging.

`repin-publish.sh` now does four things just before the PATCH:

1. It re-reads the card from live `main` with the marketplace repository's own token (`MARKETPLACE_TOKEN`, the workflow's `github.token`).
2. It compares only the pin tuple, the fields the publish depends on: source url, source sha, version, release tag and release id.
3. It treats a **mismatch as a normal skip**. It prints `skip <name>: main no longer pins <tag>` and returns 0.
4. It treats a **read failure as an error**. It returns 1, and the run goes red.

Only then does it publish with the release App token (`GH_TOKEN`), and it fails if the response still says `draft: true`.

The general pattern has three parts:

- If you must decide from a snapshot, re-read the one fact the write depends on immediately before the write.
- Keep "the state changed" (skip, quietly) apart from "the state could not be read" (fail, loudly). A silent skip on a read error hides a broken train. A publish on a read error publishes blind.
- Compare only what the write depends on (here the pin tuple, not the whole manifest).

### 3. Match a GitHub App's PR author in both spellings

gh CLI reports a GitHub App's PR author as `app/<slug>`; the REST API reports the same account as `<slug>[bot]`. Live on 2026-10-17:

- `gh pr list --json author` for hov-marketplace#206 and #207 gave `app/startupbros-hov-marketplace-bot`, with `is_bot: true`.
- The REST pull-request payload for #207 gave `user.login: startupbros-hov-marketplace-bot[bot]`, `type: Bot`.

The Pro round on #209 said, with high confidence, that the `app/` login could never match. One live `gh pr list --json author` payload refuted that P1. `repin-land.sh` accepts both spellings (`.author.login == "app/\($slug)" or .author.login == "\($slug)[bot]"`). It takes the slug from the `app-slug` output of `actions/create-github-app-token`, not from a hard-coded name.

When a reviewer, human or model, asserts the exact spelling of an API field, one live payload settles it faster than a search through the docs. Whatever the payload shows, the match should accept every spelling the tools you call can return.

### Verified on the first release through #209 (pro-gate v0.65.2, 2026-10-18)

#209 is not a Pro pass. Its one round ended FIX-FIRST: the snapshot P1 was fixed, the author P1 was refuted, and the fixes were not reviewed again. The smoke run on the merge commit (no drift) proved only the wiring: both App tokens were minted, the bot slug resolved, land closed 0 PRs, and publish printed 11 `published` lines and 0 `published now`.

pro-gate v0.65.2 (pro-gate#301, merged at about 07:02Z) then went through the merge and publish paths. Its draft was staged by about 07:14Z. No scheduled reconciler run came (see below), so `repin-reconcile.yml` was dispatched by hand at 08:44:20Z. From there every step ran unattended, and dispatch to announcement took under three minutes:

- **The App merges under the org ruleset's `require_extra_approval_for_unattributed_changes: true`.** The dispatched run logged `drift pro-gate: card v0.65.1 -> release v0.65.2 (draft=true)`, opened repin PR hov-marketplace#211 at 08:45:08Z and requested auto-merge at 08:45:12Z. #211 merged at 08:46:05Z with the App as `mergedBy` and no review. The rule-suite log evaluated that push as `pass`, and `rules/branches/main` still showed the rule active.
- **An auto-merge enabled by the App fires the `push` trigger.** A push-triggered `Repin reconcile` run started at 08:46:08Z and logged `published now pro-gate: v0.65.2` at 08:46:42Z.
- **A publish by the release App token fires the release train.** pro-gate's `Release train` ran on the `release` event at 08:46:44Z, and both of its jobs succeeded. A publish by `GITHUB_TOKEN` would not have fired it, because events caused by that token start no new workflow runs.
- **The announce did not need its promotion-lag retry** (30 s × 8 in `scripts/tool-drop-announce.sh`). It returned `"status":"announced"` at 08:47:09Z, 64 s after the card merged, about 6 s after the step began.

The step still bound to the schedule is the first one. Nothing wakes the reconciler when a plugin stages a draft. Between #210's merge (about 05:30Z) and the 08:44Z dispatch, the four-ticks-an-hour schedule produced no run at all, so v0.65.2's draft waited 90 minutes and would have kept waiting. When a release should ship now, dispatch `repin-reconcile.yml` once the draft exists; the rest needs no one.

## Why This Matters

A human step in a release chain fails in two ways. Nobody does it (v0.65.0's draft), or the person or reviewer doing it is the thing being fixed (the 0.62.0 runtime reviewing its own replacement). Automating it as one more event in the chain trades those failures for a worse one: a chain that cannot be safely re-run, and that acts on whatever it read first.

A reconciler that converges on observed state can run on any schedule because a second run does nothing. It recovers from a missed or failed run by itself. And it can only merge or publish what it can prove matches main.

The live re-read is what makes "publish automatically" safe. Without it, the window between a run's snapshot and its PATCH is exactly where a revert meant to hold a release back gets overridden. Under the old train a person was in that window. Under the new one nobody is.

## When to Apply

- Turning a "someone runs X after Y" step into automation: reconcile from current state, give the reconciler's outputs content-addressed names, and prove that what you merge or publish is what you computed.
- Any job whose final write is irreversible and whose inputs can change during the run: re-read the input the write depends on just before writing, and separate a changed state (skip) from an unreadable one (fail).
- Filtering GitHub objects by an App's author: accept `app/<slug>` and `<slug>[bot]`, and take the slug from the token action's output.
- Not for steps that are already idempotent, cheap, and reversible. There a plain event trigger is fine.

## Examples

Before #209, on 2026-10-17, v0.65.1 (which carried v0.65.0) was promoted by hand:

1. Wait about 11 minutes for release.yml to finish staging.
2. Dispatch `repin-reconcile.yml`. The scheduled run had fired before staging finished and still chose v0.65.0.
3. Merge the repin (hov-marketplace#207) with a script that proves the bot identity and a pin-only diff.
4. Dispatch the plugin's publish workflow.
5. Close #206 by hand, because merging it after #207 would have downgraded the card.

After #209, the merge commit's smoke run printed `closed 0 superseded repin PR(s)`, 11 `published` lines and 0 `published now`. A publish skipped because main moved prints `skip <name>: main no longer pins <tag> (releaseId <id>); not publishing` and exits 0. A failed live read prints `error: could not read the live manifest of <repo> at main` and exits 1.

## Related

- `merging-a-plugin-version-bump-is-the-ship-moment.md` (what the automated train means for review: the VERSION-bump merge is when a release ships)
- `../integration-issues/drive-post-merge-activation-instead-of-handing-back.md` (the same move, automating a post-merge human step, for host activation)
- hov-marketplace#209 (this change), #168 (drafts invisible to the reconciler), #130 (superseded repin PRs never closed), #202 (review vs. no-review rationale); dotfiles#1832 (repins merge on checks), #1834 (fleet merge), #1873 (fleet retired)
- The plugin release recipe in the hov-marketplace repository's docs folder (steps 1-6; "No step after the version-bump merge is human.")
