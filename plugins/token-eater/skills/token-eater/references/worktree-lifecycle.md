# Worktree lifecycle, isolation, and concurrency

token-eater runs every chore in its own git worktree so it never disturbs the user's
checkout and so parallel runs (and parallel token-eater sessions) cannot corrupt each
other. `scripts/wt.sh` owns this — it vendors the proven conventions from the
compound-engineering `ce-worktree` skill and `wt-sweep.sh`, so users do
not need those installed.

## Isolation guarantee

- **Branch from a committed ref, never the dirty working tree.** `wt.sh create` cuts the
  chore branch from `HEAD` (or a given base) into a separate worktree. The user's main
  checkout — including uncommitted WIP and whatever branch they are on — is untouched.
  They keep working while token-eater runs (R12).
- **The chore edits happen only in the worktree.** The gate runs there; keep/rollback
  affects only that worktree and branch (see `delegation-invocation.md`).

## Naming (collision-safe)

Per token-eater invocation, generate a short `run-id` (random hex). Per chore:

- branch: `token-eater/<run-id>-<chore-slug>`
- worktree: `<repo>/.claude/worktrees/te-<run-id>-<chore-slug>` (the user's on-disk convention)

One chore = one branch = one draft PR (independently-reviewable, independently-mergeable
slices). Because names are keyed by `run-id`, two sessions never collide on a path or branch.

## `scripts/wt.sh`

```bash
wt.sh create  <repo> <run-id> <chore-slug> [base-ref]   # prints the worktree path
wt.sh cleanup <repo> <worktree> keep|drop               # remove worktree; keep or drop the branch
wt.sh sweep   <repo>                                     # remove orphaned te worktrees (DRY_RUN=1 default)
```

`create` also sets the worktree up to actually run the gate (the lessons from earlier runs):
copies `.env*` (skipping `.env.example`), symlinks `node_modules` / `.venv` so `tsc` /
`vitest` / `pytest` resolve, excludes those injected deps from change detection via
`$(git rev-parse --git-path info/exclude)`, and gitignores the worktree dir.

## Concurrency model

- **Within a run:** chores run in parallel, each its own worktree → its own PR.
- **Across sessions / same repo:** safe by construction — `run-id`-keyed names avoid path
  and branch collisions, and the brief ref-mutating git operations (`worktree add/remove`,
  `branch -D`) are serialized with a per-repo `flock` on `<git-common-dir>/token-eater.lock`,
  so they cannot race on `index.lock`.
- **Across repos:** fully parallel.

Open caveat (v2): two sessions could independently pick the *same* chore and open
duplicate PRs. v1 accepts this (low harm, the human dedups); a chore-claim file is the
planned fix.

## Cleanup (zero-loss, from `wt-sweep.sh`)

- On chore completion: `wt.sh cleanup <repo> <wt> keep` (gate passed -> branch is the PR) or
  `... drop` (rolled back -> remove the branch too).
- **Removing a worktree never deletes commits**; a kept branch persists in the repo.
- **A branch holding >= 2 unpushed commits is never force-deleted** — `cleanup drop` keeps
  it and warns instead.
- `wt.sh sweep` reclaims orphans from crashed/abandoned runs. It **skips live worktrees**
  (under `.claude/jobs/` or `/tmp`, touched within `ACTIVE_MIN=120` minutes, or held open by
  a process) — never remove a worktree a running session owns. `DRY_RUN=1` is the default;
  re-run with `DRY_RUN=0` to apply. Merged/gone branches are cleaned up separately by the
  user's existing branch hygiene (`ce-clean-gone-branches`).
