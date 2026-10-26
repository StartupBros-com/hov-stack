---
title: "Drive and verify post-merge activation instead of handing the operator a command"
date: 2026-09-03
category: integration-issues
module: dotup-activation-pipeline
problem_type: integration_issue
component: development_workflow
symptoms:
  - "wt-done.sh reports the PR shipped, but the running harness still executes pre-merge code because the canonical checkout never fast-forwarded or the skill localizer never ran"
  - "The hourly dotup-refresh.timer fast-forwards the canonical ~/dotfiles checkout up to ~80 min late and, before #915, never invoked scripts/skills-localize.sh, so skill drops and overlays stayed stale after the checkout was current"
  - "Before the unrelated-dirty fast-forward fix, SessionStart heal refused the canonical checkout because backup-harness.sh kept 34 memory-mirror files dirty; incoming-path collisions still correctly block refresh"
  - "Sessions close a merged, gate-green PR by handing the operator a 'run sync.sh install' command, or by asserting merged code is live without checking the canonical checkout"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
severity: high
related_components:
  - wt-done.sh
  - dotup-refresh.service
  - skills-localize.sh
  - launchpad-freshen.sh
tags:
  - post-merge-activation
  - hand-back
  - systemd
  - symlinked-checkout
  - skills-localize
  - verification
  - dotup
  - worktree-closeout
---

# Drive and verify post-merge activation instead of handing the operator a command

## Problem

A merged dotfiles PR is not live. `~/.claude/{scripts,hooks,agents,bin,CLAUDE.md}` are symlinks into the canonical checkout at `/home/user/hov-stack`, and skill drops and overlays under `skills-local` and `skills-patches` are copied into `~/.claude/skills` by `scripts/skills-localize.sh` (`HERE` resolved through the symlink at `scripts/skills-localize.sh:59-60`; fork deployment at `scripts/skills-localize.sh:142-179`, patch overlays at `scripts/skills-localize.sh:237-261`). A merge to `main` therefore changes nothing that any session loads until the canonical checkout fast-forwards and the localizer runs. Until PR #915, neither was triggered by a merge, so sessions closed a merged, gate-green PR by handing the operator a command (`sync.sh install`) or by reporting merged code as live.

## Symptoms

- `wt-done.sh` prints "PR merged this exact tip", yet `~/.claude/scripts/*` and `~/.claude/CLAUDE.md` still resolve to the pre-merge commit and a new skill directory does not exist under `~/.claude/skills`.
- The canonical checkout sits one or more commits behind `origin/main` for up to ~80 minutes: `dotup-refresh.timer` is `OnCalendar=hourly` with `RandomizedDelaySec=20m` and `Persistent=true` (`systemd/dotup-refresh.timer`, lines 5, 11 and 14). Measured 2026-08-27, before the timer existed: the checkout was 25 commits behind, and merges had sat inert for four days (session history).
- Skill forks and overlays are missing from `~/.claude/skills` or `~/.codex/skills` even after the checkout is current, because the hourly path never ran the localizer; only a 03:00 `jsm-auto-update` `ExecStopPost` drop-in did.
- A session's closing report ends with a command for the operator ("run `sync.sh install`") or states that a merge is live without having checked the checkout. Incidents: #355, #508/#510, #893. The operator's correction is on record twice, a week apart: on 2026-08-27 ("why are you making me run commands? why are we handrolling scripts?") and on 2026-09-02 ("any time a human has to run a command it indicates an issue with the system") (session history).

## What Didn't Work

