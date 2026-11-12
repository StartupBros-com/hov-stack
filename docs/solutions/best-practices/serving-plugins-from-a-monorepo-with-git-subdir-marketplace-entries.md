---
title: "Serving plugins from a monorepo with git-subdir marketplace entries: what Claude Code clients do and what an install lacks"
date: "2026-11-11"
category: best-practices
module: marketplace-manifest
problem_type: best_practice
component: development_workflow
severity: medium
resolution_type: workflow_improvement
applies_when:
  - "Adding a plugin under plugins/ or moving files inside one"
  - "A plugin file refers to another file by path"
  - "A plugin works in the checkout and in plugin CI but not once installed"
  - "A member's Claude Code client refuses the marketplace manifest"
  - "Rolling back or re-pinning a released plugin"
symptoms:
  - "Claude Code 2.1.68 to 2.1.75 refuse marketplace add for the whole manifest with Unrecognized keys: metadata, card"
  - "A file a plugin needs is present in the checkout and in CI but missing from the installed plugin"
  - "The validator refuses an entry with cannot change shape from git-subdir back to url"
  - "The validator refuses a pin with pinned commit is not reachable from main"
tags: [git-subdir, claude-code-marketplace, sparse-install, plugin-cache, version-floor, release-train]
related_components:
  - marketplace-manifest
  - release-train
  - skill-pack
---

# Serving plugins from a monorepo with git-subdir marketplace entries: what Claude Code clients do and what an install lacks

## Context

At the cutover every entry in `.claude-plugin/marketplace.json` became a `git-subdir` source: the shared repository's clone URL, a `path` of `plugins/<name>` and a `sha` pin. Before it, each plugin was a `url` entry pointing at a repository of its own. The U24 record counts thirteen entries, the twelve plugins and the skill pack, all `git-subdir`, with no `url` entry left (restructure plan).

The hosted rehearsal (U21, the gate-2 record in the plan) checked how Claude Code clients handle that shape before the real migration. It used two public scratch repositories, a manifest repository and a monorepo holding a scratch plugin and a three-skill pack, and clients on Claude Code 2.1.68 to 2.1.77 or 2.1.309 in scratch homes with no GitHub token, one of them with no SSH key.

## Guidance

**What a client does with a `git-subdir` entry.** Observed at U21 on the scratch repositories:

| Case | Observed |
|---|---|
| Reading the manifest | 2.1.68 to 2.1.75 refuse `marketplace add` for the whole manifest ("Unrecognized keys: "metadata", "card""); 2.1.76 and later read it. The live marketplace split the same way, so the floor comes from the release metadata and card every entry carries, not from `git-subdir`. Versions older than 2.1.68 were not run. |
| A fresh install | The cache held exactly the plugin's subdirectory at the pinned commit and nothing outside it. The pack's cache held every skill of the pack and nothing else from the monorepo. |
| Two plugins pinned to one commit | Installed side by side with separate caches on fresh 2.1.76, 2.1.77 and 2.1.309 clients. |
| An installed plugin whose entry switched from `url` 0.3.1 to `git-subdir` 0.3.2 | Updated on 2.1.76, 2.1.77, 2.1.309 and the 2.1.309 client with no SSH key. The old version folder was marked orphaned; enabled state and plugin data survived. |
| A pin not reachable from main | The validator refused it. Clients given it anyway failed the checkout and stayed on the installed version, enabled, with data intact. |

At U24 the real canary repeated only the update: a member install moved from rent-check 0.3.1 to 0.3.2 at the pinned commit, in a scratch home on the author's machine. The cache contents, the orphaned folder and the kept state were not recorded again.

**The client floor is 2.1.76, and `./setup` names it instead of refusing.** `setup` sets `CLAUDE_FLOOR=2.1.76`, with a comment citing the gate-2 record. Below the floor it reports that the version "is below the 2.1.76 floor, under which the CLI refuses the" manifest and says to run `claude update`, then keeps linking and asks the old CLI nothing else (`tests/repo/setup.test.sh`: "claude 2.1.75 is named below the 2.1.76 floor; the run goes on and asks it nothing else").

