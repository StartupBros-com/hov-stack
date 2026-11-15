---
title: "A plugin fix merged without a version bump is merged, not released"
date: "2026-11-15"
category: best-practices
module: plugin-release-delivery
problem_type: best_practice
component: development_workflow
severity: high
resolution_type: workflow_improvement
applies_when:
  - "A pull request changes shipped files under plugins/<name>/ and leaves plugins/<name>/VERSION unchanged"
  - "Reporting a plugin fix as done, or closing the issue it fixes"
  - "Deciding whether a plugin fix can wait for that plugin's next release"
  - "A repo-wide sweep touches files inside several plugins"
symptoms:
  - "CI, the repo's guards and the post-merge activation receipt are all green while a marketplace install of the plugin still has the old files"
  - "The plugin's marketplace card pins a commit that does not contain the fix's merge commit"
  - "plugins/<name>/VERSION is the same at the card's pinned commit and on main while shipped files differ"
tags: [plugin-release, marketplace-pin, version-bump, delivery-verification, merged-not-released]
related_components:
  - hov-marketplace-repin-reconcile
  - papercut-delivered-check
---

# A plugin fix merged without a version bump is merged, not released

## Context

#612 fixed unchecked `mktemp` lines across the repo (#443). Its diff included shipped files in four plugins: pro-gate, token-eater, wsl-cdp and hov-stack. #635 followed and changed three of token-eater's scripts again. Neither PR changed a `plugins/<name>/VERSION`.

Every signal was green. CI passed. The new guard, `tests/mktemp-checked-guard.test.sh`, passed. The post-merge closeout printed `activation: checkout current`. The work was reported done and #443 was closed.

It was not done for anyone who installs those plugins from the marketplace. Each plugin's card still pinned a commit from before #612, and `git diff <pin> origin/main -- plugins/<name>` listed the fixed files. On the one host where it was checked, the installed copies of pro-gate, token-eater and wsl-cdp differed from main in the same files. The fixes were on main and in no release.

**Why nothing moved.** A plugin reaches an install through its marketplace card, and the card pins a commit.

- `.github/workflows/auto-release.yml` runs on a push to main that touches `plugins/*/VERSION`. Its script, `release/scripts/auto-release-decide.sh`, walks only the `VERSION` files that changed in that push and tags `<name>--v<version>`.
- `release/scripts/repin-reconcile.sh` writes a card's `sha` from the commit behind the plugin's newest release tag. It reads releases and tags. It does not read the diff on main.

A merge that leaves `VERSION` alone makes no tag. With no new tag the card stays where it is, and a marketplace install follows the card. A host that loads a plugin straight from a checkout is the exception: #568's body notes that such a host "picks the change up when the checkout updates".

**Why every signal was green.** None of them looks at the card.

- `release/scripts/plugin-ci.sh` checks that `VERSION` matches the plugin manifest and asks for release notes when `VERSION` changed to a version with no tag yet. Changed shipped files beside an unchanged `VERSION` pass.
- The guard and the test suites read the tree on main, where the fix is.
- `scripts/wt-done.sh` prints activation lines for the checkout, the settings and the skills. `./setup` links `scripts`, `hooks` and the other top-level harness paths from the checkout into the live config, so for those paths "checkout current" does mean live on that host. Plugin files take the other route. `CONCEPTS.md` says as much under *Activation receipt*: a checkout-current receipt "proves that one merge is an ancestor of the checkout's HEAD".

One PR, two delivery routes, one receipt. The receipt was true and covered half the diff.

**It had happened before.**

- `plugins/papercut/docs/EXTRACTION-DESIGN.md` records a papercut redaction fix that merged in September and "had not reached a single customer twelve days later". It concludes that "a freshness check would" have caught it. That check exists for papercut alone, as `scripts/papercut-vendor.py --verify-delivered`. Since #309 turned the papercut card into a subdirectory pin it cannot read the pinned files, and it answers UNKNOWN (#645).
- hov #568 changed `plugins/hov/hooks/hooks.json` with no bump, and its body said so: members would get it "with the next hov release". Nothing else changed in hov, so #580 bumped it to 0.1.8 with #568 as its only content. #590 moved the card and the release published about eight hours after #568 merged. That one was named at merge and released on purpose. It also shows what "the next release" means when none is coming: a release cut for one fix.

## Guidance

**Say "merged, not released".** When a PR changes shipped plugin files without a bump, write those words in the PR body, in the report, and where the issue closes. Name the release that will carry the fix, or say that none is scheduled. "Done" and "fixed" are true of the repo tree only.

**Check the card, not the checkout.** The test is whether the card's pinned commit contains the fix's merge commit. It answers only for a PR that changed files in that plugin, so the check refuses anything else instead of guessing.

```bash
name=token-eater   # the plugin
pr=612             # the PR that carried the fix
git fetch origin main
pin="$(git show origin/main:.claude-plugin/marketplace.json |
  jq -r --arg n "$name" '.plugins[] | select(.name == $n) | .source.sha // empty')"
fix="$(gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid')"
changed="$(git diff --name-only "$fix^" "$fix" -- "plugins/$name")"

if [ -z "$pin" ] || [ -z "$changed" ]; then
  echo "could not compare: no card for $name, or #$pr is unmerged or changed nothing under plugins/$name"
else
  git merge-base --is-ancestor "$fix" "$pin"
  case $? in
    0) echo released ;;
    1) echo "merged, not released"
       # every file that differs since the pin, tests included, then the merges that changed them
       git diff --name-only "$pin" origin/main -- "plugins/$name"
       git log --format=%s "$pin..origin/main" -- "plugins/$name" ;;
    *) echo "could not compare: the pinned commit is not in this clone" ;;
  esac
fi
```

