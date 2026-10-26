---
title: "A permissions entry added to the tracked settings.json never reaches the live file; the drift remedy would delete it"
date: "2026-10-13"
category: integration-issues
module: claude-harness-settings-sync
problem_type: integration_issue
component: development_workflow
symptoms:
  - "A merged, activated PR adds `Bash(vastai:*)` and `Bash(vast-ssh:*)` to `settings.json` permissions.allow, yet `grep vastai ~/.claude/settings.json` finds nothing on the host that merged it"
  - "The owner's post-merge check after PR #1742 exited 1 with `{\"ok\":false,\"stage\":\"settings\",\"code\":\"confirm_ask_rules_missing\"}`: nine Resend ask rules were tracked and none were live (dotfiles#1778)"
  - "`sync.sh check` prints `DRIFT: settings.json differs from repo copy beyond ad-daemon-owned keys (sync.sh push)`, and harness-doctor check 11 says `.permissions drifted from dotfiles copy — review then sync.sh push`"
  - "Running the recommended `sync.sh push` would copy the live file over the tracked one and remove the new entries from the repo"
  - "An allow entry from an earlier PR (`Bash(discord-cli api GET:*)`, dotfiles#1622) is still tracked-only"
root_cause: missing_workflow_step
resolution_type: config_change
severity: high
framework_version: "claude-code 2.1.x; dotfiles sync.sh and harness-doctor.sh at main 0c845c73 (2026-10-13)"
related_components:
  - "sync.sh"
  - "scripts/harness-doctor.sh"
  - "hooks/PreToolUse/settings-guard.js"
  - "dotfiles#1769"
  - "dotfiles#1622"
  - "dotfiles#1392"
  - "dotfiles#1742"
  - "dotfiles#1775"
  - "dotfiles#1778"
tags:
  - settings-json
  - volatile-file
  - permissions-allow
  - permissions-deny
  - permissions-ask
  - sync-push
  - settings-guard
  - live-vs-tracked
---

# A permissions entry added to the tracked settings.json never reaches the live file; the drift remedy would delete it

## Problem

In this repo `settings.json` is a **volatile file**: Claude Code rewrites the live `~/.claude/settings.json` atomically, so it cannot be a symlink, and `sync.sh` treats the live copy as authoritative once it exists. `install` seeds the file only when the host has none (`sync.sh`: "Never clobber a live config"), `push` copies live over tracked (stripping the proxy key on the way, with a shrink guard), and `check` reports any other difference as drift to be resolved by `push`. The tracked file is therefore a capture of live, not a source. An agent that adds a `permissions.allow`, `permissions.deny` or `permissions.ask` entry in a PR edits the capture. The PR merges green, the checkout activates, and the entry is absent from every host that already has a live file, including the one that merged it. The drift the doctor then reports names `sync.sh push` as the remedy, and push would remove the entry from the repo too.

