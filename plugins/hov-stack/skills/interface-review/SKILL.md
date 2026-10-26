---
name: interface-review
disable-model-invocation: true
description: Reviews your work across multiple categories like UI, typography, layout, color, writing and accessibility and gives you a detailed analysis of the findings.
---

# Change review

This skill reviews a change rather than a screen. It resolves the scope, expands the changed files to the surfaces they affect, reads both sides of the diff and classifies every finding.

Scope is all it owns. Domain rules belong to the `better-*` skills. Severity, consolidation, coverage, the cap and the verdict are defined in `## Severity, cap and verdict` at the end of this file, folded in from the upstream orchestrator skill (better-interface), which this harness does not install.

Correctness, tests, security and performance belong to the project's general code review. Name the concern once and move on.

## The change, not the codebase

The author is asking "did I make this worse?". Report what the change caused and stay mostly quiet about what it merely touched. Three pre-existing findings is a courtesy; thirty is a different review and one nobody asked for.

Read the change before forming an opinion of it. The stated intent decides what counts as incomplete, and a skimmed diff produces findings about code the next hunk already fixed.

## Core principles

### 1. Resolve the change scope first

The whole invocation is the target, so `/interface-review pr 482` reviews pull request 482. [Scope resolution](scope-resolution.md) holds the accepted targets and how each resolves.

With no target supplied, resolve in this order and stop at the first match:

1. `HEAD` is ahead of `git merge-base origin/<default-branch> HEAD`: that range **plus** any uncommitted changes, with the commit count and the uncommitted file count stated separately.
2. The working tree is dirty: the uncommitted changes.
3. Neither: there is no change to review. Stop and ask, per **With no change, ask rather than invent one**.

Order matters. Check the working tree first and one stray formatting edit shadows a twelve-commit branch, with the report still claiming full coverage.

Exclude lockfiles, snapshots, generated output, vendored code and binaries, and name what you excluded. An empty scope after exclusions reaches the same place by a different route.

### 2. With no change, ask rather than invent one

A clean tree with nothing ahead of the merge base means the user asked to review a change that does not exist. Never fall back to `HEAD~1..HEAD` on your own. The last commit is whatever happened to land, often a merge, often someone else's work, and a report on it is indistinguishable from a report on what the user meant.

