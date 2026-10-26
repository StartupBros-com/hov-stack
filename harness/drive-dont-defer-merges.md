---
name: drive-dont-defer-merges
description: "The user wants me to drive merges/routine decisions, not park them back on him"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: ab1c00f0-096e-4699-a5d6-da94673fc2ec
---

When I've finished a PR I created and it's safe/clear-cut (onboarding configs, lockfiles, my own infra PRs, graduations), **merge it myself** — don't end with "merge this when you're ready" or hand routine merges back to the user.

**Why:** he explicitly pushed back — "why would I merge it? You merge it..." He delegated the work; deferring the final click is friction, not safety.

**How to apply:** drive merges + routine decisions to completion. Reserve asking for genuinely consequential/irreversible calls (auto-merge blast radius across many prod repos, deleting things, spending scarce resources, security-posture changes) — see [[dependency-autopilot]]. For everything routine: just do it and report what I did.

**"Gate-green" means the required checks RAN, not merely that they are green.** GitHub treats a *skipped* required check as satisfied, so a check that never executed still shows a green tick and still permits merge. Confirmed live on 2026-07-29: a members-app change merged with `⚫️ Test = skipped` because a draft-gating conditional evaluated against a stale event payload.

**The general law, of which that is one instance:** a green aggregate is not evidence that anything ran. Closure requires the REQUIRED set to equal the PASSED set over *named* checks — a set comparison, never an aggregate exit code — and an **empty set is a failure, never a vacuous pass**. This is not CI-specific: a jest run matching zero files, a `pytest -k` selecting nothing, and a benchmark emitting null summaries all exit 0 too. Full statement and the non-CI cases: [evidence-regime](evidence-regime.md) §2.

Before merging, run the check rather than eyeballing the tick:

```bash
scripts/gate-check.sh <owner/repo> <pr-number>
```

It asserts every required check's conclusion is `success`, fails on `skipped`/`pending`/missing/empty, and when branch protection is unreadable it widens to all observed checks and says so instead of reporting PASS over an unknown set. The raw query it replaces, if you need it by hand:

```bash
gh api "repos/<owner>/<repo>/commits/<head-sha>/check-runs" \
  --jq '.check_runs[] | "\(.name): \(.conclusion)"'
```

Two structural traps behind that:
- A job skipped by a conditional reports Success and satisfies the check. A *workflow* skipped by `on:`-level filtering leaves the check Pending forever and blocks merge. Opposite outcomes, so never reach for `on:`-level filters on a required check.
- An aggregator job fronting other jobs via `needs:` **must** carry `if: always()`. Without it `needs:` implies `if: success()`, so an upstream *failure* skips the aggregator, which then reports green — the failure becomes invisible.

Related: [[gh-tracking-and-claims]]
