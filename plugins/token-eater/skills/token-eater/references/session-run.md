# Session run

A token-eater run is **one session**: one service, one token-heavy skill, one polished draft PR. The engine is `scripts/run-session.sh`; this playbook is how `SKILL.md` drives it — pick the skill, pick the gate, pick the target, launch, report.

The credit-burn model: the chosen CLI (e.g. `grok`) is itself a coding agent that loads your installed skills and runs them on **its own** models. token-eater hands it one recipe — *"run this skill, keep this gate green, self-review and fix, open a draft PR"* — and it runs the whole loop. token-eater's job is the safe setup around that (isolated worktree off fresh `origin/main`, a verified gate) and the guardrail after (re-run the gate independently, draft-PR only, never merge).

## The menu

Offer the token-heavy maintenance skills that are **installed** (`scripts/detect-skills.sh`) and **applicable to this repo**. These are the credit-burners — judgment work a deterministic gate can still verify:

| Skill (menu label) | What it does | Typical gate | How to pick the target |
| --- | --- | --- | --- |
| **de-monolithize** (`de-monolithize-your-codebase-isomorphically`) | Split a large module into cohesive files, behavior-preserving | tests + typecheck | the largest source file(s) with test/type coverage |
| **simplify** (`simplify-and-refactor-code-isomorphically`) | Simplify/refactor in place, behavior-preserving | tests + typecheck | a chosen module or the most complex file |
| **de-slop** (`de-slopify`) | Tighten repetitive/placeholder/AI-looking prose and comments | tests + typecheck (for code) or docs build | README/docs, or noisy-comment files in an explicit set |
| **dead-code** (`ce-simplify-code` / unused-symbol cleanup) | Remove provably-unused code | tests + typecheck (`noUnused*`) or lint | what the type/lint gate flags as unused |
| **mock-removal** (`mock-code-finder`) | Remove dead/placeholder mock code | tests | files the mock-finder flags |

Resolve each menu label to a concrete installed skill via `skills-catalog.yaml`. If a skill isn't installed, either suggest its (stubbed) House of Vibe drop-in or omit it from the menu. Let the user pick exactly one (or honor the skill argument).

Skills that have **no machine gate** (pure prose de-slop with no docs check, perf "optimize" with no benchmark) are offered only when the user explicitly accepts that the deterministic safety net is weaker — otherwise omit them.

## Pick the gate

The gate is what makes an unattended run safe — a deterministic check that is **green before the session starts**. You no longer pick it: `run-session.sh` **auto-detects** it (and you can override with `--gate "<cmd>"`). The engine:

1. **Installs the project's deps into the worktree first** (`ensure_deps`) — pnpm/npm/yarn/bun, uv/poetry, cargo, go, bundler — so the gate can actually run. (A fresh worktree of a pnpm **workspace** otherwise lacks per-package `node_modules`, which silently forced a typecheck-only downgrade before.)
2. **Climbs a ladder**, strongest green first, staying within the strongest ecosystem (`run-gate.sh --list`):
   - **Tier A — Verified:** `pnpm typecheck && pnpm test` (behavior-proving).
   - **Tier B — Checked:** `typecheck` / `build` / `lint` / `format:check`.
   - **Tier C — Soft:** no deterministic gate exists → **run anyway** with the AI review + a clearly-flagged draft PR as the safety net (operator decision 2026-06-29, for the many less-technical projects with no checks). The PR gets a prominent `> [!WARNING]` "no automated tests — AI-reviewed only" banner.
3. An **explicit `--gate`** is honored as-is and must be green at baseline, else the run refuses (exit 3).

The recipe wording adapts to the tier (Tier A/B: "run the gate, it must pass"; Tier C: "no gate — make the smallest conservative change and lean on the review").

## Target: let the skill choose it (on the service's credits)

Do **not** pre-pick the target with a crude heuristic. These maintenance skills find their own work, and they do it better — on the service's credits, which is exactly what we want to burn:
- **de-monolithize** runs a full census (`scripts/census.sh` + parallel `monolith-census-mapper` subagents per directory) that ranks files by size×complexity×churn, tags pathology buckets, and **skips generated files and justified-cohesive monoliths**. Its docs even warn that a file you hand-pick "may not be the worst offender."
- **dead-code** keys off the gate's own unused-symbol output; **mock-removal** scans for dead mocks; **de-slop** finds the sloppiest prose.

Choosing the right target is itself token-heavy analysis — that's a feature, not overhead. So leave `--target` off and let the skill discover it (the recipe tells the skill to spend real effort here, parallel `general-purpose` subagents encouraged). Pass `--target` **only** as an optional scope hint when you want to steer it (e.g. `--target "focus on the API layer if it's the worst"`); the recipe passes it as a hint the skill's own analysis can override.

## Launch

```bash
bash <skill-dir>/scripts/run-session.sh \
  --repo <project-path> --service <service> \
  --skill <skill-name> --gate "<gate command>" \
  --rounds 2 --slug <short-slug> [--pace gentle|thorough] [--target "<optional scope hint>"]
```

`run-session.sh` does, in order: auth preflight → `git fetch` + worktree off fresh `origin/main` → **baseline gate (must be green)** → render the recipe → **launch the service** (it runs the whole skill→gate→self-review→draft-PR loop on its own credits) → **independently re-run the gate** → ensure a **draft** PR exists on `origin`. Add `--dry-run` to render the recipe and stop (no launch, no spend).

Exit codes: `0` draft PR opened + gate verified green · `2` usage/preflight failure · `3` baseline gate red (refused) · `4` final gate red (worktree kept, no PR) · `5` gate green but no PR could be opened (branch kept).

### What the recipe tells the service (and why)