The harness closes the same gap for **hooks** and the harness env keys: `sync.sh` has `reconcile_hook_group` and a family of `reconcile_*_hook` functions (for example `reconcile_dcg_hook`, `reconcile_shape_rewrite_hook`), plus `reconcile_runtime_env` (CLI spelling `reconcile-runtime-env`). `sync.sh install` calls them, so a host merges those keys into its own live file whenever it runs install (backup, jq, atomic replace); dotup activation runs `install.sh`, which calls `sync.sh install`. That is a code reading, not a per-host verification. On the permissions side there is one exception: the settings reconcilers carry the single bare `EnterPlanMode` deny (dotfiles#1392), and harness-doctor tells the operator to run `install`, "never sync.sh push", for that entry. No reconciler merges any other allow, deny or ask entry.

## Symptoms

- dotfiles#1769 shipped `Bash(vastai:*)` and `Bash(vast-ssh:*)` in the tracked file. After merge and dotup activation the live file had 295 allow entries and neither of them (the count recorded when this doc was first captured, #1772).
- dotfiles#1742 shipped nine Resend ask rules (`Bash(resend-cli *--confirm-{send,write,destructive}*)`, the same three with a leading `Bash(*resend-cli ...`, and three `Bash(*resend_cli.py *--confirm-{send,write,destructive}*)`). The tracked ask list went from 66 to 75 in the merge (`de953261`); the live list stayed at 66. The PR owner's post-merge check then failed with `confirm_ask_rules_missing` (dotfiles#1778).
- `sync.sh check` and harness-doctor check 11 both flag this kind of drift, both with `push` as the remedy.
- dotfiles#1622's `Bash(discord-cli api GET:*)` showed the same state and is still tracked-only, so this is a class, not a one-off.
- Nothing in CI or at activation detects the class (#1775's wording): the tracked file is valid and the install smoke passes. `sync.sh check` and harness-doctor compare the two files, but they are operator checks with `push` as the remedy. The ask case was caught because the PR owner's post-merge check for #1742 asserted the ask rules were live.

## What Didn't Work

- **Expecting activation to deliver the entry.** `install` links the stable surfaces (hooks, scripts, bin, skills) and, for a volatile file, seeds only a missing one (`[ -f "$H/$f" ] || cp ...`). It never merges into a present one. This is why #1778's nine ask rules were absent after the checkout activated.
- **Reading the drift line as "run push".** For an entry the operator approved interactively in Claude Code (which writes live first), push is right: it captures live into the repo. For an entry that originated in a PR it is backwards. The line cannot tell the two apart because it compares the files, not the direction the change came from.
- **Routing around the settings-guard ask through Bash.** `hooks/PreToolUse/settings-guard.js` asks on any Edit, Write or MultiEdit to a permission-surface file. Its header says Bash is deliberately not gated, as a matter of general shell autonomy. That is not a route for a permission-surface change. A denied or unanswered ask is not a reason to retry the same change through the shell.

## Solution

### Current host: the guarded Edit

Apply only the tracked-only entries to the live `~/.claude/settings.json` with the Edit tool. settings-guard raises an ask, and that ask is the approval point for a permission-surface change (the global instructions classify editing the permission surface as security-posture, ask first). Add only what is missing, keep every existing entry, and compare the allow, deny and ask counts before and after.

The record is #1778: the nine Resend ask rules were added through the guarded Edit path, preserving all prior entries (allow 297 -> 297, deny 70 -> 70, ask 66 -> 75). The 66 -> 75 transition is the parent session's observed evidence, as #1778 says; #1778 does not record who answered the settings-guard ask. The stored post-merge check then passed. An independent verifier re-ran both installed checks at merge revision `de953261b4efd0a010a6d563ac8d296ac711a1ee`; both exited 0 (last real read 2026-10-14T01:27:32Z UTC), and it verified the current counts and all nine rules, not the earlier transition.

If the ask is denied or unanswered, the entry stays tracked-only on that host. Say so in the PR or issue. Do not apply it another way.

### What #1769 ran, and the shape a reconciler would take

This is history and reconciler design, not the route this doc recommends for an agent applying an entry by hand. #1769 applied its two allow entries with an untracked Bash/jq script (`~/.claude/jobs/<job>/tmp/apply-vastai-allow.sh`), taking live allow entries from 295 to 297 with a backup kept (`~/.claude/backups/vastai-allow-20261013T235626Z/`). settings-guard does not gate Bash, so no ask fired for that write. The #1769 PR body records that the operator asked for the widening. The verbatim script is kept as evidence in this doc's first version (`git show 93a9407626a9da226f0acb8499a684664a356266:docs/solutions/integration-issues/a-permissions-entry-added-to-the-tracked-settings-json-never-reaches-the-live-file.md`). Do not reuse it to avoid the settings-guard ask.

Its shape is what a reconciler in `sync.sh` would do, and what the existing hook reconcilers already do:

1. Back up the live file.
2. Add only the entries that are absent, keeping every existing entry and its order.
3. Prove nothing outside the edited list changed.
4. Replace the file atomically.

### Current host versus other configured hosts

The guarded Edit changes only the live file on the host where it runs; #1742's merge went live on `workstation` (#1778). Nothing carries a permissions entry to any other configured host. `install` has no permissions reconciler, so a later dotup activation elsewhere will not add it. Hooks and the harness env keys differ by code: `install` calls their `reconcile_*` functions, so each host that runs install merges them into its own live file. Neither this doc nor #1778 verified that on any host; it is a code reading (`sync.sh install` calls the reconcilers). Each other host needs its own guarded step, and #1778 verified none.

### Durable fix status

dotfiles#1775 proposed a `reconcile_permissions` in `sync.sh` and a harness-doctor line naming tracked-only entries. It was closed NOT_PLANNED at 2026-10-14T00:46Z (UTC) on the operator's call. Its closing comment reasons: the only tracked-only entry then was `Bash(discord-cli api GET:*)`, an allow rule; the deny lists matched (70 on both sides); the tracked `defaultMode` is `bypassPermissions` and the enforced floor is the root-owned managed settings, so both remedies would govern a list that is inert in that mode. Neither remedy exists in the repo (check 11 is still a whole-object compare).

#1775's closing comment calls one smaller change worth adding when a future `sync.sh` PR touches push: make `sync.sh push` refuse to drop tracked-only `permissions.allow`/`permissions.deny` entries unless an explicit flag says so, because push is the only destructive path in this class. No issue or PR for it exists.

Do-not-retry predicate (see CONCEPTS.md): do not re-propose the reconciler or doctor line unless a host runs default or ask mode, or a PR adds a deny entry that must reach live. #1775's text names allow and deny only; ask entries were not part of that decision, and this doc does not decide whether #1778 reopens it.

## Why This Works

The live file is rewritten by Claude Code (and by the statusline daemon, sub-second, for `statusLine`/`spinnerVerbs`), so it can only be a regular file, and the repo can only hold a copy. The harness chose "live is authoritative" for that copy because most of its keys originate in the running client: interactive permission approvals, model and effort choices, plugin toggles. Security-relevant entries that originate in the repo need a deliberate apply, because the copy direction is wrong for them. Hooks got reconcilers for that reason; ordinary permissions entries did not.

The guarded Edit puts the human approval where the harness puts permission-surface changes. Add-only keeps the daemon's keys and the operator's approvals intact, so it does not fight the sub-second rewrites. It is per host: it changes the one live file it touches and nothing else.

## Prevention

- **When a PR adds to `permissions.allow`, `permissions.deny` or `permissions.ask` in `settings.json`, treat the tracked edit as half the change.** The PR body says how the entry reached live on the merging host (guarded Edit, through the settings-guard ask) and that other hosts are not covered. A green merge plus activation does not deliver it.
- **Read the two drift lines by origin, not by text.** `settings.json .permissions drifted ... sync.sh push` is correct when live gained the entry (operator approval) and destructive when tracked did (a PR). Before any push, diff the tracked and live rule lists in both directions; anything tracked-only is a PR entry that push would delete.
- **The same rule covers `.hooks`, `.env`, `enabledPlugins` and `skillOverrides`**, the keys check 11 compares. Hooks and the harness env keys already have reconcilers; a new key of either kind needs one before it is relied on.
- **Mode.** #1775's closing reasoning is that a missing allow entry is inert under `bypassPermissions`; this doc does not test it. A missing deny entry is a gap in whatever mode honors it. The `sync.sh` comment above `denies_enter_plan_mode` gives the motive for the one deny that has a reconciler: a model-initiated EnterPlanMode call drops a session out of bypass permissions (dotfiles#1392). That gap is why this class is rated high.
- **Missing ask entries: do not extend the inert reasoning in either direction.** #1778 verified disk rules and registered hook simulations, not a fresh Claude permission dialog or already-running sessions' cached settings.

## Related Issues

- `docs/solutions/integration-issues/retire-a-hook-twin-by-name-before-changing-its-verdict.md`: the hook-side statement of the same fact ("ask whether the tracked file edit can reach the host at all"), with the by-name retirement a reconciler needs.
- dotfiles#1742 (the Resend feature whose nine ask rules were tracked-only after merge).
- dotfiles#1778 (the ask instance and the guarded-Edit remedy, 66 -> 75).
- dotfiles#1775 (the reconciler and doctor-line proposal, closed not planned 2026-10-14T00:46Z UTC).
- dotfiles#1769 (the vastai allow entries and the hand-applied merge), dotfiles#1622 (the earlier tracked-only entry), dotfiles#1392 (the EnterPlanMode deny reconciler and the "never push" remedy wording in harness-doctor).
- `HARNESS.md`, "Autonomy & permission model": the enforced tiers are the live `~/.claude/settings.json` plus the managed floor and git-guard; the tracked copy is "drift enforcement", which is the reason the direction matters.
