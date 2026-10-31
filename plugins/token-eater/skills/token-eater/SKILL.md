---
name: token-eater
description: "[BETA] Spend a subscription's idle, about-to-expire credits on safe, machine-verified cleanup. You pick the service (Grok / Codex / Claude) and a token-heavy maintenance skill (de-monolithize, de-slop, simplify, dead-code); that service runs the whole skill -> gate -> self-review -> draft-PR loop on its own credits, in an isolated worktree. token-eater verifies the gate and never merges. Manual invocation only during beta."
disable-model-invocation: true
argument-hint: "[grok|codex|claude] [skill] [dry-run] [setup]"
---

# token-eater

Turn the subscription credits you would otherwise let expire into a cleanup crew for your project.

**You point token-eater at a service and pick a token-heavy maintenance skill. That service runs the entire job on its own credits** — it runs the skill, keeps the project's own checks green, reviews and fixes its own work, and opens a draft PR — all in an isolated worktree. token-eater is the launcher and the guardrail: it sets up clean isolation, hands the service one self-contained recipe, then independently re-runs the gate and makes sure nothing ever merges. The final review and merge are always yours.

Want to burn expiring Grok credits? `/token-eater grok`. It spends only the service you name and leaves everything else alone.

> **How this works (important):** the chosen CLI (e.g. `grok`) is a full coding agent that already loads your installed skills — `de-monolithize-your-codebase-isomorphically`, `de-slopify`, `ce-*`, etc. — and runs them on *its own* models. token-eater doesn't re-implement the work; it hands the service a recipe that says *"run this skill, keep this gate green, review-and-fix, open a draft PR,"* and the service does the whole loop. That's why the credits burned are the service's, not your Claude session's.

**Skill files resolve from THIS skill's base directory, not the user's project.** Every `scripts/...`, `references/...`, and `skills-catalog.yaml` path below is relative to the directory this `SKILL.md` lives in. Invoke scripts by their absolute path — e.g. `bash <skill-dir>/scripts/run-session.sh ...`. The *work* runs in the user's project (a worktree of it); the *tooling* lives with the skill.

**Codex on Windows:** when this skill is surfaced through `C:/Users/<username>/.agents/skills/token-eater`,
run the shell tooling through WSL, not native Windows path syntax. Prefer the installed WSL skill directory,
for example `$HOME/.claude/skills/token-eater`, and invoke scripts with a translated Linux path via
`wsl -e bash -lc 'bash "$HOME/.claude/skills/token-eater/scripts/run-session.sh" ...'`. If you must use
the Windows copy, translate it to `/mnt/c/Users/<username>/.agents/skills/token-eater` before passing it
to bash. WSL is a compatibility layer, not a security sandbox. The target repository's code still runs
with the files, credentials, and network access available to your WSL user.

## Status

`[BETA]` — manual invocation only (`disable-model-invocation: true`: a human must type `/token-eater`; other skills cannot hand off to it).

## Input

<input> #$ARGUMENTS </input>

## Audience first: the user just types `/token-eater`

**Assume the person running this does not want to learn this tool's flags** — not because they
could not, but because nobody should read a manual to spend credits that are about to expire. They
type `/token-eater` and nothing else. **You (Claude) are the friendly layer**: you collect what's
needed through **plain-language, interactive multiple-choice questions** (use the AskUserQuestion
tool — a click beats a flag), you translate those choices into `run-session.sh` flags yourself, and
you report back in plain English. The flags in this doc are *your* contract with the engine, never
something you make the user read.

### First run on a project (not yet configured) → interactive preflight, then persist

When there's no saved config (`references/setup-and-config.md`) and no `$ARGUMENTS`, ask a short
**interactive multiple-choice preflight** (plain language, no jargon), then **save the answers to
`./.token-eater.yaml`** so you never ask again for this project:

1. **"What should I do?"** — plain-language options that map to skills (see the table below). Mark the
   safest/most-broadly-useful as *(Recommended)*.
2. **"Which credits should I use?"** — only if more than one service is signed in; otherwise pick the
   one that is, silently. Phrase as "Claude / Grok / Codex credits", not "service".

Before any shell command, explain plainly that token-eater will run this project's own checks and that
the isolated worktree is not a security sandbox: project code can access the user's files, credentials,
and network. Ask whether to continue. Only after an explicit yes, pass `--trust-repo-caveat 1`. The engine stores
versioned consent outside the project, keyed by its canonical path. The same caveat version asks nothing
later; a version bump asks again. Never infer consent from `./.token-eater.yaml` or any tracked project
file. Persist only `{services, task}` to `./.token-eater.yaml`.