- **Relying on the hourly timer.** Before #915, its refresh did not include localization: `dotup` never called the localizer at all (`dotup`, the `skills-localize apply` block, records that until 2026-09-02 the only automatic caller was the 03:00 drop-in). The current timer includes that step, but a delayed or refused refresh still cannot establish that a change is live before the next step.
- **Relying on a blanket clean-checkout rule.** The earlier SessionStart heal refused any tracked modification on the default branch; the 34 memory-mirror files kept dirty by `backup-harness.sh` made that refusal permanent. Current `process_repo()` in `scripts/launchpad-freshen.sh` carries unrelated tracked edits through `git -c merge.autostash=false merge --ff-only` and refuses incoming-path collisions. Off-default healing retains separate clean-tree and pushed-tip/age checks; closeout does not request healing or a branch switch. This canonical-checkout policy does not relax `wt-done`'s requirement that the task worktree itself be clean.
- **Hiding the actual refresh refusal.** Before #1885, `launchpad-advisory.js` retained only helper success lines and then blamed all dirty state. It now reports bounded helper diagnostics separately from mutations. A failed fetch leaves upstream freshness unconfirmed even when cached origin refs match HEAD; a successful branch switch followed by a failed fetch is partial progress, not a fresh checkout.
- **Sessions doing it by hand.** Forensics on 2026-09-02 (issue #909): of seven post-merge fast-forwards that day, five were merging sessions running `dotup` or `git merge --ff-only` themselves and two were the timer landing by luck. A worktree-isolated session cannot do even that: Claude Code's built-in worktree verifier blocks `git -C ~/dotfiles` from inside a worktree session, and that is the session that closed PR #893 with a hand-back. On 2026-08-27 the same guard blocked the operator's own pasted deploy command relayed through a session still pinned to a merged worktree (session history).
- **Hand-updating the dirty checkout.** Twice before this stranded or froze it: an unresolved stash-pop conflict silently blocked every later merge, and `git pull --ff-only` under `rebase.autoStash` stashed 35 tracked modifications and failed to re-apply them (auto memory [claude]). The same trap was seen on 2026-08-27, when `git merge --ff-only` printed a successful fast-forward summary and then "Applying autostash resulted in conflicts", leaving conflict markers in tracked files on the path the hourly timer runs unattended (session history).
- **The deploy chain that swallowed its own failures.** The first `dotup` ran `repo_ff_update "$HERE" || true`, so a hard refusal and a clean update looked identical and a stale tree got installed with a success report; both merge call sites sent stderr to `/dev/null`; and after the refresher existed, a fail-closed `install.sh` preflight requiring `cosign` and `mise` ran under systemd's bare PATH because the unit had no `Environment=` line, so every hourly run failed silently from one evening onward (PR #480, #485, #544; session history). The current `dotup` fails closed on a refusal (`dotup:155-164`) and the unit carries its PATH (`systemd/dotup-refresh.service:44`).
- **Reaching for `wt-sweep.sh` instead of `wt-done.sh` at closeout.** One session (PR #830, 2026-09-02) never ran `wt-done`, ran the cleanup sweep from inside its worktree, hit the guard, and declared the work shipped from `gh pr view` alone before closing with "the one command that deploys it" (session history). `wt-done` is the closeout; `wt-sweep` is a later, DRY_RUN-first disposal step.
- **Rejected designs** (per this session's conclusion): wiring the localizer into `sync.sh install` (that function runs from wherever it is invoked, including worktrees, which is exactly the symlink trap `dotup` itself refuses at `dotup:46-55`); a `dotup --activate` child process (it would lose the systemd unit's own timeout); a route-guard exemption (no repo hook was blocking anything); a `.path` unit or webhook (a fetch or listener nobody runs).

## Solution

After merging your own PR, run the closeout from inside the worktree:

```
DRY_RUN=0 ~/.claude/scripts/wt-done.sh
```

In full mode, `close_one()` in `scripts/wt-done.sh` activates after proving shipment by A (`headRefOid == HEAD`), B (an empty diff against the merge commit), or C (the tip is an ancestor of the head GitHub merged). `--reconcile-only`, wt-sweep's triage path, can fetch and reconcile pointers or anchors in apply mode, but never activates or removes. `DRY_RUN=1` is different: it uses cached Git state and never invokes the freshener or systemd; it may still query GitHub.

A branch whose tip is already reachable from a remote ref takes `activate_reconciled()`. Reachability alone does not prove a merge, so this path also resolves the merged PR. Its head must be the tip or contain it; an ordinary repository also accepts a tip already moved onto that PR's exact merge commit by an earlier tree-proof reconciliation. Before an ordinary checkout refresh, the merge object must exist locally and be on `origin/<default>`; shallow-history uncertainty uses the existing GitHub comparison. A reused branch name or unrelated PR cannot authorize refresh. `still_proven()` re-checks branch, tip and cleanliness after activation before cleanup, including the tree-proof path, so concurrent new work invalidates the cleanup proof. Before #1372 the already-reconciled path never activated, and PRs #966 and #969 closed without their merge going live.

`activate()` selects the existing updater for the repository and reports its observed outcome. The two paths prove different things.

### Ordinary repositories: checkout currency

Before #1885, repositories without dotup received `activation: n/a`; that explicit message had replaced silence after seven papercuts from five repos in September 2026. They now use `activate_checkout()`, which reuses the installed sibling `launchpad-freshen.sh --repo "$repo"` **without `--heal`**. It preserves route and in-progress-Git guards, does not switch an off-default checkout, and never automatically stashes colliding edits. Unrelated canonical-checkout edits may survive a fast-forward.

If canonical HEAD already contains the known merge, no helper runs. Otherwise the helper is bounded by `WT_DONE_ACTIVATE_TIMEOUT` (default 90 s), its output is retained, and HEAD is independently re-read. The helper can exit zero after a refusal, so only merge ancestry establishes success:

```
activation: checkout current ($repo at <head>; includes <merge>)
```

If the merge remains absent, closeout reports `!! activation: checkout not current` and retains the actual helper diagnosis, including blocking paths. Inspect that output rather than a dotup service journal. This path establishes containment of the known merge—not freshness against every later upstream commit, a service restart, or runtime deployment. It creates no ordinary-repository timer. Dry-run never calls even the freshener's own dry-run mode, because that helper mode still fetches.

### Dotup-managed repositories: canonical harness activation

For a checkout identified by `dotup_managed()`, `activate()` first asks whether the merge commit is already applied:

```
git -C "$repo" merge-base --is-ancestor "$mc" "$head"
```

If it is, it prints and stops:

```
activation: live ($repo at <sha> already includes <mc>)
```

If not, it starts the existing unit and waits, bounded by `WT_DONE_ACTIVATE_TIMEOUT` (default 900 s):

```
timeout 900 systemctl --user start dotup-refresh.service
```

`dotup-refresh.service` is `Type=oneshot` with `TimeoutStartSec=15min` (`systemd/dotup-refresh.service`), so a closeout racing the hourly timer coalesces into the same run rather than double-running it. Starting that unit was already the sanctioned lever for forcing activation from a worktree-isolated session, used deliberately in place of `sync.sh install` before #915 wired it into the closeout (session history). The unit runs `dotup --no-doctor`, which under `flock` performs `repo_ff_update`, then `install.sh`, then `skills-localize.sh apply`, and records handled refresh outcomes in its status file. The updater tolerates unrelated edits and refuses divergence or ordinary incoming-path collisions. Dotup separately opts the derived `memory/` mirror into recovery and re-mirroring; that exception is not authority to discard other local files. Installation failure records `install-failed`; localization failure warns without necessarily changing the final result from `ok`.

`activate()` then re-checks ancestry and prints one of two literal receipts:

```
activation: live ($repo now at <sha>; dotup result=ok)
```

```
!! activation: $repo still at <sha> (dotup result=refused); the hourly timer will retry, and journalctl --user -u dotup-refresh.service has the reason
```

The same line can follow other results when the merge remains unapplied, including `locked`, `unverified` after an offline fetch, or `stale-status`. Ancestry determines the receipt, not the result label: `install-failed` can accompany `activation: live` after a successful fast-forward, or `!! activation:` when an offline fetch left the merge unapplied before installation failed. The hourly timer retries; it does not guarantee recovery. Read the journal to diagnose the cause, and ask for a local-file decision only when a refusal requires one. For a local-change refusal, the status file records `result=refused` but not the blocking paths; the journal names them in a `WARN: N locally-modified file(s) are in this update's path` line followed by the paths (seen 2026-09-23 for `scripts/backup-supabase.sh`).

A status-file timestamp older than the activation's own start is reported as `dotup result=stale-status`: the start coalesced into a run that began before this merge, so its result is not this merge's verdict (`activate()` in `scripts/wt-done.sh`). A `live` line proves canonical merge containment; it does not independently prove copied skills were installed or already-running consumers reloaded. The already-contained path skips dotup entirely. Verify the installed files and affected consumer when making a stronger deployment claim.

Activation refusal is printed but does not fail closeout's normal reconciliation result. The hourly dotup timer is a backstop only for dotup-managed repositories, and does not guarantee recovery.

Report the printed line, not your own guess. The always-on rule (`CLAUDE.md`, "Merge-anchored closeout") reads: "`wt-done` proves shipment via GitHub's exact merged head (`headRefOid == HEAD`), a merged head containing the tip, or an empty diff against the merge commit, then activates the canonical checkout and prints its `activation:` line — report that line, not your own guess. After a printed `!! activation:` line, `journalctl --user -u dotup-refresh.service` has the reason; if dotup refused to overwrite local changes, ask the operator for that one decision and re-run `wt-done` yourself once you have it, never a command for them to run."

If dotup refuses, the fix is on the checkout, not on the caller: `journalctl --user -u dotup-refresh.service` names the reason, and `repo_ff_explain` (`lib/repo-update.sh:112-183`) lists the exact untracked or modified paths blocking the fast-forward, with kind-labeled guidance (`lib/repo-update.sh:133-165`). Never fall back to telling the operator to run `sync.sh install`: that command symlinks `~/.claude` at whatever checkout it runs from (`dotup:46-55` states the same trap for `dotup` itself), which from a worktree silently repoints the live harness at a throwaway branch.

## Why This Works

The original gap was structural: the hourly refresh did not run at merge time, and nothing before #915 ran the localizer outside the 03:00 path. A worktree-isolated session could not repair it by directly pulling the shared checkout. The dotup activation branch therefore delegates canonical checkout updates to the existing systemd unit, reusing dotup's lock, fast-forward-only merge with autostash off, refusal semantics, status file and timeout. That does not mean `wt-done` is Git-read-only: its reconciliation path fetches, writes verified anchors and may soft-reset an identical-tree branch pointer. Since #1885 the ordinary-repository activation branch likewise reuses the existing safe freshener rather than inventing another updater.

Wiring `skills-localize.sh apply` into `dotup` closed the missing invocation in #915: merge-triggered and hourly refreshes attempt copied-skill deployment after installation. This is a recovery path, not proof that every installation or localization succeeded. The historical first live run took the canonical checkout from `0e44bd5` to `254955a` (PR #915) with `dotup result=ok`; the localizer step's first live run deployed six Codex skill forks the hourly-only path had never carried (session history).

Per this session's conclusion, the design was chosen by an 18-agent workflow (four candidate designs, three judges scoring 24.5/30 for this one, six refute-by-default verifiers, five confirmed) before landing as PR #915 (issue #909).

## Prevention

- After merging your own PR, run `DRY_RUN=0 ~/.claude/scripts/wt-done.sh` from inside the worktree and report its actual `activation:` outcome. Do not equate the merge record, a zero exit status, checkout currency and runtime deployment; verify the consumer-specific state needed for the claim.
- On a printed `!! activation:` line, inspect the freshener output for an ordinary repository or the service journal for dotup. If a refusal requires a decision about colliding local changes, ask for that one decision and re-run `wt-done` yourself once resolved. Do not automatically stash, discard or commit unrelated state. Do not hand over the re-run or ask for a file decision on a transient `locked`, `unverified`, or `stale-status` result.
- Tests enforce the receipt contract. `tests/wt-done.test.sh` carries these activation cases:
  - already live
  - behind, then live with dotup's result
  - refused without failing the closeout
  - stale status
  - dry run
  - `--reconcile-only` never activates
  - ordinary repositories: a real fast-forward carries unrelated local state; collisions preserve HEAD, bytes and stash state; no `--heal` or service start
  - helper false-success and timeout cannot manufacture a current-checkout receipt; route, parked-branch and in-progress-Git refusals remain intact
  - already-reconciled branches still resolve the relevant merged PR, including ordinary repositories; no merge or unrelated identity yields `n/a`, not a fabricated activation
  - ordinary exact-merge tips and descendant-head proofs work; missing/off-default merge objects cannot authorize refresh
  - dry-run does not invoke the freshener at all, reconcile-only does not activate, and concurrent commits invalidate cleanup proof

  The named cases in `tests/wt-done.test.sh` include the ordinary-repository handoff fixtures and the tree-proof activation race. Its planted negative still rejects `sync.sh install` in output. `hooks/tests/launchpad-advisory.test.js` covers bounded diagnostics, partial success, failed fetch with current cached refs, and preservation of colliding/unrelated state. `tests/dotup-deploy-loop.test.sh` checks that the localizer runs after installation and a localization failure warns without flipping `result=ok`. These are fixture contracts, not live-deployment evidence.
- Dotup-managed merges that bypass `wt-done` remain dependent on a later hourly refresh, with its delay and refusal limits. Ordinary repositories do not acquire that timer merely because closeout now freshens their checkout.
- Activation does not retrofit sessions that are already running: they cache hooks and settings until they restart, so a report may say the hook is live on the checkout and still name the sessions that have not picked it up (session history).
- Any fail-closed check added to the unattended path (`install.sh` preflight, a new guard in `dotup`) has to carry the environment the interactive shell had when it was tested, or the hourly refresher becomes a silent outage (PR #544; session history).

## Related Issues

- dotfiles#909 (the gap; its comments carry the forensics and the first live run), dotfiles#915 (the original fix), dotfiles#1372 (the historical `n/a` line and activation on the already-reconciled path), dotfiles#1883 / PR #1885 (ordinary-repository checkout activation and truthful refresh diagnostics), dotfiles#918 and dotfiles#920 (the always-on rule agents read), dotfiles#355, #508, #510, #893 (the incidents).
- dotfiles#479 and PR #480 (the root ancestor: source-tree-pure install, fail-closed `dotup`, the refresh timer), #485 (the untracked-file blocker classifier), #544 (the unit's PATH), dotfiles#596 (wt-done proves shipment via `headRefOid`, the proof machinery `activate()` runs after), dotfiles#842 (the same shape one step earlier: disposal folded into wt-done and wt-sweep so no outside re-run is handed back), dotfiles#409 (the positive handoff protocol, source of the hand-back vocabulary).
- Vocabulary: `CONCEPTS.md` defines *Hand-back*, *Valid exit*, and *Activation receipt* under "Turn-end contract".
- Sibling learnings: [Enabling a consent-gated daemon takes two keys](../best-practices/enable-consent-gated-daemons-with-two-keys-not-one.md) (a status surface reports success while a second gate is still unset; check the dedicated verifier, not the surface), [Diagnose plugin behavior against the installed version, not caches](../best-practices/diagnose-against-installed-versions-not-plugin-caches.md) (resolve what is actually running before trusting what exists in source), and, for where the rule and the mechanics belong, [Demote always-loaded agent context without losing operational authority](../best-practices/demote-always-loaded-context-without-losing-authority.md).
