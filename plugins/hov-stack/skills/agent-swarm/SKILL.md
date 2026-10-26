---
name: agent-swarm
description: >-
  Run a large or parallelizable task across many agents (parallel subagents, the
  Workflow tool, Codex delegation, worktree isolation). Use when a task is too big for
  one context or has many independent units — whole-codebase campaigns (refactor / audit
  / migration / dead-code sweep), broad multi-file sweeps — or when you need multiple
  independent perspectives (adversarial verification).
---

# Agent Swarm — parallelize with the native stack, not a protocol

> **The core shift.** The old swarm needed a *coordination protocol* (spawn terminals, reserve files,
> share a task pool) because its agents ran in separate processes with no shared structure. You don't:
> your parallelism is **structured** (the Workflow tool), your agents are **first-class** (the Agent
> tool), and your isolation is **physical** (git worktrees). So most "swarm coordination" evaporates —
> you pick an engine, fan out, and verify. No file reservations, no message bus, no bead pool.

## The primitive map

| Old jsm swarm | Native replacement |
|---|---|
| `ntm` — spawn N terminal agents | **Claude Code subagents** (Agent tool): launch many in one message → concurrent; specialized agent types; background by default |
| `beads` — shared task pool + dependency graph | **The Workflow tool**: deterministic `pipeline`/`parallel`, fan-out, loop-until-dry, adversarial-verify, budget-scaled |
| `agent-mail` — file-reservation coordination | **Worktree isolation** (`isolation:"worktree"` / `codex exec --cd <wt>`): physical isolation ⇒ no protocol |
| `bv` / triage | plain code in a Workflow script, or a judgment subagent |
| multi-model peer scoring | **`/multi-model-triangulation`** (compose, don't re-implement) |

## Pick the lightest engine that fits

- **Solo / inline** — < ~5–7 independent units. Orchestration overhead isn't worth it; a single Sonnet
  subagent or inline work is cheaper. Don't build a swarm for a small job.
- **Parallel subagents (Agent tool)** — independent **read/analysis/search** fan-out with no cross-item
  dependency: search sweeps, per-file analysis, collecting findings, multi-angle exploration. Launch
  **multiple Agent calls in one message** so they run concurrently. Pin `model` (sonnet/haiku for
  mechanical sweeps — don't let them inherit the session model). Keep only the conclusions in your
  context, not the file dumps. *Concurrency is capped ~10–16; excess queues.*
- **The Workflow tool** — when you need **structure or verification**: multi-stage per-item work
  (`pipeline`), a barrier over all results (`parallel`), fan-out-then-verify, loop-until-dry discovery,
  or scaling depth to a token budget. This is the beads-task-pool replacement — a real orchestration
  engine. Reach for it for comprehensive reviews (find → adversarially verify → synthesize), migrations
  (discover → transform → verify), and any "fan out N, verify each, synthesize" shape.
- **Codex delegation** — **implementation batches ≥ 5–7 units** (upstream-measured breakeven; below
  that a Sonnet subagent is cheaper). `codex exec --cd <worktree>` (sets cwd = writable root), or the CE
  plan→Codex-host handoff for planned work, or token-eater's grok launcher for bulk grunt. **Codex edits,
  the session model reviews the diff; always give Codex an explicit testing directive.**
- **Retained background specialist (rare; Claude Code 2.1.224)** — only when a known later follow-up needs
  the same conversation context; normal Agent/Workflow fan-out remains the default. Launch a persistent
  background CLI session with a unique `--name` (never `--no-session-persistence`), then wait for its exact
  row to reach `state:"done"` in unfiltered `claude agents --json --all` before `claude attach <short-id>`.
  The name is for discovery, not identity: match `id`, `sessionId`, name, and cwd; inspect the full-UUID transcript
  when continuity evidence matters. This proves neither compaction survival nor quality, cost, or latency gains.

## Isolation is the coordination

The one rule that replaces the entire file-reservation protocol:

- **Read-only fan-out** (analysis, search, review) → **no isolation needed**. Many agents read the same
  tree safely.
- **Parallel agents that MUTATE files** → **one git worktree per agent** (`Agent isolation:"worktree"`,
  or `codex exec --cd <worktree>` per unit). Physical isolation means zero conflicts and zero coordination
  — each agent owns its checkout; you merge/collect after. This is strictly better than advisory leases.
- Worktrees are ~200–500 ms + disk each — use them only when agents genuinely write in parallel, not for
  read-only work.

## Dispatching from a worktree-isolated session (background jobs)

Subagents and Workflow agents inherit the session's worktree shape-checker — the
fleet's #1 measured denial source (7.4k "too complex" refusals/30d; a 2026-08-28
stratified sample scored 13/15 shape refusals as false positives on safe work).
The checker is upstream (Claude Code bundle; dotfiles#436), so route around it
in every dispatch prompt:

- Multi-step or loop-bearing work goes in a script file written with the
  file-write tool, run as `bash /tmp/<scratch>/<name>.sh` — plain
  `bash <script-file>` always passes; inline for-loops, `$( )` in argument
  position, and compound chains may not.
- Never prefix `HOME=` or other env vars onto complex commands — a
  `HOME=… cargo build` with no git in it is still refused for "injecting git
  configuration."
- Keep `git -C` inside the session worktree or `/tmp` clones; sibling-worktree
  reads get refused.

Measured effect: dispatches carrying this preamble ran 0 shape refusals across
7 agents (2026-08-28); the two dispatches before it each lost a stage to the
checker.

## Cross-session overlap (before touching a gh issue)

Physical worktree isolation solves intra-task parallelism (above); it does nothing for two of the
~6 concurrent sessions picking the SAME gh issue. Nothing claims issues (retired 2026-10-17), so look first:

```bash
gh-ready.sh --repo <owner/repo>        # unblocked ready work (--all for org-wide)
gh pr list --repo <owner/repo> --search "#<n>"   # an open PR already on it?
wt-new.sh <repo> <slug> --issue <n>    # worktree + the printed gh pr create command
```

Full mechanism: `harness/gh-tracking-and-claims.md`.

## The patterns worth knowing (from the Workflow doctrine)

- **Fan-out → adversarially verify → synthesize.** Generate findings in parallel, then spawn *independent
  skeptics* per finding (prompted to refute; kill on majority-refute), then synthesize survivors. Stops
  plausible-but-wrong findings from shipping.
- **Loop-until-dry.** For unknown-size discovery (bugs, dead code, refactor sites), keep spawning finders
  until K consecutive rounds surface nothing new — dedup against everything seen, not just what's kept.
- **Multi-modal sweep.** Each agent searches a *different way* (by-container / by-content / by-entity /
  by-time); one angle never finds everything.
- **Completeness critic.** A final agent asks "what's missing — a modality not run, a claim unverified?"
  Its findings are the next round.
- **Pipeline, not barrier, by default.** Only force a `parallel` barrier when a stage genuinely needs all
  prior results at once (dedup across the full set, early-exit on zero, cross-item comparison). Otherwise
  `pipeline` — item A verifies while item B is still being reviewed.
- **Worker brief schema.** Every packet handed to a worker carries labeled fields: GOAL, CONTEXT (why it
  exists, what it must not assume), SCOPE (files or surface it owns), ACCEPTANCE, VERIFY (the exact suite
  or command), TIMEBOX (dollars or minutes), FORBIDDEN, REPORT (the return shape, with a literal example
  when parallel workers must agree on it), STANDING (what to do when blocked). TIMEBOX and FORBIDDEN are
  never empty; the rest may be one line. Two parallel workers once shipped a writer storing objects and a
  reader parsing epochs with both suites green because their packets never pinned the shape (PR #1167);
  the dispatcher's child prompt used this schema (dotfiles#1202) until the dispatcher's retirement in #1873.

## Cost routing (operationalizes CLAUDE.md)

- **Mechanical** (search sweeps, file collection, log trawls, summarization, bulk edits) → Sonnet, or
  Haiku for trivial sweeps — pin `model` explicitly (see "Pick the lightest engine that fits" above).
- **Judgment** (planning, architecture, review, adversarial verification, synthesis) → the session model.
- **Implementation batches / bulk grunt** → see "Pick the lightest engine that fits" above.
- **Never silently absorb a delegatable batch into the session model.** If direct Codex is unavailable
  (explicit quota preflight or auth outage), use a fresh subagent and report the statusline's actual
  `via` model. That is an implementation fallback, not proof of cross-model independence; use
  `/pro-gate` or record an adversarial gate as skipped when provenance is unknown.

### Workflow stage tiers (full text; `CLAUDE.md` carries the short form)

- **Inventory, sweep, collect** → `sonnet` (`haiku` for trivial) as `subagent_type: lean-reader`
  when the stage only reads files named in its prompt, judge stages included. It drops CLAUDE.md and
  the memory index (18.8k tokens a request; output not worse at n=2, #1221, #1237). It inherits
  session effort, and a per-call `effort` overrides agent frontmatter (#1321).
- **A stage that needs a read CLI** (structural search, raw web content via firecrawl-cli/exa-cli,
  gh or git facts, a data-source query) → `subagent_type: lean-collector`: the same omission plus
  Bash and the data-source-clis skill preloaded (#1341). A stage that edits, commits, pushes or
  posts stays general-purpose.
- **Analyze, synthesize** → the session model, only where judgment is real.
- **Factual verification** → `sonnet` at session effort. No `effort: 'low'`: low miscounted its own
  files (`experiments/lean-reader-2026-09-19/RESULTS-effort-2026-09-22.md`). A lower tier
  needs a latency reason plus a real-task quality measurement, never a token saving (#1332).
  Escalate only contested or design-level verdicts: a handful, never the fleet.
- `wf-pin-audit.py` (harness-doctor check 23) scans the week's workflow scripts for missing pins,
  uncapped fan-outs and over-broad schema `required` lists.

### Fan-out hygiene (full text; `CLAUDE.md` carries the short form)

- Hard-cap every data-driven fan-out with both `.slice(N)` and schema `maxItems`.
- Dedup findings across producers at a barrier before spawning verifiers.
- Batch related claims per verifier: one host or subsystem per agent, not one claim per agent.
- The verify fleet should not outnumber its producers. 5 producers x 8-cap = 40 verifiers is a bug,
  not thoroughness.
- Mark `required` only the fields a downstream stage actually reads, at any nesting depth; leave the
  rest optional and default them in the reader. Every mismatch silently regenerates the whole
  output, and one- and two-field schemas fail this way too (issue #676 has the live numbers).
  wf-pin-audit WARNs past 7 required, or 5 paired with `additionalProperties: false`.

## Verification ladder (compose, don't stack)

Follow merge-and-end in CLAUDE.md: CI, then one `/pro-gate` review only when the diff touches billing,
auth, migrations or CI. `/review-adversarial-first` and `/ce-code-review` run only when the operator names
them. `/codex-consult` is an optional cross-model second opinion and bundled
`/code-review` a worker's in-progress bug check on its own diff; neither is a tier. For findings, prefer *diverse-lens*
verification (correctness / security / does-it-reproduce) over N identical refuters.

## Campaign template (the whole-codebase use case)

The shape a big campaign skill (refactor, audit, migration, dead-code) routes through:

1. **Scout inline** — discover the work-list first (list files, find the sites, scope the diff). You need
   the *work-list* before you orchestrate, not before the task.
2. **Fan out** — one unit per agent: read-only analysis via parallel subagents; mutating work via
   worktree-isolated subagents or `codex exec --cd`; multi-stage-per-unit via a Workflow `pipeline`.
3. **Verify each** — adversarial/diverse-lens verification as each unit completes (pipeline, not barrier).
4. **Synthesize** — collect the survivors; dedup; a completeness-critic pass for what was missed.
5. **Gate** — run the project's real tests + the lightest review tier that fits; never merge un-gated.

Scale to the ask: a quick check → a few finders, single-vote verify. "Be comprehensive" → larger finder
pool, 3–5-vote adversarial pass, synthesis. Log anything you cap (top-N, no-retry) — silent truncation
reads as "covered everything" when it didn't.