**Dependency preflight (required companion):** token-eater's code reviewers are the compound-engineering
plugin's `ce-*` personas. Check whether they're present (glob
`~/.claude/plugins/marketplaces/*/plugins/compound-engineering/agents/ce-correctness-reviewer.md`). If
**missing**, tell the user plainly — "I use the *compound-engineering* plugin for the code reviews;
want me to install it?" — and on yes run `/plugin install compound-engineering@hov` (or
`@every-marketplace`), then continue. (If they decline, the run still works but the review degrades to
generic lenses — say so.) Never show the user the word "plugin dependency" or a `ce-*` agent name.

Plain-language task → skill mapping:

| Member-facing choice | skill | 
|----------------------|-------|
| "Tidy up & simplify my code" *(Recommended)* | `simplify-and-refactor-code-isomorphically` |
| "Remove unused / dead code" | `ce-simplify-code` (dead-code) |
| "Split up big, messy files" | `de-monolithize-your-codebase-isomorphically` |
| "Clean up the writing in my docs" | `de-slopify` |

### Later runs (already configured) → zero questions

If `./.token-eater.yaml` (or user config) already has `{services, task}`, just run with them — no
questions. The engine's per-repo trust cache means no affirmation flag is needed while caveat version 1
remains recorded. If the caveat version changes, show the new text and pass that exact new version only
after another explicit yes. The user types `/token-eater`, you run, you report. To change the saved choices later they can run
`/token-eater setup`.

### Power-user arguments (optional — for someone who knows the tokens)

A technical user MAY pass tokens; parse and strip them, then skip the matching preflight question.
Never require these.

| Token | Effect |
|-------|--------|
| `grok` / `codex` / `claude` | Spend this service this run (overrides saved). |
| a skill name (e.g. `de-monolithize`) | Run this skill; skip the "what should I do?" question. |
| `setup` | Re-run the interactive preflight and rewrite the saved choices. |
| `dry-run` | Preflight + show the recipe without launching or opening a PR. |

## How a session runs

A token-eater run is **one session**: one service, one skill, one polished draft PR. The shape:

1. **Detect + resolve the service.** Run `scripts/detect-adapters.sh`. If none of the CLIs are installed, stop with a plain explanation. Resolve the service from `$ARGUMENTS` -> saved config -> one-question setup. Confirm it's headless-ready: `scripts/check-auth.sh <service>` (`run-session.sh` does this too).