The file list is everything under the plugin that differs since the pin. It includes tests and docs, which do not ship, and changes from other merges.

**Give the release an owner before the PR merges.** There are three honest choices.

1. Bump `VERSION`, with its release notes, in the PR that carries the fix. Merging it is then the ship moment.
2. Merge without a bump and open the release PR next, as #580 did for #568.
3. Merge without a bump and name the release already in flight that will carry it.

"It rides the next release" is a plan only when that release is in flight or someone owns cutting it. Otherwise it is choice 2 with nobody doing it. A change that touches only a plugin's tests or docs needs no release; say that instead.

**Ask the question per plugin on a sweep.** #612 touched files in eight plugins and no single plugin was its subject, so the release question never came up. Before merging a repo-wide change, list the plugins it touches and look at which of those files ship.

```bash
git diff --name-only origin/main...HEAD -- plugins | cut -d/ -f2 | sort -u
```

**pro-gate has a second step.** Its README says: "The plugin updates itself through the marketplace; the privileged runtime deliberately does not." After a pro-gate release moves the card, the runtime still needs its own update through `plugins/pro-gate/install.sh` at the new version.

**Until a report does this, it is a manual step.** #645 asks for a delivered report that covers every card: shipped files on main ahead of each pin, printed as warnings in the weekly report. It should report and not fail a merge, because some differences are deliberate. `.github/workflows/release-pins-refresh.yml` edits a hov-stack plugin file on main and "never bumps plugins/hov-stack/VERSION". When that report exists and covers every card, the manual check above can go and this doc should point at the report.

## Why This Matters

- **It is silent by construction.** CI, the guards, the plugin CI and the activation receipt all pass, and each is right about what it checks. Nothing fails until someone compares the pin with main.
- **The false "done" removes the prompt.** Closing the issue is what ends the work. Once #443 was closed, nothing was left to ask for a release. hov #568 went the other way: its PR body named the gap, #580 carried the bump, and the release published about eight hours after the fix merged.
- **The author's machine hides it.** Tests and guards run against the checkout, where the fix is present. The people who lack it are the ones who install from the marketplace.
- **It recurs.** `scripts/harness-weekly.sh` says the September fix sat "unreleased for twelve days and nothing anywhere said so". This one was reported done. The one automated check covers papercut only and currently answers UNKNOWN (#645).

## When to Apply

- A PR changes a file under `plugins/<name>/` that ships, meaning anything but its tests and docs.
- Before writing "done", "fixed" or "live" about a plugin change, and before closing its issue.
- A repo-wide sweep or refactor touches files inside plugins.
- Someone asks whether a plugin fix has reached them. Answer from the card, not from main.

## Examples

The check above, run for token-eater and #612 on 2026-11-15. Four of the seven files ship; the three under `tests/` do not.

```text
merged, not released
plugins/token-eater/skills/token-eater/scripts/apply-tool.sh
plugins/token-eater/skills/token-eater/scripts/delegate-claude.sh
plugins/token-eater/skills/token-eater/scripts/delegate-codex.sh
plugins/token-eater/skills/token-eater/scripts/delegate-grok.sh
plugins/token-eater/tests/consent-preflight.sh
plugins/token-eater/tests/delegate-scope.test.py
plugins/token-eater/tests/validate-data.test.sh
fix: a failed mktemp keeps each script's exit contract; guard follows sourced helpers (#635)
fix: check every mktemp where it runs, and guard the tree against new unchecked ones (#612)
```

The same check printed `released` for hov and #580, which carried a bump, and for hov and #568, which #580 released. For a plugin with no card, a PR number that does not exist, and hov with #612, which changed nothing in hov, it printed `could not compare`.

The report, before:

> #612 merged. Guard green on main. #443 closed.

What it should have said, with the last sentence filled in from the real plan:

> #612 merged. Repo scripts and hooks: live on hosts that run the checkout. Plugin files in pro-gate, token-eater, wsl-cdp and hov-stack: merged, not released. No `VERSION` changed, so each card still pins its previous release. No release is scheduled; #645 lists what is ahead of each pin.

## Related

- `merging-a-plugin-version-bump-is-the-ship-moment.md` (the other half: when a bump exists, merging it ships)
- `docs/solutions/integration-issues/drive-post-merge-activation-instead-of-handing-back.md` (the activation receipt, which covers the checkout and not a plugin's card)
- `serving-plugins-from-a-monorepo-with-git-subdir-marketplace-entries.md` (why a card pins a commit of this repo)
- `diagnose-against-installed-versions-not-plugin-caches.md` (judge a plugin by what is installed)
- `automate-a-release-step-by-converging-on-observed-state-and-re-reading-before-publish.md` (how the repin step decides what a card should pin)
- `plugins/pro-gate/docs/solutions/conventions/a-staged-release-tag-can-predate-a-later-fix-on-the-same-version.md` (a narrower case of releases keyed to `VERSION`)
- `docs/release/plugin-release-recipe.md` (how to cut the release)
- `plugins/papercut/docs/EXTRACTION-DESIGN.md` (the September instance and the case for a freshness check)
- `CONCEPTS.md`: *Marketplace card*, *Activation receipt*
- #443, #612, #635 (this instance); #568, #580, #590 (hov); #309, #645 (the delivered check)