The rendered recipe (see `run-session.sh`) bakes in what the live runs taught us:
- **No `--effort` flag for grok** — `grok-composer-2.5-fast` rejects `reasoningEffort` (400). The engine never passes it.
- **Rate-limit resilience is built into the engine, not left to grok.** grok's rate-limit tier scales with historical API spend, so a lightly-used / first-time account 429s hard — and the wall-clock killer is parallel subagent fan-out triggering cascading backoff sleeps. Two deterministic, token-eater-owned defenses: (1) **pace** — `--pace thorough` (default) dispatches up to 3 subagents in parallel (the fan-out the review fleet needs; real 429s proved rare); `--pace gentle` dispatches **serially** (one at a time) for an account that actually 429-storms, pacing *under* the limit. (2) **backoff + resume** — `run-session.sh` watches whether grok actually made progress (committed work); if it made none **and** the logs show 429s, the engine itself backs off (exponential, jittered, capped at 5 min) and **resumes the same session via `grok --continue`**, escalating to `--no-subagents` so even a brand-new low-tier account eventually lands the core work. grok that simply grinds through 429s and commits is left alone (no wasted retries). This makes the skill robust across both extremes — a power user who's run it a hundred times, and someone using grok for the very first time.
- **The review stage runs `/ce-code-review` as a real subagent fleet — registry-adaptively.** The recipe tells the service to review-and-fix its committed diff by following `/ce-code-review`'s method (apply safe, verified fixes, commit on the branch, never push), looping until no P0/P1 remain or `--rounds` is hit. Key empirical finding (grok debug logs, 2026-06-29): **grok's Task subagent registry is inconsistent across runs.** Some runs expose only grok's four *native* types (`generalPurpose`, `code-reviewer`, `best-of-n-runner`, `cursor-guide`); other runs expose the full discovered `~/.claude` agent set — **including the genuine `compound-engineering:ce-*` reviewer personas** (`ce-correctness-reviewer`, `ce-security-reviewer`, …) that `/ce-code-review` natively dispatches. A dispatch to a type absent this run fails with `Unknown subagent type: X. Available types: …` (the error lists the valid set). Controlled probes (2026-06-29) showed the **native-four set is the reliable, common case** — short/early dispatches get it every time — while the `ce-*` "discovered" set is rare and appears only deep in some long sessions, consistent with grok's plugin/agent discovery being an async race that usually hasn't finished at dispatch time. **MCP on/off makes no difference** (8/8 probes native-four either way — the MCP-blocking-init hypothesis was tested and rejected). `--agents` injection also does *not* help — injected agents are rejected by the same Task enum (`unknown variant`). Six levers were tested to make `ce-*` *subagent_type* dispatch reliable — MCP on/off, `--agents` injection, installing the compound-engineering plugin into grok, namespaced names, wall-clock delay, and a warm-up dispatch — **all rejected** (native-four still dominated every time). Conclusion: grok's `ce-*` subagent_type dispatch cannot be made reliable.

**The review is service-aware** (`$SERVICE` branch in `run-session.sh`): on the **`claude`** service the real `/ce-code-review` runs directly — its `ce-*` reviewer subagents are native and reliable in Claude's runtime, no workaround — which is the default path for House-of-Vibe customers. The rest of this section describes the **`grok`/`codex`** path, where `ce-*` subagent_type dispatch is unreliable.

**The reliable solution there (and what the recipe does on grok/codex): run `/ce-code-review`'s genuine *persona prompts* — the full tiered roster, with its real selection logic — via the always-available `general-purpose` subagent.** The personas are markdown files in the compound-engineering plugin (`~/.claude/plugins/marketplaces/*/plugins/compound-engineering/agents/ce-*.md`), and the skill's own selection rules live in `skills/ce-code-review/references/persona-catalog.md`. `run-session.sh` discovers both at launch and points the recipe at them: spawn the **4 always-on personas** every run (`ce-correctness-reviewer`, `ce-testing-reviewer`, `ce-maintainability-reviewer`, `ce-project-standards-reviewer`), then **read the diff and select the cross-cutting conditional personas** whose domain it touches (`security`, `performance`, `api-contract`, `data-migration`, `reliability`, `adversarial`, `previous-comments`) and the stack-specific ones (`julik-frontend-races`, `swift-ios`) — exactly ce-code-review's catalog logic, judgment not keyword. Each selected persona runs as a `general-purpose` subagent prompted to *read and fully adopt* its persona file, then review the diff. Verified: a `general-purpose` subagent reading `ce-correctness-reviewer.md` produces genuine correctness-reviewer output. The cross-model `codex-reviewer` CE agent is skipped (needs the Codex CLI; out of scope for a grok-only run). If the persona files aren't found, it falls back to generic `general-purpose` lens reviewers. Either way this is the service reviewing **its own** work, so still not a substitute for your independent review.
- **The gate is authoritative; the service's self-report is not.** `run-session.sh` re-runs the gate itself after the service finishes and refuses to open a PR if it's red.

## Report

Relay what the engine returns:
- **Success:** the draft PR URL + that the gate was independently verified green. Note that the service already ran `/ce-code-review` over its own diff as a self-review pass. Then: **"Run your OWN independent review before merging — a fresh `/ce-code-review` in your Claude session (a different model than the one that wrote the diff) plus your frontier-model pass — token-eater did not merge anything."** The service reviewing its own work is a polish pass, not a substitute for an independent review.
- **Gate red (exit 4):** say plainly that the attempt didn't pass the project's own checks, so no PR was opened; the worktree is kept for inspection and your working tree was never touched.
- **No gate / not applicable:** explain why nothing ran.

One session, one PR. To burn more, run another session (another skill, or the same skill on another target).