2. **The gate is auto-detected — you don't need to pick it.** `run-session.sh` makes the project's deps available in the worktree (shared from the user's checkout by default; `--install-deps` opts into a fresh, worktree-local install), then climbs a ladder (strongest green check first): **Tier A** `typecheck && test` → **Tier B** `typecheck`/`build`/`lint` → **Tier C (soft)** no deterministic gate, in which case it still runs but relies on the AI review + a clearly-flagged draft PR. So just **omit `--gate`** and let the engine choose; pass `--gate "<cmd>"` only to override. (Less-technical users with no tests still get a useful run, plainly labeled lower-confidence.)

3. **The task is already chosen — don't show a jargon menu.** It came from the interactive preflight's "What should I do?" (mapped to a skill), from saved `./.token-eater.yaml`, or from a power-user skill argument. NEVER present raw skill names (`de-monolithize`, `mock-removal`, …) to a user — those only appear in the plain-language mapping above. Verify the chosen skill is installed (`skills-catalog.yaml` + `scripts/detect-skills.sh`); if not, fall back to the recommended one and say so plainly.

4. **Let the skill find its own target — on the service's credits.** Do NOT pre-pick a target with a crude heuristic (e.g. "the largest file"): that wastes *your* tokens and overrides the skill's better, service-run analysis. Most of these skills discover their own work — de-monolithize runs a census that ranks monoliths and skips generated / justified-cohesive files; dead-code keys off the gate's unused-symbol output. Choosing the right target is itself token-heavy analysis that belongs on the service. So pass `--target` only as an optional **scope hint** (e.g. "focus on the API layer") — or omit it entirely and let the skill choose.

5. **Launch the session.** Call the engine — it does preflight (worktree off fresh `origin/main` + baseline gate), hands the service the recipe, then independently re-verifies the gate and ensures a draft PR:

   ```bash
   bash <skill-dir>/scripts/run-session.sh \
     --repo <project-path> --service <service> --skill <skill-name> \
     --rounds 2 --trust-repo-caveat 1 [--gate "<override>"] [--install-deps] [--pace gentle|thorough] [--target "<hint>"]
   ```

   **You pass these flags, not the user.** `--trust-repo-caveat 1` is justified only by the user's
   explicit acceptance of caveat version 1 just shown (the engine caches that version per repo); pass
   `--install-deps` only if the user opted
   into it (don't, by default). `--gate` is optional (auto-detected — step 2). Add `--dry-run` to
   render the recipe and stop. The service then runs the whole loop (skill -> gate -> review + fix, up
   to `--rounds` rounds -> push -> draft PR) on its own credits — the review uses the real
   `/ce-code-review` on the `claude` service and the genuine-persona fleet on `grok`/`codex`. This is
   the long-running part.

6. **Report — in plain language.** Translate the engine's output for the user, scaled to how technical they are. Always state, simply: what was cleaned up, that it's a **draft PR** (nothing merged), and the **confidence tier** — "✅ your tests pass" (Tier A), "✅ structural checks pass" (Tier B), or "⚠️ this project has no automated tests, so this was AI-reviewed only — please read it before merging" (Tier C). Include the spend line if present, and end with the one-line risk summary (tier + files touched). Then: **for your own peace of mind, run a fresh `/ce-code-review` (or your frontier-model review) on the PR before merging** — the service reviewed its own work, so an independent pass is still worth it. token-eater did not merge anything. On a clean failure (gate red on an explicit gate, or no PR), say so plainly; the worktree is kept and the user's checkout was never touched.

## Safety invariants

- Never auto-merge AND never auto-mark-ready — work lands as a **draft PR**; the final review and merge are always yours.
- **Prefer a deterministic gate; degrade transparently when there isn't one.** Tier A/B run the project's real check and the result is re-verified independently. Tier C (no gate) still runs but is clearly flagged on the PR as AI-reviewed-only — never presented as machine-verified.
- **Trust boundary (enforced):** token-eater runs *the target repo's own code* on your machine — its gate command (e.g. `pnpm test`), and, with `--install-deps`, its dependency install/lifecycle scripts. So it **refuses to run a repo's code without `--trust-repo-caveat 1`** (remembered per repo after the first time). Dependency install is additionally OFF by default. Repo-derived strings (`origin` slug, base/branch) are validated before reaching `gh`/the recipe, and the target repo's `.env` is never copied into the worktree.
- token-eater's gate is re-run **independently** after the service finishes — the service's self-report is never trusted for keep/ship.
- token-eater only spends the service you named (or your saved default).
- All work happens in a fresh worktree branched from `origin/main`; your checkout and uncommitted work are never touched. A red final gate means no PR.

## Reference map

| File | What it's for |
|------|---------------|
| `references/session-run.md` | **The main flow** — the menu of token-heavy skills, how to pick a gate + target, and the `run-session.sh` contract |
| `skills-catalog.yaml` | The menu source: token-heavy skill ↔ archetype ↔ gate (installed skills + stubbed HoV drop-ins) |
| `references/setup-and-config.md` | The one-question setup + the small config schema |
| `references/worktree-lifecycle.md` | Worktree isolation, naming, and cleanup (`scripts/wt.sh`) |
| `references/adapter-contract.md` | How each service CLI is invoked headlessly (`adapters.yaml`) |
| `references/result-handling.md` | Draft-PR rules + plain-language summary + run ledger |
| `references/schedule-install.md` | **Optional / advanced** — run token-eater on a recurring schedule |

Scripts: `run-session.sh` (the whole session: preflight → launch service → verify gate → draft PR) · `detect-adapters.sh` (which CLIs are installed) · `detect-skills.sh` (menu scan) · `check-auth.sh` (headless-auth preflight) · `run-gate.sh` (deterministic gate) · `wt.sh` (worktree create/cleanup/sweep) · `delegate-{codex,claude}.sh` (non-grok service runners) · `onwatch-usage.sh` (optional balance reader).

> The earlier per-chore "harvest loop" references (`chore-discovery.md`, `harvest-loop.md`, `delegation-invocation.md`, `review-pipeline.md`, `apply-tool.sh`) are **superseded** by the session model in `references/session-run.md` and are kept only as legacy.
