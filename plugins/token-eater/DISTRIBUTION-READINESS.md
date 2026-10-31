> **Historical (superseded 2026-08-03).** This was the pre-distribution gate
> checklist, written before token-eater shipped. Its "Open — DELIVERY" section
> asks for an install mechanism that now exists: token-eater is published in the
> [House of Vibe marketplace](https://github.com/StartupBros-com/hov-stack)
> and installs with `/plugin install token-eater@hov`. Kept for the reasoning
> trail, not as a current status report.
>
> The one item here that is still live is the trust boundary, and it is not a
> secret: the tool runs your project's own gate command in an unsandboxed shell
> under your user account, which is why it refuses to run without explicit
> per-repo consent. That is stated plainly in the README's Safety section, which
> is the current source of truth.

# Distribution readiness — House of Vibe

token-eater is **internal-ready on `main`** (works for power users on Linux/macOS). This is the gate
checklist before distributing it to House of Vibe members (non-technical Claude Code users, mostly on
macOS). Two threads: make it **safe** for untrusted users, and make it **installable**.

## Done

- **Layered review proven on the tool itself.** `/ce-code-review` (Claude `ce-*` fleet) → fixes →
  merge → `/pro-gate` (GPT-5.5 Pro Extended, cross-model) → fixes → merge. Each tier caught
  complementary bugs the others missed.
- **Cross-platform validated (PR #14).** Runs on macOS stock **bash 3.2.57** + BSD tools (no
  pnpm/timeout/flock), verified on a real Mac — the realistic member environment. Fixed: empty-array
  `set -u` aborts, `mapfile`, pnpm-hardcoding, `stat -c`, `timeout`.

## SAFETY (makes it safe to point at untrusted repos) — DONE

- ✅ **Trust gate.** token-eater runs the target repo's own code (its gate command; with `--install-deps`,
   its install scripts). It now **refuses without `--trust-repo`** (explicit, remembered-per-repo consent),
   so a repo's code never runs silently. `--install-deps` stays opt-in for the install-script RCE path.
   *(A network sandbox — `sandbox-exec`/`bwrap` — is a stronger future control; the trust gate is the v1
   because a default sandbox breaks legitimate gates that need fs/network.)*
   **Scope of the v1 boundary (be explicit with members):** the service adapters (grok
   `--always-approve`, claude `--allowedTools Bash`) and the gate itself all run an UNSANDBOXED
   shell under the user's OS account — repo content that prompt-injects the service, or a model
   mistake, can reach `$HOME`, credentials, and the network. `--trust-repo` consent covers exactly
   this. The pro-gate verify-round review (2026-07-03) re-flagged it: an OS sandbox around the
   service + gate is the **required hardening before distribution beyond trusted-repo use**, and
   codex (`workspace-write`) already shows the target posture.
- ✅ **Repo-derived strings validated.** `ORIGIN_SLUG` (owner/repo charset), `BASE`, `BRANCH` (git ref
   charset) are rejected if malformed before reaching `gh pr create` or the agent recipe.
- ✅ **`.env` no longer copied** into the worktree (was exposing secrets to the autonomous service).

## Member-first runtime UX — DONE

- ✅ **`/token-eater` and nothing else.** Members are non-technical and never type a flag. First run on a
   project asks a short **interactive multiple-choice preflight** (plain language: "what should I do?" +
   "which credits?"), **persists the answers to `./.token-eater.yaml`**, and every later run is
   zero-questions. Flags (`--trust-repo`, `--install-deps`, `--gate`, `--pace`) are Claude↔engine only;
   the member's interactive choice is the trust consent. No jargon skill-menu. (SKILL.md + setup-and-config.md.)

## Open — DELIVERY (makes it installable by a member)

The House of Vibe app is course/challenge/vault-based with **no skill-install
mechanism yet**. Needs a design:
- Bundle format + install path into `~/.claude/skills/` (and how members run `/token-eater`).
- Versioning / updates.
- The **compound-engineering plugin dependency** — the genuine `ce-*` persona fleet needs it; without
  it the review falls back to generic lenses. Either bundle/recommend it, or make the fallback a
  first-class, honestly-labeled experience.
- Course lesson / vault resource that teaches install + use.

## Open — OBSERVABILITY (members will ask "what did this cost?")

- **Per-run spend is unobservable on grok.** token-eater's whole pitch is "burn your credits," but the
  grok headless log emits only ONE usage record (the orchestrator turn — e.g. 111k tokens, 99.6%
  cached); the parallel native subagents (`grok-4.20-multi-agent`) that do the real work log no token
  usage. So the DONE-block spend line is empty for grok. claude and codex delegates DO report `cost_usd`.
  Options: query grok's usage API/dashboard for a per-run delta, show wall-clock + subagent count as a
  proxy, or at minimum tell the member where to see their spend. (Verified on PR #830's run.)

## Standing rule (added 2026-06-29)

Cross-platform validation on a real **macOS bash 3.2** target is part of the pre-distribution checklist
for any shell tooling shipped to members — a whole bug class (bash-4 features, GNU-vs-BSD tools) that a
Linux/bash-5 dev box structurally cannot surface. Same spirit as the cross-model `/pro-gate` tier.
