---
name: ce-plugin-local-patches
description: The compound-engineering local-patch layer was RETIRED 2026-07-01 at CE 3.17.1 — native model tiering + native cross-model review replaced it, ce-work-beta was removed upstream, and the session model returned to Fable 5. No more post-update patching.
metadata:
  node_type: memory
  type: project
  originSessionId: 84b9c765-ef99-4c68-9936-3cd657a7244e
---

**Retired 2026-07-01.** When Fable 5 came back, CE was updated 3.12.0 → 3.17.1 and the whole local-patch treadmill was dismantled, because upstream now does natively what the patches did by hand.

**What changed at CE 3.17.1** (repo restructured to root-level `skills/`, was `plugins/compound-engineering/…`):
1. **`ce-work-beta` hard-deleted upstream** (plan `2026-06-26-001-chore-remove-ce-work-beta-plan`). Codex delegation was deliberately NOT promoted into stable `ce-work`. Decision: retire it here too — delegate via Codex CLI / token-eater's grok launcher directly. `~/.claude/CLAUDE.md` Model Routing updated to drop the `/ce-work-beta delegate:codex` mandate. So `ce-model-invocation-flips.sh` is moot.
2. **Native model tiering** lives in the dispatching skills now: judgment personas (correctness/security/adversarial) `inherit` the session model (= Fable); every other persona/agent runs Sonnet-class. Scout agents are frontmatter-free prompt assets under `skills/*/references/agents/` — nothing to pin. So `ce-agent-model-pins.sh` is obsolete.
3. **Native cross-model review**: `scripts/cross-model-adversarial-review.sh` runs a Codex second opinion on risky, locally-diffable diffs (adversarial-selected + local/standalone scope; non-blocking). Decision: "native only" — dropped the custom always-on `codex-reviewer`/`codex-doc-reviewer` wiring. So `codex-reviewer-ce-integration.sh` is retired. NOTE: `ce-doc-review` at 3.17.1 has NO native cross-model pass; doc reviews no longer get an automatic Codex second opinion (accepted tradeoff).

**Where things went:**
- `~/.claude/plugins/ce-post-update.sh` → tombstone (exits 0, explains retirement).
- Retired scripts + the 2 custom agents archived (reversible) to `~/.claude/git-archive/retired-ce-patches-20260701/`: `ce-model-invocation-flips.sh`, `ce-agent-model-pins.sh`, `codex-reviewer-ce-integration.sh`, `codex-reviewer.md`, `codex-doc-reviewer.md`.
- `~/.claude/agents/oracle-reviewer.md` KEPT (separate GPT-5.5 Pro terminal-gate reviewer, unrelated to the retired Codex personas).
- `~/.claude/hooks/plugin-auto-update.js`: self-heal block removed. It still auto-pulls the marketplace + `claude plugin update` daily, but no longer runs any post-update patch. With no local patches, the marketplace working tree stays clean, so the old "dirty tree blocks the auto-pull" failure mode is also gone.

**Session model:** `"model": "fable"` set in `~/.claude/settings.json` (global). The `/mnt/c/Users/user/.claude/settings.json` project override may still pin `opus` (bg-isolation guard blocked editing it in this job) — flip or remove it if sessions launched from the Windows home should use Fable. `MAX_THINKING_TOKENS`/`CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` are ignored by Fable 5 (adaptive-only); reconsider removing them so non-Fable Sonnet subagents can use adaptive thinking instead of a forced 32k budget on mechanical work.

Related: [[model-usage-tracking-infra]], [[token-eater-project]].
