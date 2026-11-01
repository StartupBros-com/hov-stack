# Plan: adaptive gate + service-aware review (power-user AND House-of-Vibe ready)

Status: proposed (2026-06-29). Owner: this branch. Engine file `scripts/run-session.sh` is also
edited by a parallel effort — implement in small focused commits, rebase on each push.

## Goal — progressive disclosure

`/token-eater` with **zero arguments** must "just work" for a House of Vibe customer (a Claude Code
user who can type a slash command but does not know what a "pnpm workspace", a "gate", or a "429"
is), **and** every auto-decision stays overridable by a flag for a power user. One tool, two
audiences, no separate modes.

## The safety model (three auto-selected confidence tiers)

The customer never picks a tier; the engine picks the strongest available and labels it plainly.

| Tier | Selected when | Safety net | Shown as |
|------|---------------|------------|----------|
| **A — Verified** | `test && typecheck` (or ecosystem equivalent) is green | full deterministic proof | "tests pass" |
| **B — Checked** | only typecheck / build / lint is green | structural proof | "structural checks pass" |
| **C — Soft (AI-only)** | the project has no deterministic gate | independent AI review + draft PR | "no automated tests here — AI-reviewed only; please look it over before merging" |

Tier C (decision 2026-06-29: allow gateless runs for accessibility) is made safe by: (1) the work
service runs the review, (2) token-eater additionally runs an **independent** review pass (a
different agent/model than wrote the diff), and (3) the draft PR carries a prominent plain-language
"no tests — review before merging" banner. Accessible, but honest about confidence. The
draft-PR-only + never-merge invariants are unchanged and matter *more* for non-savvy users.

## Fix #1 — adaptive gate: detect → install → ladder → soft fallback

Problem: the engine assumes Node deps are pre-symlinked. False for pnpm **workspaces** (a fresh
worktree lacks per-package `node_modules`, e.g. `better-sqlite3` under `apps/cockpit`) and for every
non-pnpm stack. This silently forced a downgrade to typecheck-only, weakening the guarantee.

Design:
1. **Detect** package manager + workspace from lockfiles/manifests: `pnpm-workspace.yaml`,
   `package.json#workspaces`, `uv.lock`/`poetry.lock`/`requirements.txt`, `Cargo.toml`, `go.mod`,
   `Gemfile.lock`, `bun.lockb`, etc.
2. **Install deps in the worktree** before the baseline gate, per ecosystem
   (`pnpm install --frozen-lockfile --prefer-offline`, `npm ci`, `yarn`, `bun install`, `uv sync`,
   `cargo fetch`, `bundle install`, …). Best-effort + offline-friendly; never fail the run on a
   slow/absent network — fall through to the gate ladder.
3. **Gate ladder** (`run-gate.sh` already detects; add install-first + ladder): strongest green of
   `test && typecheck` → `typecheck`/`build` → `lint` → `format:check` = Tier A/B.
4. **Soft fallback**: no green deterministic gate → Tier C.
5. `--gate "<cmd>"` still overrides everything for power users.

## Fix #2 — service-aware review

The review recipe is grok-shaped but handed to every service. Branch `REVIEW_INSTRUCTIONS` on
`$SERVICE`:
- **claude** → run the real `/ce-code-review` (native `ce-*` subagent fleet). Highest fidelity, no
  workaround. Default for HoV (Claude subscriptions).
- **grok** → the verified persona-file-read fleet (explicit numbered dispatch + PERSONA-MARK roll-call).
- **codex** → codex's own reviewer, else the persona-file pattern.
Auto-selected from the authed CLI; the customer never thinks about "personas".

## Adaptability layer

- **Zero-config entry**: bare `/token-eater` → detect authed CLI → service (saved default → else the
  one authed CLI → else the existing one-question setup) → auto gate → skill finds its own target →
  run → draft PR → plain-language report. Print a one-line preview before launching. Power-user flags
  unchanged.
- **Plain-language report + risk summary**: translate "baseline gate GREEN / worktree off
  origin/main / exit 3" into "I made a safe copy, confirmed your checks pass, cleaned up X, opened a
  PR." End with a risk line (tier + files touched + tests status) to aid the merge decision.
- **Spend reporting**: surface cost in the DONE block. `delegate-claude.sh` already meters
  `total_cost_usd`; wire grok via `onwatch-usage.sh`. Report only — no surprise hard-cap (keep the
  optional `stop_when_low`).

## Implementation order (each step: edit → `bash -n` → `--dry-run` render → commit → push; validate
heavy paths with one real run)

1. `run-gate.sh` + `run-session.sh`: dependency auto-install + gate ladder (Fix #1, Tiers A/B).
2. `run-session.sh`: Tier-C soft gate + the prominent draft-PR banner + independent review pass.
3. `run-session.sh`: service-aware `REVIEW_INSTRUCTIONS` (Fix #2).
4. `run-session.sh` + `SKILL.md`: zero-config entry + plain-language report + spend line.
5. Docs: `references/session-run.md`, `SKILL.md`, `setup-and-config.md` updated to match.

## Out of scope (named so they aren't re-litigated)
- `pro-gate` (GPT-5.5 Pro Extended oracle review) — a separate power-user-only final tier, not wired in.
- Hard cost caps / billing — report spend only for now.
- Building the stubbed House-of-Vibe drop-in skills (`skills-catalog.yaml` `hov_registry`).
