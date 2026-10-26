---
title: "A systemd user unit with an env -i allowlist cannot reach the user bus"
date: 2026-10-05
category: integration-issues
module: pr-owner-closeout-activation
problem_type: integration_issue
component: development_workflow
symptoms:
  - "`systemctl --user start dotup-refresh.service` inside the pr-owner unit prints `Failed to connect to bus: No medium found` and exits 1"
  - "Each owner closeout before the fix (#1540, #1541, #1563) had `wt-done` print `!! activation: /home/user/hov-stack still at <sha> (dotup result=stale-status)`, so a merge the owner made stayed inert until the hourly dotup timer ran"
  - "The stage-1 suites passed; only the plan's live check (owner-merged #1540 and #1541) showed it"
root_cause: config_error
resolution_type: code_fix
severity: medium
related_components:
  - pr-handoff.sh
  - pr-owner.sh
  - pr-owner-state.sh
  - wt-done.sh
  - dotup-refresh.service
tags: [systemd, user-manager, xdg-runtime-dir, env-allowlist, pr-owner, activation, systemd-run]
---

# A systemd user unit with an env -i allowlist cannot reach the user bus

> **Status 2026-10-18.** The owner scripts this entry cites (`pr-handoff.sh`, `pr-owner.sh`) were removed by #1873 on 2026-10-17, and nothing launches an owner unit any more; the Merge-and-end rule in `CLAUDE.md` replaced the fleet. Read their file:line citations below as pre-removal history. They were written against #1548's tree and had already drifted before #1873 (the `OWNER_RUNTIME_DIR` lines sit at `pr-owner.sh:1358-1359` in `dd68bf5a^`). `scripts/lib/pr-owner-state.sh` survives, with `pr_owner_command` now at `:235-242` and the `XDG_RUNTIME_DIR` validation at `:214-219`, but nothing calls either function. The lesson still applies to `scripts/wt-done.sh:629`, which starts `dotup-refresh.service` with `systemctl --user` from whatever environment the closing session has. A session without `XDG_RUNTIME_DIR` (a headless or `env -i` one) can fail the same way.

## Problem

The PR-owner unit runs its command under `env -i` with a short allowlist, and that allowlist dropped `XDG_RUNTIME_DIR`. The owner's closeout calls `systemctl --user start dotup-refresh.service` to activate the merge, and without the variable it cannot find the user manager. No owner-merged PR activated on the host until #1548 fixed it (issue #1543).

## Symptoms

- `systemctl --user` prints `Failed to connect to bus: No medium found` and exits 1.
- Each owner closeout printed `!! activation: /home/user/hov-stack still at <old sha> (dotup result=stale-status)`. That held for #1540 and #1541, per #1548's description. #1563's owner still printed it on 2026-10-05, because it was running scripts from before the fix.
- The merge stays inert until the hourly `dotup-refresh.timer` runs, or until a session runs `wt-done` by hand.

## What Didn't Work

- **Reading the error literally.** "No medium found" says nothing about a missing variable. It is what `systemctl --user` prints when `XDG_RUNTIME_DIR` is unset. On this host, `env -i PATH=/usr/bin:/bin HOME=$HOME systemctl --user is-system-running` prints it. The same call with `XDG_RUNTIME_DIR=/run/user/$(id -u)` added reaches the manager and prints its state.
- **Blaming `systemd-run --user`.** The user manager's own environment carries the variable: `systemctl --user show-environment` lists `XDG_RUNTIME_DIR=/run/user/1001`, and a unit inherits it. Our own `env -i` drops it. The allowlist exists because `--setenv` alone cannot clear the manager's environment (`scripts/lib/pr-owner-state.sh:235-242`, `pr_owner_command`).
- **Recording the key at handoff only.** That was the first version of #1548. Pro round 1 found a P1 in it. A record written before the change has no key, and when recovery replays it, the closeout still runs without the bus. The fix added a runtime fallback to the account's own directory.
- **Ignoring version skew.** The cross-model `/ce-code-review` pass on #1548 found this. A launcher run from a newer checkout still starts the *installed* owner, and the installed recovery replays the record it writes. An older installed library would reject the new key, so recovery would park the PR. An older owner would also hand the bus on to its fix sessions.

## Solution

There are four parts, all in #1548:

1. **The handoff takes the value from the account, never from the caller** (`scripts/pr-handoff.sh:85`):

   ```bash
   --arg bus "/run/user/$(id -u)" \
   '{PATH:$path,HOME:$home,PRO_GATE_HOME:$runtime,ANTHROPIC_BASE_URL:$url,XDG_RUNTIME_DIR:$bus} + ...'
   ```

2. **Validation accepts the key only at the service user's own directory** and keeps it optional, so older records still recover (`scripts/lib/pr-owner-state.sh:214-219`).
3. **Only the closeout's activation gets the bus.** At startup, `pr-owner.sh` moves the variable aside (`scripts/pr-owner.sh:449-450`):

   ```bash
   OWNER_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$EUID}
   unset XDG_RUNTIME_DIR
   ```

   It exports the variable again only inside the `wt-done` command substitution (`scripts/pr-owner.sh:172`). Reviews, fix sessions and CI repair keep the environment they had before, without the bus.
4. **The launcher checks the record against the installed library** (`scripts/pr-handoff.sh:99-111`). If that library rejects the key, the launcher drops it and validates again. Any other refusal still stops the handoff.

## Why This Works

`systemctl --user` needs `XDG_RUNTIME_DIR` to find the user manager. With the variable set, the same bare `env -i` call connects. Scoping the variable to the closeout subshell leaves what a fix session can reach unchanged, which was a stated constraint of #1548. Deriving the value from `id -u` means a caller cannot point the owner at another account's runtime directory.

## Prevention

- When a script builds a unit's environment with `env -i` or any other allowlist, check each later step for calls into the user session. Any `systemctl --user` call needs `XDG_RUNTIME_DIR`. In the reproduction above, that variable alone was enough.
- Give the variable only to the step that needs it, and take its value from the account, not from whoever launched the unit.
- When a launcher writes a record that an installed version of another script will replay, validate the record with that installed version's validator, not the checkout's.
- A fixture that stubs `systemctl` cannot catch this, and a live check did. Keep a live check that runs the real activation and quotes its `activation:` line.
- The same class of bug, a user unit's environment differing from a login shell's, also hit docker-hygiene. There, a user unit had no `PATH` entry for `supabase` (issue #1555, closed 2026-10-05).

## Verification Status

As of 2026-10-05, #1548 is merged and installed (dotup reported the canonical checkout at the merge of #1551, which includes it). No owner closeout has printed `activation: live` yet, because the owners that merged since then were running older scripts. Issue #1543 closed when #1548 merged, but its acceptance check has not run yet. That check is the first owner handed off after installation that merges a PR. It is now moot: #1873 removed the owner fleet on 2026-10-17, and the activation path that remains is `wt-done.sh` run by the closing session.

## Related Issues

- [Drive and verify post-merge activation instead of handing the operator a command](drive-post-merge-activation-instead-of-handing-back.md): the activation path this broke.
- [network-online.target does not exist in the user manager](network-online-target-does-not-exist-in-the-user-manager-gate-readiness-in-the-script-instead.md): another wrong assumption about the user manager.
- Issue #1543, fixed by PR #1548. Issue #1555 is the docker-hygiene `PATH` case.
