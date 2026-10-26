---
title: "Retire a hook's second live registration by name before changing its verdict"
date: "2026-09-05"
category: integration-issues
module: claude-harness-hook-registration
problem_type: integration_issue
component: development_workflow
symptoms:
  - "A PreToolUse guard rewritten to return `updatedInput` instead of `deny` still denies on the live host, with the old denial text, even though the repo copy has the new code and the hook suite is green"
  - "`~/.claude/settings.json` lists the same guard basename twice under one matcher: the canonical `~/.claude/hooks/...` path and a per-host routing-bundle path under `~/.local/share/claude-routing/<sha>/hooks/...`"
  - "Removing the duplicate registration from the tracked `settings.json` merges green and activates, yet the live file still carries both registrations afterwards"
  - "The sync smoke floor fails with `host-local allowlist entry matches no registration and should be removed` once the tracked registration is gone"
root_cause: config_error
resolution_type: code_fix
severity: high
framework_version: "claude-code (2026-09-05 build); dotfiles sync.sh reconcile"
related_components:
  - codex-quota-guard
  - claude-sync-reconcile
  - sync-install-smoke-test
  - claude-routing-bundle
tags:
  - hooks
  - pretooluse
  - updatedInput
  - settings-json
  - reconcile
  - routing-bundle
  - twin-registration
---

# Retire a hook's second live registration by name before changing its verdict

## Problem

Dotfiles issue 991 changed `hooks/PreToolUse/codex-quota-guard.js` from "deny when the Codex window is out" to "rewrite the command onto the best available model, deny only when nothing is open". The rewrite is the documented `hookSpecificOutput.updatedInput` shape (house precedent: `hooks/PreToolUse/structured-output-unwrap.js` and `heavy-job-admission.js`). Unit and fixture tests were green, yet on the live host an exhausted window still produced the old denial.

Two facts combined to make the new verdict unreachable:

1. **The guard was registered twice.** `settings.json` carried the canonical registration and a second one pointing at the 2026-08-26 routing rollout's frozen copy under `~/.local/share/claude-routing/<sha>/hooks/PreToolUse/codex-quota-guard.js`. Claude Code runs every matching PreToolUse hook, and a `deny` from any of them wins over another hook's `updatedInput`. The older copy denied first; the rewrite never took effect.
2. **The tracked settings hunk could not reach the host.** `~/.claude/settings.json` is in `VOLATILE_FILES` in `sync.sh`: install seeds it only when the live file is absent. The only code that edits a live registration for this hook, `reconcile_hook_group` (called from `reconcile_codex_quota_hook`), retires a same-basename twin **only when the twin's target file is absent from disk**. That rule exists so a moved hook's stale spelling is provably dead before it is removed; a twin that is present but superseded is exactly the case it declines to touch. The routing-bundle file exists, so the twin survived every install.

The adversarial review of the change (five lenses, refute-by-default verification) found the second fact before merge; the first was visible from the settings diff.

## Solution

Retire the twin **by name** in the hook's own reconciler, and keep the generic rule as it is.

`sync.sh` gained `codex_quota_routing_twins()`, which enumerates live `PreToolUse` registrations whose target sits under `~/.local/share/claude-routing/<hex>/hooks/PreToolUse/codex-quota-guard.js` (matched by path shape, never a hardcoded bundle sha), and `reconcile_codex_quota_hook()` passes them to `retire_hook_commands` alongside the two legacy doghouse commands it already retired:

```bash
codex_quota_routing_twins() {
  local live=$H/settings.json
  [ -f "$live" ] || return 0
  jq -r '.hooks.PreToolUse[]?.hooks[]? | .command // empty' "$live" 2>/dev/null \
    | grep -E '/\.local/share/claude-routing/[0-9a-f]+/hooks/PreToolUse/codex-quota-guard\.js"?$' || true
}

reconcile_codex_quota_hook() {
  local -a twins=()
  reconcile_hook_group "codex-quota" PreToolUse "$CODEX_QUOTA_HOOK_COMMAND" || return 1
  mapfile -t twins < <(codex_quota_routing_twins)
  retire_hook_commands "legacy codex-doghouse / routing-bundle codex-quota twin" \
    "$CODEX_LEGACY_PRE_HOOK_COMMAND" "$CODEX_LEGACY_POST_HOOK_COMMAND" "${twins[@]}"
}
```

`retire_hook_commands` already backs the live file up (`~/.claude/backups/hook-retire-<ts>-*`), strips exact command strings from every event, and leaves unrelated hooks alone. The bundle **file** is never touched; its statusline half stays in use.

Three companion edits kept the change honest:

- the duplicate registration was removed from the tracked `settings.json`, so a fresh seed matches the reconciled state;
- the host-local allowlist entry for routing-bundle hook paths was dropped from `tests/sync-install-smoke.test.sh` (`HOST_LOCAL_OK`), because that floor fails by design on an entry that matches nothing;
- the smoke test registers a routing twin **with an existing target file** in a fixture live settings and asserts it is retired, the file is preserved, and an unrelated hook survives.

Activation then proved it end to end: after the merge, `wt-done` ran the dotup install, the live settings held exactly one `codex-quota-guard.js` registration, and the backup of the previous file sat under `hook-retire-20260904-212709-*`.

## Prevention

Before changing what a PreToolUse guard **returns**, list every live registration of its basename (`jq '.hooks.PreToolUse[].hooks[].command' ~/.claude/settings.json`) and ask whether the tracked file edit can reach the host at all: a volatile live file plus an absent-target-only twin rule means it cannot. A superseded twin needs its own by-name retirement in the reconciler, with a smoke assertion that uses an **existing** target file, or the verdict change ships green and does nothing.

Retiring a hook outright, rather than superseding it, needs one more step for the deploy gap, the pattern dotfiles #1865 used for `hooks/PreToolUse/handoff-compliance.js`. Retire the live registration by name in `sync.sh install` (`retire_hook_commands`), but do not delete the file yet: the launchpad self-heal can fast-forward the checkout before dotup runs install, and a registered path that no longer exists errors on every tool call until then. Replace the file with a comment-only no-op that still reads stdin before exiting 0 (a payload past the 64 KiB pipe buffer otherwise leaves Claude Code's write with EPIPE), rewrite its test to pin that no-op contract, and delete both once no live `settings.json` registers the path.

Refs: dotfiles issue 991, PR 994 (the guard and the reconciler), the review workflow's P1 finding recorded in that PR body, and the `truthful-model-routing-live-2026-08` memory note that explains why the routing bundle carried its own copy.
