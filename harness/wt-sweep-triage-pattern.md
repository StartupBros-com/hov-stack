---
name: wt-sweep-triage-pattern
description: "wt-sweep 'preserved' branches are ~95% squash-merge artifacts — always follow a sweep with a content-verified triage pass; first run 2026-07-02: 24 preserved → 23 superseded, 1 real"
metadata: 
  node_type: memory
  type: project
  originSessionId: 453baaee-e364-4c41-ab67-4e83520b35de
---

First live wt-sweep (2026-07-02) removed 81 worktrees and preserved 24 branches as "has unique work." Triage (3 parallel readers doing byte-level diff-vs-merged-PR comparison) found **23 of 24 were fully superseded**: squash-merges orphan branch SHAs, so wt-sweep's `rev-list --count HEAD --not --remotes` counts "unpushed" commits whose content already merged. `git cherry` can't catch it either (squash combines commits). The one real find: a members-app auth-hardening branch (~15 unmerged commits → rescued as a members-app change).

**The pattern (keep it two-stage, don't "fix" the sweep):** wt-sweep stays conservative/zero-loss (over-preserving is correct — content-equivalence detection is too heavy for a sweep script). After any sweep with preserved branches, run a **triage pass**: per branch, three-dot diff vs origin/default + compare against merged PRs (`gh pr list --head <branch>` catches most — squash-merged branches usually keep their head-branch name on the PR). Verdicts: PR-WORTHY → push + draft PR; SUPERSEDED/JUNK → bundle then delete (`git bundle create .git-archive/<date>-triage/superseded-branches.bundle <branches> ^origin/<def>` — incremental, tiny; restore via `git fetch <bundle> <branch>`).

Gotchas from the first run: a worktree can sit ON `main` and WIP-commit to local main (reset with `git branch -f main origin/main` after bundling); "behind 146 + 4 unpushed" can be pure merge-graph noise with a byte-identical tree (check `git diff origin/<def>...<branch> --stat` emptiness first — cheapest disqualifier); stale origin URLs (repos moved to StartupBros-com org) make `gh pr create` fail with cross-org ref errors — `git remote set-url` first (a private repository fixed 2026-07-02; dotfiles same pattern).

**Iceberg cleared (2026-07-02, same day):** `~/.claude/scripts/branch-triage.sh` (wt-sweep's sibling) now automates the funnel — PROTECTED (default/worktree/open-PR) → MERGED → SYNCED → TREE-SAME → PR-SHIPPED (merged-PR head-name match, fetched once per repo) → CHERRY → RESIDUE. Fleet run over ~600 local branches: 494 mechanically disposed, 53 residue deep-triaged by readers → 9 rescue draft PRs (the members app: RLS-hardening batch + route-handler-400 + a second auth-hardening change; a private evals repository: EXP-007/EXP-012 test splits; another private project: two small feature branches; two private projects: a paired branch set; pi-ce: pi-064-compat from stranded remote branch), 2 open PRs improved (a private evals repository's #822 unpushed-commit push, its duplicate #821 closed), rest bundled+deleted. Residue-class intel: `worktree/<codename>` = duplicate pointers to one merged commit; `backup/`/`restore/`/`pr-NNN` = snapshots/review-checkouts, almost always junk; timestamped agent-retry series (token-eater) = keep only the converged attempt; gh rate-limit failures during classification fall through CONSERVATIVELY (branch kept). Held for human: a members-app subsystem-removal branch (a deprecation call), rizeio feat/usage-analytics (origin is third-party — fork decision), smaug open PRs #30/#31 aging ~99d.

Related: [[cc-two-homes-decommission]], [[drive-dont-defer-merges]].