**Nothing a plugin needs at run time may live outside `plugins/<name>`.** An install holds only that directory. A relative path, a symlink or a `~/.claude/...` path that leaves it resolves in the author's checkout and in CI, and is missing on a member's machine. The plan's KTD11 is the worked case: the root `skills/` is a link into `plugins/hov-stack/skills/`, chosen over the reverse because "a link out of it dies in the sparse checkout". KTD11 also notes that a Windows checkout may materialise a git symlink as a text file, so `./setup` resolves the plugin path directly and never depends on the root link: it links each skill from `plugins/hov-stack/skills/*/`.

Only the skill pack has a check for this:

- `test_root_skills_link_resolves_into_the_pack` holds the link's direction.
- `test_no_pack_skill_reaches_the_checkout_through_a_home_path` refuses a pack skill that reaches the checkout through a home path. A skill that has to run one of the checkout's scripts lives in `skills-stack/` instead, which `./setup` links and the pack does not ship; `test_every_stack_skill_reaches_the_checkout` keeps that directory to skills that need it (all in `tests/test_skill_pack.py`).

No shared check covers the other plugins. `release/scripts/plugin-ci.sh` runs a plugin's own CI script (for example `plugins/design-rails/tests/ci.sh`) from inside a full checkout of the repository, so a reference out of the plugin's directory passes plugin CI. As of `4f8fade` no shipped runtime file under `plugins/` reaches outside its own plugin: there are no symlinks, and the parent-relative paths in shipped files resolve inside their plugin, apart from one test, `plugins/hov-stack/skills/hov-setup/scripts/instructions.test.mjs`, which compares against the repository's `lib/manifest.sh` and runs only in a checkout.

**A `git-subdir` entry only moves forward.** The validator refuses a switch back to `url` ("cannot change shape from git-subdir back to url (rollback is a new prefixed release)", plan R50) and a pin that main cannot reach ("pinned commit is not reachable from main"). The release recipe lists reverting the card among the things that are not a lever. A bad release is fixed by a new prefixed release.

## Why This Matters

A `git-subdir` entry lets one repository serve every plugin without each install pulling the whole monorepo. The cost is that the install is narrower than every place the plugin is developed and tested: the author's checkout and CI both hold the whole repository, and the member's cache holds one directory. A reference that crosses that line passes every check this repository runs for every plugin but the pack, and fails only on a member's machine. The other two failures, an old client and a bad pin, already stop in code: `./setup` names the floor, and the validator refuses the pin.

## When to Apply

- Adding a plugin under `plugins/`, or moving files inside one.
- Writing a plugin file that refers to another file by path.
- A report that a plugin works in the checkout but not once installed.
- A member reporting that `marketplace add` refuses the manifest.
- Considering a rollback of a released plugin.

## Examples

A relative path is fine while it stays inside the plugin. The design-rails skill points at its scripts two directories up from the skill, which is `plugins/design-rails/src/`, inside the installed directory.

The link direction KTD11 chose, against the one it rejected:

```text
skills -> plugins/hov-stack/skills        # chosen: the link lives outside the pack, its target inside
plugins/hov-stack/skills -> ../../skills  # rejected: the target is outside the pack, absent from the cache
```

## Related

- `docs/plans/2026-10-20-feat-hovstack-restructure-plan.md`: KTD11, R50, the gate-2 rehearsal record (U21) and the U24 record
- `docs/release/plugin-release-recipe.md` ("What is not a lever", "Adding a plugin after the flip")
- `release/scripts/validate-marketplace.sh`, `release/scripts/plugin-ci.sh`, `tests/test_skill_pack.py`, `setup` (`CLAUDE_FLOOR`)
- `renaming-a-repository-that-serves-a-claude-code-marketplace.md` (the same rehearsal, for the repository rename)
- `diagnose-against-installed-versions-not-plugin-caches.md` (the cache holds the plugin's directory, not the repository)
- `merging-a-plugin-version-bump-is-the-ship-moment.md` (the release that writes each pin)
- #374