State the repository facts you found, then offer the routes and wait. [Nothing to review](scope-resolution.md#nothing-to-review) holds the facts to gather:

- **The last commit**, `HEAD~1..HEAD`, named by short SHA and subject, so the user sees what they would get before choosing it.
- **A target they name**: `pr <n>`, a branch, a ref, or a range, resolved per **Resolve the change scope first**.
- **A whole-repository interface audit**, which is not a change review. That is a job for `/ux-audit` or `/design-rails` on this harness, without this skill's scope block, statuses, or pre-existing section. With no change, every finding is pre-existing and the classification says nothing.

Check for an open pull request on the current branch before asking, and offer it first. A branch whose commits already landed resolves to no change, while its pull request is still exactly what the user meant.

Where the scope emptied out after exclusions, say which files were excluded and ask the same way. Never report a review of nothing as `Approve`.

### 3. A diff is not a surface

A changed file is evidence, not the review subject. Its **blast radius** is the set of surfaces it renders in; review those.

Expand the blast radius one hop by default: the direct importers and callers. Expand a second hop only for design tokens, theme values and shared primitives, where one line reaches the whole product.

Review at most five consumers, ordered by [the rule in Scope resolution](scope-resolution.md#expanding-to-consumers), then state how many you did not expand. A sweep with no bound cannot support the coverage it claims, and an unstated cutoff reads as completeness.

### 4. Read the removed lines

Regressions are invisible in the post-change state. Read the `-` side of every hunk against [Removed signals](removed-signals.md).

A signal is a lead, not a finding. A removal is only a regression when nothing in the change replaces it, and the domain skill owns that judgement. Route each unmatched removal to its owner, report only what that skill confirms and status it `Regression`. That tells the author they broke something that worked rather than made a new mistake.

### 5. Classify every finding

Give every finding one status:

- `Introduced`: the change created it.
- `Regression`: the change weakened something previously correct.
- `Pre-existing`: present in the touched code but not caused by this change.

Status by what the diff touched, not by which file it sits in: a line the change never touched is `Pre-existing` even three lines from a hunk. Confirm against the base ref when it matters:

```bash
git blame -L <line>,<line> "$BASE" -- path/to/file
```

Carry every finding forward with its status attached, then apply the cap and verdict rules in `## Severity, cap and verdict`.

### 6. Hold the change to its stated intent

Read the pull request title and body, the linked issue and the commit messages, then review whether the interface delivers what they claim.

This is what surfaces the **incomplete** change. A surface review cannot see it, because it inspects the states that are present, and here the point is the ones that are absent:

- A new variant, size, or theme applied to some states but not all: hover, focus, active, disabled, loading, selected.
- A new user-facing string with no entry in the translation catalogue the project maintains.
- A new component with no empty, loading, error, disabled, or narrow-width state.
- A control added to one surface but not to the siblings that already carry its peers.

Do not report scope creep. Whether a change does too much is a process question, not an interface one.

### 7. Route to the domain skills and rank

For each finding, take the rule from the domain skill that owns it. On this harness they are invoke-only: read `better-accessibility`, `better-layout`, `better-writing`, `better-typography`, `better-colors` and `better-ui` by name (`../<name>/SKILL.md`, relative to the directory that holds this `SKILL.md`; the pack ships them side by side) rather than expecting them to fire. Then apply severity, consolidate, enforce the cap and issue the verdict per `## Severity, cap and verdict`.

If a domain skill is missing, mark that domain `Not reviewed` in the coverage line and name it. Do not recreate its rules from memory or substitute a neighbour.

### 8. Never mutate the working tree

A change review is read-only, including the checkout. Fetch pull request refs; never check them out. `git fetch` writes only to `.git` and is permitted. `gh pr checkout`, `git checkout`, `git switch` and `git stash` rewrite the files the author has open. They fail against local edits or discard them, so they are never permitted.

Rendered verification is opt-in. Mark visual and runtime claims **Not verified** unless the project exposes a cheap preview or the user asks for a rendered review. When they do, use an isolated worktree (`git worktree add /tmp/review-<n> refs/remotes/pr/<n>`) and remove it when done.

## Before you finish

| Mistake | Fix |
| --- | --- |
| One stray edit reviewed instead of the branch | Check `merge-base` before the working tree, and report both counts |
| The last commit reviewed because there was no change | State the facts and offer the last commit, a named target, or a repository audit |
| Hunks reviewed without their consumers | Expand one hop, two for tokens and primitives, and name what you skipped |
| Only the `+` side of the diff read | Search the `-` side for removed accessibility, focus, motion and text signals |
| An equivalent replacement reported as a regression | Route the removal to its owner; report only what it confirms |
| A removal reported as a new mistake | Status it `Regression` so the author knows it used to work |
| A line near a hunk statused `Introduced` | Status by what the diff touched, confirmed with `git blame` against the base ref |
| A pull request checked out to review it | Fetch the ref and review it in place |
| Line numbers cited that do not exist on the reviewed ref | Cite against the head ref named in the scope block |
| The severity scale or the finding cap restated inside a finding | Cite `## Severity, cap and verdict` once |
| Correctness, test, or security findings in the report | Name the concern once, point at the project's code review and drop it |

## Review output format

Open with the scope block:

| Field | Value |
| --- | --- |
| Target | `branch`, `working`, `staged`, `pr 482`, or the range as entered |
| Base ref | `origin/main` at `a1b2c3d` |
| Head ref | `refs/remotes/pr/482` at `e4f5g6h` |
| Commits | 7 committed, 2 files uncommitted |
| Files in scope | 12 after exclusions |
| Excluded | `pnpm-lock.yaml`, `src/__snapshots__/`: lockfile and snapshots |
| Surfaces expanded | `CheckoutPage`, `SettingsPanel`; 3 further `Button` consumers not expanded |

The coverage table follows it unchanged. A domain with no evidence in the change scope is `Not reviewed: no evidence in the change scope`, which is a coverage statement rather than a gap.

Then the findings, with a `Status` column per **Classify every finding**:

| Severity | Domain | Status | Location | Before | After | Why |
| --- | --- | --- | --- | --- | --- | --- |
| HIGH | Accessibility | Regression | `src/Dialog.tsx:42` | `aria-label="Close"` removed in this change | Restore `aria-label="Close"` on the icon-only control | The close control had an accessible name before this change and no longer does |

With no `Introduced` or `Regression` findings, omit the table and state "No actionable interface findings in this change."

Then `Pre-existing` findings, at most three, highest severity first, stated plainly as not this change's responsibility. Omit the section when there are none.

| Severity | Domain | Location | Issue |
| --- | --- | --- | --- |
| MEDIUM | Typography | `src/Toolbar.tsx:7` | Numeric badges use proportional figures; predates this change |

The cap and the verdict cover `Introduced` and `Regression` only. `Pre-existing` findings sit outside the cap, so touching a legacy file cannot turn into a full-file audit. They sit outside the verdict too, so a change whose only findings are pre-existing is an `Approve`.

End with `Block` when any `HIGH` remains and `Approve` otherwise, leaving the remaining findings in the table as work to do. The severity scale and the cap are the ones in `## Severity, cap and verdict`.

## Severity, cap and verdict

Folded in verbatim from the upstream orchestrator skill (jakubkrehel/skills better-interface, commit 267330e), which this harness does not install; heading numbers dropped and the cap sentence's cross-reference to that file's own heading removed. In a change review these cover `Introduced` and `Regression` only; pre-existing findings stay out of the cap and the verdict.

### Rank by user impact

Use one shared severity scale:

- `HIGH`: blocks a task, misleads the user, hides content or controls, causes data-loss risk, or creates a repeated systemic failure.
- `MEDIUM`: meaningfully harms comprehension, efficiency, adaptability, or consistency.
- `LOW`: isolated polish with limited task impact.

Within a severity, rank by how many places the finding reaches and how much one fix buys. A token or shared-component fix outranks the same symptom in one leaf.

**Escalation triggers.** Once the owning skill confirms one of these, it is `HIGH` on sight, never averaged down because the surface is minor:

- An interactive control with no accessible name.
- A keyboard-reachable control with no visible focus indicator.
- A control or path reachable by pointer but not by keyboard.
- Motion or auto-playing content that ignores `prefers-reduced-motion`.
- Content or a control clipped, overlapped, or unreachable at 320px width or 200% zoom.
- Body or control text whose rendered contrast pair fails its required ratio.
- State or meaning carried by color alone.
- A destructive action with no confirmation, undo, or distinct treatment.
- Truncated content with no way to reach the full value.
- Content or a control reachable only past a scroll edge or behind a disclosure that has no visible cue.
- An error that names no way to recover from it.
- A semantic color used against its meaning, such as the danger hue on a non-destructive action.
- A state change carried by motion alone, with no color, icon, or label left behind when the animation does not run.

Triggers rank above every other finding. When more fire than the cap allows, list them first and say how many the cap excluded. A cap may shorten a report; it may never be why a blocker went unreported.

These set severity, not new rules. The owning skill decides whether the symptom is present; this list decides what it costs. In a change review, a confirmed `Regression` against a trigger is `HIGH` even where the same symptom would be `MEDIUM` as pre-existing.

### Prefer the cheaper fix

Severity says how bad a finding is; this says which fix to propose. When more than one would work, take the earliest that does:

1. **Delete.** A separator that space would carry, an animation on a high-frequency interaction, an ARIA attribute a native element makes redundant, a ramp nothing imports.
2. **Use the platform.** The native element, the native control, the browser's own focus ring, in place of a custom rebuild.
3. **Reuse what the project has.** An existing token, spacing step, or motion curve, before any new value.
4. **Correct the value.** The wrong easing, radius, gap, or contrast pair, using the exact value the owning skill gives.
5. **Add.** A new token, a wrapper, a media query, an ARIA attribute the platform cannot supply.

A fix written at step 5 where step 1 was available is its own finding. Report the deletion instead.

### Consolidate systemic findings

One root cause is one finding. List every confirmed location in the same row rather than one row per occurrence. Never pad to reach the cap; a short review or no findings is a valid result.

### The cap

Cover the resolved scope across every domain skill, including the empty, loading, error and narrow-width states where they exist. Report at most 15 findings.

### Verdict

End with one of two:

- `Block`: one or more `HIGH` findings remain. Do not ship until they are fixed.
- `Approve`: no `HIGH` findings remain. Any `MEDIUM` and `LOW` findings stay in the table as work to do.

`Approve` claims the coverage you reported, so never issue it for a domain you did not inspect.
