---
title: "Eliminate Supabase zombies without restarting WSL"
date: "2026-09-13"
category: runtime-errors
module: docker-container-lifecycle
problem_type: runtime_error
component: infrastructure
severity: medium
symptoms:
  - "303 exited Node processes remained as zombies beneath eight Supabase application PID-1 processes"
  - "A blind Docker restart could stop AutoRemove PostgreSQL containers holding anonymous data volumes"
  - "Image-default healthchecks differed from the probes configured on deployed containers"
root_cause: config_error
resolution_type: config_change
framework_version: "Docker Engine 29.7.2 on WSL2 Ubuntu"
tags:
  - docker
  - supabase
  - zombies
  - pid-1
  - live-restore
  - autoremove
  - wsl
  - healthcheck
---

# Eliminate Supabase zombies without restarting WSL

## Problem

The WSL host retained 303 exited Node processes beneath eight Supabase Studio and metadata containers whose applications ran as PID 1 without an init reaper.
The fix needed to prevent orphan accumulation without restarting WSL or sacrificing other containers' state.

## Symptoms

- All 303 zombies were owned by the eight application PID-1 processes. They consumed no resident memory; this was a lifecycle defect, not evidence of 303 live Node applications or a demonstrated RAM bottleneck.
- Maintenance preflight found 91 containers, 83 running, and 190 volumes. Two running PostgreSQL containers combined `AutoRemove=true` with anonymous data volumes, making an indiscriminate stop a possible data-loss path.
- The deployed Supabase CLI healthchecks differed from the images' default healthchecks.

## What Didn't Work

- **Killing zombie PIDs:** a zombie has already exited. Its parent must reap it, or the parent/namespace must exit.
- **Recycling as the permanent fix:** restarting a container clears its current zombies but does not add an orphan reaper for future children.
- **Blind daemon or WSL restarts:** these were rejected, not attempted. WSL shutdown was unnecessary and unapproved; stopping the auto-remove databases was unsafe.
- **Validating the image's probe instead of the deployed probe:** Supabase CLI had overridden the image default. The runtime test was corrected to bind both image identity and healthcheck to a source container inspected read-only; see `tests/docker-init-runtime.test.sh:281-299`.

## Solution

The implementation shipped in PR #1149.
The separately approved September 12 maintenance used this order:

1. Inventory current container IDs, running PIDs, mount/volume identities, restart policies, auto-remove settings, and health checks.
2. Enable Docker live restore by **reload**, then verify `LiveRestoreEnabled=true` before restarting the daemon. This was a separate operator-approved host setting, not an implicit addition to the init-only policy.
3. Adopt `init: true` through the reviewed helper and restart **Docker only**. The helper manages only that key and preserves unrelated settings, including live restore (`scripts/docker-daemon-config.py:101-106`, `scripts/docker-daemon-config.py:650-657`).
4. Verify that all 83 original running containers retained their PIDs across the daemon restart. Then restart only the eight affected stateless Studio/metadata containers and require healthy status plus `docker-init` as namespace PID 1.
5. Verify inheritance with a null-init fixture created before activation, a newly created null-init fixture, and an explicit-false control. Remove only the recorded, ownership-verified fixtures.

The observed endpoint was zero host zombies, with all 91 original containers and 190 volumes preserved and the WSL boot ID unchanged.
Only the eight approved stateless PIDs changed; databases did not restart.
Compare mount **identities**, not listing order: Docker reordered some mount arrays without changing any mount.

Use the [operational runbook](../../../harness/docker-lifecycle.md) for command details, approval boundaries, and rollback rather than duplicating that procedure here.

## Why This Works

An init process can reap orphaned children adopted by it.
It cannot reap a child still owned by a living, non-reaping application.
The controlled test demonstrated that distinction: for each of the two deployed image classes, 20 orphan cycles left 20 zombies without init and zero with init; a direct-child counterexample remained under its living parent.
The local HTTP responder was test input, not production-service proof.

On Docker 29.7.2, a private-PID container with unspecified `HostConfig.Init` can inherit the daemon default **when started**, even if it was created before activation.
The old and new null-init fixtures both started with `docker-init`; the explicit-false fixture stayed `node`.
This agrees with [the installed Docker revision's runtime construction](https://github.com/moby/moby/blob/6a43e3d/daemon/oci_linux.go#L728-L744).
A null stored field therefore does not prove init is absent, and universal container recreation is unnecessary for this case.
Observe the actual namespace PID 1.

## Prevention

- Preserve explicit per-container opt-outs and unowned daemon settings. Do not replace an existing daemon configuration with a two-key example.
- Inspect auto-remove and storage ownership before maintenance. Verify live restore is active before relying on it to preserve running containers; it is not a replacement for backups.
- Keep the existing stateless recycle allowlist, active-work protection, and prohibition on automated volume deletion. Do not add a zombie-killing cron or another maintenance daemon.
- Keep configuration publication, daemon-loaded configuration, and effective container behavior as separate evidence levels.

**Limits:** The controlled experiment does not establish who created every historical zombie, prove arbitrary direct-child leaks are fixed, or prove database contents from volume identity alone.
Issue #1138 remains open for the first natural scheduled post-deployment hygiene observation, due September 16.
Neither the successful maintenance nor one later scheduled run proves weeks of unattended reliability.

## Related Issues

- [Original implementation plan](../../plans/2026-09-12-1803-fix-workstation-container-hardening-plan.md) — a historical decision record; do not rewrite its completion criteria to match an early closeout.
- [State-surface verification](../best-practices/verify-a-ledger-inferred-backlog-against-the-engines-state-surface.md) — use current identities rather than reconstructing state from old reports.
- [Falsifiable assertions](../best-practices/make-test-assertions-falsifiable-by-the-defect-they-guard.md) — the no-init and direct-child controls prevent false confidence in reaping tests.
- [Docker live restore](https://docs.docker.com/engine/daemon/live-restore/) — supported activation and operating limits.
