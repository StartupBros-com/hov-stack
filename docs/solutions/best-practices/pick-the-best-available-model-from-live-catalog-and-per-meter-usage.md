---
title: "Pick the best available model from the live catalog and per-meter usage, and plant an unknown slug so no name lives in code"
date: "2026-09-05"
category: best-practices
module: claude-harness-codex-quota-resolver
problem_type: best_practice
component: development_workflow
severity: medium
resolution_type: code_fix
applies_when:
  - "A guard, router, or CLI must choose a model for a provider whose lineup rots within hours (a cache listed a model in the morning that the live list had dropped by evening)"
  - "Availability is not one number: an account-level window covers most models while some models carry their own separately metered windows on the same account"
  - "A denial is the default behavior and the cheaper fix is to rewrite the request onto whatever is actually open, with a receipt the caller can read"
  - "The same decision is needed from a hook path (Claude Code's PreToolUse) and from paths hooks never see (scripts, cron, another host), so one resolver must produce one receipt for both"
symptoms:
  - "A quota guard denied `codex exec -m gpt-5.3-codex-spark` although that model's own meter sat at 0%, because it read only the account-level `rate_limit`"
  - "Every earlier fallback design hardcoded model names, and the names were wrong within the same day"
related_components:
  - codex-quota-guard
  - codex-model-resolver
  - codex-pick
tags:
  - model-selection
  - catalog
  - usage-limits
  - planted-negative
  - fallback
  - codex
---

# Pick the best available model from the live catalog and per-meter usage, and plant an unknown slug so no name lives in code

## Context

Dotfiles issue 991 replaced "deny when the Codex window is out" with "run on the best model that is actually available". Two live sources make that decision without a single model name in the code:

- **The catalog is the source of "best".** `GET chatgpt.com/backend-api/codex/models?client_version=<codex --version>` returns entries with `priority` (lower is better), `visibility` (`list` or `hide`), `upgrade.model` (a deprecation pointer), `supported_reasoning_levels`, `default_reasoning_level`, `supported_in_api`, and `display_name`. Codex caches the same payload at `~/.codex/models_cache.json`; the resolver reuses it while it is under six hours old and never writes it. The catalog is versioned by client: the same account saw nine models for clients up to 0.152 and ten, with a new priority-1 model, from 0.153.0, so the version the resolver sends is the version whose lineup it gets.
- **The usage endpoint is the source of "available".** `GET chatgpt.com/backend-api/wham/usage` carries one account-level `rate_limit` for every model except the separately metered ones, which appear in `additional_rate_limits[]` with their own `rate_limit`, joined to the catalog on `limit_name == display_name`. Banked resets sit in `rate_limit_reset_credits.available_count`.

## Guidance

`hooks/lib/codex-model-resolver.js` implements the rule; `hooks/PreToolUse/codex-quota-guard.js` and `bin/codex-pick` both call it and emit the same receipt.

1. **Availability is per model, not per account.** For each catalog entry, find the `additional_rate_limits` row whose `limit_name` equals its `display_name`; if one exists, that row's `rate_limit` governs the model, otherwise the account-level one does. Only explicit state counts (`allowed === false` or `limit_reached === true` blocks; anything unfamiliar is "uncertain" and fails open on the active account, or skips a fallback account).
2. **Rank by priority after filtering, and follow deprecations only into something open.** Drop `visibility != list`; for an entry whose `upgrade.model` names a catalog entry that is itself available, substitute it; dedupe; sort by `priority`.
3. **A requested model that is itself open stays.** Check the request against the un-deduplicated available list first, so a deprecated-but-open model someone asked for is not silently upgraded.
4. **Effort clamps to the chosen model.** The catalog lists each model's levels but not their order, so keep one ordering for clamping only (`none … ultra`); when the request pins a level the fallback model lacks, walk down to the nearest supported level and say so in the receipt; when nothing was requested, report the catalog default and let the provider apply it.
5. **Plant the negative that a name-keyed implementation must fail.** `hooks/tests/fixtures/codex/catalog-planted.json` puts an unknown slug at the top and a known slug that `upgrade`s to it second; the resolver must choose the unknown slug, in the unit suite and through the CLI. This test paid for itself the next day, when the real catalog gained a new priority-1 model and the resolver picked it with no code change.
6. **One resolver, two entry points, one receipt.** The guard rewrites through `hookSpecificOutput.updatedInput` with the receipt in `permissionDecisionReason`; `codex-pick --json` prints the receipt and `codex-pick --exec` runs the rewritten argv. A parity test feeds the same fixtures to both and requires the same `{account, model, effort, priority, reason}`.

Fixtures are field-faithful copies of the live payloads on the day (an exhausted account with the separately metered model open, everything out, healthy), with the observation date in each file's comment, so a later reader can tell fixture truth from current truth.

## Applicability

Use this shape wherever a provider publishes a ranked catalog and a per-window usage document: rank from the catalog, gate on the meter that governs each entry, keep names in fixtures only, and plant the unknown-name negative before the first real name change proves the point for you. Do not carry it to a provider with no live catalog; there the fallback is a stated policy, and the doc should say so.

Refs: dotfiles issue 991, PR 994 (resolver, guard, `codex-pick`, fixtures), PR 1003 (a further rung that ranks a router's pool profiles against the same catalog).
