---
name: codex-consult
description: Ask Codex (GPT-5.5) for a read-only second opinion on the current problem, then synthesize agree/disagree against Claude's own view. Advisory only — Codex never edits files.
argument-hint: The question or decision to get a second opinion on (e.g. "is this auth refactor sound?", "why does X deadlock?")
disable-model-invocation: true
allowed-tools: Bash
---

# Codex Consult — cross-model second opinion

Get an independent read from **Codex / GPT-5.5** on `$ARGUMENTS`, then return a
synthesis — not a raw forward. This is the lightweight, stateless counterpart to
the codex second-opinion pass inside `/ce-code-review` (diff review). Use it
mid-conversation when you want a fast, divergent opinion before committing to an
approach.

## When this is worth the round-trip
- Architecture decisions that are painful to reverse
- Root-cause analysis after ≥2 failed fixes
- Security review of auth / crypto / user-input / shell-exec paths
- Non-trivial algorithms or concurrency reasoning
- Anything you (Claude) are low-confidence on

**Not worth it:** naming debates, "what does this code do", style nitpicks. For
those, just answer directly.

## How to run it

1. **Assemble a self-contained prompt.** Codex runs read-only and may lack your
   conversation context, so embed the essentials: the question, the relevant code
   (paste the actual snippets/diffs), constraints, and what you've already tried.
   Lead with this guardrail line so Codex stays advisory:

   > You are a senior engineer giving a TEXT-ONLY advisory second opinion. Do not
   > modify files, create branches, or open PRs. Reason about the question and give
   > your analysis + a clear recommendation. If you genuinely need more context,
   > state exactly what — don't guess silently.

2. **Invoke direct Codex (read-only, OPENAI_API_KEY stripped so it uses the
   ChatGPT subscription rather than API credits).** Pipe the prompt via stdin to avoid quoting hell:

   ```bash
   env -u OPENAI_API_KEY codex exec -s read-only --skip-git-repo-check \
     -c model_reasoning_effort="high" - < "$CLAUDE_JOB_DIR/tmp/codex-consult.md"
   ```

   - Effort: **`high`** by default. Bump to **`xhigh`** for architecture, security
     audits, or hard algorithm/concurrency questions. Drop to `medium` for quick
     sanity checks.
   - Model: omit `-m` — it inherits the operator-selected model from `~/.codex/config.toml`.
   - The PreToolUse quota guard blocks only when the active direct account explicitly reports
     unavailable. If that happens, report the consult skipped or use `/pro-gate`; do not claim
     an unknown-provenance subagent is the same cross-model check. caam rotation is currently
     unavailable (its stored Codex profile is unauthorized; the active auth is unmanaged).

3. **Synthesize — never just forward.** Return exactly three parts:
   - **The question** you asked (one line).
   - **Codex's answer**, quoted verbatim (don't paraphrase its core claims).
   - **Claude's synthesis:** where you agree, where you disagree *and why*, and the
     **final recommendation**. When you and Codex disagree, say which view you trust
     more for *this specific* question and the reason.

Keep the whole thing tight. The value is the disagreement surface between two
models, not a wall of duplicated agreement.
