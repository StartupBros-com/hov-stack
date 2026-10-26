---
title: "Enabling a consent-gated daemon takes two keys: the service unit and the versioned consent record"
date: 2026-09-02
category: best-practices
module: pro-gate-daemon-runtime
problem_type: best_practice
component: development_workflow
root_cause: incomplete_setup
resolution_type: config_change
severity: medium
applies_when:
  - "Turning on a daemon or timer whose privileged mode is gated by an operator-consent record separate from the unit's enablement"
  - "A freshly enabled service reports active (running) while its journal says it is deferring or refusing all work"
  - "An installer's opt-in flag both records consent and re-runs privileged deployment steps you do not want repeated"
  - "An auto-updater for the same runtime starts refusing updates right after the daemon was enabled"
related_components:
  - "pro-gate-runtime"
  - "oracle-bridge"
  - "harness-runbooks"
tags:
  - consent-gate
  - daemon-enablement
  - systemd
  - pro-gate
  - dangerous-mode
  - two-key
---

# Enabling a consent-gated daemon takes two keys: the service unit and the versioned consent record

## Context

Step 0 of the ChatGPT Pro capacity-lanes build order (umbrella issue #849) called for enabling `pro-review-daemon.service` for a one-week measurement on 2026-09-02. `sudo systemctl enable --now` succeeded and `systemctl status` reported `active (running)`, yet the daemon's first journal lines were `FATAL: operator consent v1 is required before automatic fixer execution with --dangerously-skip-permissions` followed by `privileged runtime unavailable; globally deferring PR processing`. The unit was on; the daemon was doing nothing. The harness runbook `harness/oracle-pro-extended-setup.md` described the daemon and its guardrails but never named the consent record as a separate switch; its correction is pending in #872.

## Guidance

Treat a consent-gated daemon as a two-key system, and verify with the runtime's own doctor rather than the service manager.

1. **Enable the unit (key one).** For pro-gate on WSL this is the system unit `pro-review-daemon.service`.
2. **Record versioned consent (key two).** The installed pro-gate runtime reads `${XDG_CONFIG_HOME:-$HOME/.config}/pro-gate/dangerous-mode-consent` and accepts only when the file's trimmed content equals the expected consent version, `1` at the time of writing. The check is `pg_dangerous_consent_ok` in the installed runtime's `lib.sh`, and the daemon re-evaluates it on every poll: it resumed on its own, logging `privileged runtime ready; resuming PR processing`, three minutes after the file appeared, with no restart.
3. **Verify with the doctor.** `~/.pro-review-daemon/pro-gate-doctor.sh` prints `dangerous automatic-fixer disclosure accepted (consent v1)` when both keys are present and `daemon/dangerous mode disabled until operator consent v1 is recorded` when only the unit is on. `systemctl status` cannot tell these two states apart.

**Record consent the way the installer does, without the installer.** `install.sh --daemon --accept-dangerous-mode` prints the disclosure and atomically writes the version to the consent file, but the same invocation also renders the service units through `sudo tee`, reloads systemd, and runs `systemctl enable --now` for the browser session, the daemon, and the auto-update timer. When the runtime is already deployed at the installed version, writing the consent file directly is the equivalent of the consent branch alone. Show the operator the disclosure text first; the consent is theirs to give, not the agent's.

**Expect the auto-updater to refuse while the keys disagree.** `pro-gate-autoupdate.sh` declines any update when the daemon is enabled but consent is not recorded, so an enabled-without-consent daemon quietly freezes the runtime version until consent lands or the daemon is disabled again.

## Why This Matters

The failure is quiet in the one place operators look. The service manager reports a healthy process because the daemon deliberately stays up and keeps polling while it defers; only the journal and the doctor say why nothing happens. Left that way for a measurement week, the week measures nothing, and the auto-updater stalls on top of it. The consent record is machine-global and versioned on purpose: a consent-version bump un-arms the daemon until a human re-accepts, so a runbook that says "enable the service" without naming the consent step will fail again after the next bump.

## When to Apply

- Enabling pro-gate's review daemon on any host, including reactivation after a deliberate disable.
- Any harness daemon or timer that carries a separate operator-acknowledgment gate for a privileged mode, such as skip-permissions fixers or production-write lanes.
- Diagnosing a service that is active but idle: read its journal for a consent or disclosure line before suspecting the workload.

## Examples

Before: `sudo systemctl enable --now pro-review-daemon.service` gives `Active: active (running)`; the journal shows `FATAL: operator consent v1 is required…` and then `globally deferring PR processing` on every poll; `no PRs pending` never appears.

After: the operator accepts the disclosure and `1` is written to `~/.config/pro-gate/dangerous-mode-consent`; the next poll logs `privileged runtime ready; resuming PR processing`; the doctor prints the accepted-disclosure line; labeled PRs are picked up. The first poll after consent reported `no PRs pending` because the only `pro-review`-labeled PR was a draft whose head was already recorded in the daemon's per-SHA `processed.tsv`, which is the designed idempotency, not a third gate.

## Related

- `harness/oracle-pro-extended-setup.md` — the runbook this learning corrects; fix pending in #872.
- `harness/pro-capacity-lanes.md` — where the daemon sits in the Pro-lane routing; merged in #851.
- Umbrella issue #849, step 0.
- `docs/solutions/best-practices/diagnose-against-installed-versions-not-plugin-caches.md` — same runtime, same rule: the consent check quoted here is from the installed 0.38.0 runtime, and the `~/SITES/pro-gate` checkout is older.
