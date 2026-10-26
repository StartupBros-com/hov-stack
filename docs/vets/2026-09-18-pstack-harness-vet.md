# Harness vet: pstack (cursor/plugins 0.15.2) and pstack-codex against the dotfiles harness

- Date: 2026-09-18. Skill: harness-vet. Landing: this note plus follow-up issues for the EXTRACT items (work-spec #1197, PR #1198). Nothing installed, enabled, or ported in this PR.
- Candidate A: `pstack`, Lauren Tan's Cursor plugin, directory `pstack/` in `github.com/cursor/plugins` @ `1f84288b` (2026-09-18; the pstack tree last changed in `5bf2b154`, 2026-09-13), plugin version 0.15.2, MIT. 158 files: 47 skills (23 are one-page `principle-*` leaves; 46 of 47 carry `disable-model-invocation: true`), `poteto-mode` with 23 playbooks, 2 agent personas, the `benny` issue-triage pack (12 files), a 10-page guide, and about 6k lines of Bun/TypeScript (`orch/` state store and CLI, `watch-pr/` PR policy engine) plus `check-plan.mjs`, `worktree-audit.sh`, `bootstrap.ts`, `show-me-your-work/scripts/log.sh`. Maintenance: 30 pstack commits 2026-07-22 to 2026-09-13; first commit 2026-05-23; cursor/plugins has 8,095 stars.
- Candidate B: `pstack-codex`, `github.com/ScriptedAlchemy/pstack-codex` @ `594accc7` (2 commits, repo created 2026-09-17, 54 stars). Pins upstream `e31650ee` (2026-09-16). A blob-hash check of its `upstream-inventory.json` against the Candidate A clone matched 158 of 158 files with 0 extras, so both candidates describe one pstack tree. It adds a Codex runtime contract (`CODEX.md`), a marketplace manifest, agent TOMLs, validators (`validate.sh`, `parity.py`, `check-upstream.sh`), `ledger.mjs`, `bridge.mjs`, and tests.
- Target: the global harness (`~/dotfiles` synced to `~/.claude`), operator-stated. Runtime: interactive Claude Code 2.1.271, background jobs, headless `claude -p` dispatch, and Codex delegation (codex-cli 0.153.2). Cursor is not a runtime here; Cursor-only mechanisms were translated or marked non-portable, never exercised.
- Task (operator statement): "go through this with a fine-toothed comb... where is our stack better? where does theirs beat ours? are there any major architectural issues we need to address? or just synthesize and cherry-pick?"
- Install state: no pstack component anywhere in `~/.claude`, `~/.agents`, `~/.codex`, or dotfiles. Name collisions only: `bro`, `tdd`, `teach` (unrelated content), `cursor` (a Cursor CLI skill).
- Prior verdicts: pstack `unslop` was vetted 2026-09-02 (memory note `anti-slop-skill-list-vet-2026-09`): EXTRACT deferred to open issue #894. Verified this run: `unslop/SKILL.md` changed on 2026-09-07 (cursor/plugins PR #329, "density and mannered-prose pass"), so #894 must re-diff against current content. No other pstack component had a verdict. Searched: `~/.claude/projects/-home-user-hov-stack/memory/`, `memory/`, `docs/vets/`, `harness/`.
- Run decisions (unattended, defaulted): landing = PR for review plus tracked issues; deep-vets = 3 prompt-skill finalists (`interrogate`, `how`, `blast-radius`); readers capped at 8, verify fleet at 8; Sonnet for verification and behavioral arms, session model (Fable 5.1) for readers, lenses, and judges.

## Method and coverage

- Phase 3 (read): one workflow, 8 subsystem readers plus 5 cross-cutting lenses (orchestration, verification regime, safety and autonomy, context economy, automation), 13 agents, 1.34M tokens, 670 tool calls, 33 minutes. 64 component rows, 109 claims queued. The stub detector flagged 2 thin rows (`worktree-cleanup.md`, three Codex-port packaging rows); all four were SKIP rows whose incumbents were opened elsewhere in the run (`wt-sweep.sh` in full under C099, `~/.codex/AGENTS.md` by the vet author, `settings.json` skillOverrides by the context-economy lens, `harness-doctor.sh` under C082).
- Phase 4 (verify): one workflow, 8 Sonnet verifiers with a REFUTED default, batched by subsystem. 108 of 109 claims received an independent verdict: 66 CONFIRMED, 22 REFUTED, 19 PARTIAL, 1 NOT_RUN (C004, the em-dash rule's absence from Response shape, was self-verified by the reader against the injected CLAUDE.md and never entered the fleet). 0.79M tokens, 369 tool calls, 12 minutes. 17 audit-dividend findings. The eighth verifier was also asked to re-open every incumbent behind the 28 SKIP or unverified rows; it completed its three assigned claims and recorded that sweep as NOT_RUN rather than fabricate 28 judgments. Coverage for each SKIP row therefore rests on the per-claim verdicts cited in that row; the three rows with no claim id (`poteto-mode` Subagents, `session-pickup`/`pause-safely`, `standing-mode.md`) were opened by the vet author inline under the same REFUTED default, and the evidence column says so.
- Phase 4 (empirical): the candidates' own suites ran under a sandbox HOME; three planted-defect fixtures ran 10 arms x 2 trials; three separate judges scored blind holding the answer keys.
- Harness incident during the run: the worktree route guard locked the sandbox test-runner subagent and several readers out of Bash after one `cd`-plus-`git` command (every later command refused, including `pwd`). The test run was redone from a script file; readers recorded the lockout as coverage gaps. This is the failure mode already in memory as `cc-worktree-guard-smears-concurrent-subagents`.
- Coverage gaps recorded by readers: the Codex port's 43 non-representative skill bodies were diffed by script, not read; `ce-babysit-pr/references/watch-loop.md` and the second half of `pro-gate-loop.sh` were read by the lens but not the reader; Cursor's Automations `routine` and `SendToUser` primitives were not found in the live docs (webhook triggers were).

## Measured, not inferred

### Candidates' own tests (sandbox HOME, log in `harness/vet-fixtures/pstack-2026-09/candidate-tests.log`)

| Suite | Result |
|---|---|
| upstream `bun test orch` | 14/14 pass |
| upstream `bun test watch-pr` | 38/38 pass across 3 files |
| upstream `bun run typecheck` | exit 0 |
| upstream deps | `commander 14.0.0`, `typescript`, `bun-types`; all npmjs; no network in tests (gh is shelled via `spawn`, tests inject a fake reader) |
| port `scripts/validate.sh` | pass, 47 skills |
| port `parity.py --report` | 158/158 upstream files covered: 56 retained verbatim, 100 adapted, 2 replaced |
| port `check-plan.test.mjs` | 5/5 pass |
| port `ledger.test.mjs` | 8/8 pass |
| port `bridge.test.mjs` | 5/5 pass; server binds `127.0.0.1` only |
| port `runtime.test.mjs` | 2 pass, 2 skipped (live Codex opt-in) |
| port `worktree-audit.test.mjs` | **1 of 1 fails on Linux** |
| port `scripts/test.sh` | exit 1 (the same failure) |

The red test is a real defect, not a sandbox artifact. `worktree-audit.sh:72` computes a transcript timestamp with `stamp=$(stat -f '%m' f || stat -c '%Y' f)`. GNU `stat -f` prints the filesystem block to stdout before exiting 1, so the captured value is multi-line text plus the epoch, the integer compare fails silently, `last_ts` stays 0, and a worktree with a recent Codex session lands in the `safe` bucket instead of `verify-recent-chat`. The port shipped its own red test. Upstream's copy is macOS-only outright (`stat -f '%m %N'`, `date -r`).

### Behavioral arms (Sonnet, `claude -p --bare --tools ""`, 2 trials per arm, about $3 total; outputs and judge reports under `harness/vet-fixtures/pstack-2026-09/`)

Construct caveat for all three: this measures each skill's doctrine text steering one no-tools model. pstack's multi-model subagent mechanics (interrogate's panel, how's explorer fan-out, blast-radius's run-the-code step) were not exercised.

Fixture R, code review on `anti-slop-list/invoice-code-bundle.md` (18 planted defects, 8 honest controls), judge report `judge-R-interrogate.md`:

| Arm | Trial 1 /18 | Trial 2 /18 | Mean | Mean false accusations |
|---|---|---|---|---|
| bare | 12.5 | 13.5 | 13.0 | 2.0 |
| pstack `interrogate` (SKILL.md + 4 references) | 13.5 | 13.5 | 13.5 | 1.0 |
| our `thermo-nuclear-code-quality-review` | 13.0 | 13.5 | 13.25 | 1.0 |
| our vendored `code-slop` (SKILL.md + 25 rules) | 16.0 | 16.0 | 16.0 | 0.0 |

`interrogate`'s doctrine text is level with thermo-nuclear (which shares its lineage) and well below code-slop; K8 was missed by all eight outputs, K3 and K4 by every arm but code-slop. The rubric and lens text earn nothing over what we own. Only the N-way multi-model panel mechanism remains a candidate, and it was not exercised here. Prior run on this fixture (2026-09-02): bare 10.75, thermo 13.0, code-slop 15.25; same rank order.

Fixture H, code explanation on `explainer-toolbox-2026-09/fixtureB-code.ts` (12 edges, 2 quirks, 3 traps), judge report `judge-H-how.md`:

| Arm | Trial 1 /14 | Trial 2 /14 | Mean | Traps sprung | Invented |
|---|---|---|---|---|---|
| bare | 10 | 9 | 9.5 | 0 | none |
| pstack `how` | 11 | 12 | 11.5 | 0 | none |
| our adapted `show-me` | 8 | 9 | 8.5 | 0 | none |
| `ce-explain` (compound-engineering) | 11 | 12 | 11.5 | 0 | none |

`how` beat bare and our call-tree skill and tied our best incumbent. Every arm fabricated nothing, so the gain is structural (diagram plus Gotchas template), not fabrication suppression.

Fixture B, blast radius on the same module with a proposed `fingerprint()` change (judge-derived key, smoke test), judge report `judge-B-blast-radius.md`:

| Arm | Consumers named /5 (mean) | False positives (mean) | Invented (mean) | Disclosed no-tools limits | Prose words (mean) |
|---|---|---|---|---|---|
| bare | 4.5 | 0.5 | 0.5 | 0 of 2 | 450 |
| pstack `blast-radius` | 5.0 | 0.0 | 0.5 | 2 of 2 | 1,110 |

The doctrine improved completeness and honesty, not correctness: both arms fabricated the same nonexistent scan-reuse optimization once, and the doctrine's own Cleared and Check scaffolding did not catch it.

### Platform facts checked live (docs fetched or scratch runs, not memory)

- Claude Code skill frontmatter supports `paths:` (glob-gated loading). Verified against `code.claude.com/docs/en/skills` and empirically: a scratch skill with `paths: ["*.ts"]` refused even manual `/name` invocation with no matching file in context, while its twin without `paths:` loaded. None of our 158 installed skills uses it (`rg -l '^paths:'` over every SKILL.md: 0 hits).
- `mode:`, `reminder:`, `icon:`, `color:` are silently inert for locally loaded Claude Code skills: a scratch skill carrying all four loaded and invoked cleanly, no error, no unexpected roster entry. The inward vet added the boundary: a claude.ai Skills API upload of the same file hard-rejects unknown keys, so a verbatim port is inert on the CLI and an error on that surface.
- Cursor does ship a deny-capable `preToolUse` hook (`cursor.com/docs/agent/hooks`). pstack does not use it anywhere in either tree (`find -iname '*hook*'` hits only node_modules type definitions). The reader's "Cursor lacks hooks" framing was wrong; the accurate finding is that pstack chose prose over the mechanism its host offers.
- `codex plugin add <name>@<marketplace>` and `codex plugin marketplace add|list|upgrade|remove` are real subcommands of codex-cli 0.153.2. The live Codex delegation probe for "do our PreToolUse hooks fire inside `codex exec`" was NOT_RUN (Codex quota unavailable on the active account); the structural evidence (no hook section in `~/.codex/config.toml`, hooks registered only on Claude Code's tool loop, memory note `pretooluse-hooks-survive-bypass-permissions`) supports the known answer: they do not.
- `gh pr view --json statusCheckRollup` returned all 421 contexts on pytorch/pytorch#197562 (423 on the inward vet's re-run hours later; a live PR's count moves), so watch-pr's explicit GraphQL pagination loop solves a problem `gh` does not have.
- The GitHub issue and PR numbers cited in `watch-pr/github.ts:254` and `types.compile.ts:67` (#172004, PR 179929) do not exist in cli/cli (404; newest issue there is #14471). They may be Cursor-internal references; either way the test suite, not the citations, carries the cross-check's justification.
- `git patch-id --stable` survived a rebase that shifted line numbers and blob SHAs (identical before and after) while sha256 of the diff bytes changed; it did not survive a rebase that inserted content inside the hunk's 3-line context window. So patch-id is a strictly better staleness key than our `pro-gate-loop.sh` digest of diff bytes, not an unconditional one.
- CLAUDE.md is 27,868 bytes (about 6,970 tokens by the bytes/4 estimate) against the 5,944 tokens `scripts/shape-audit/README.md` measured; the always-on surface grew about 17% since that measurement.

### Reader claims the verifiers overturned (the corrections that moved verdicts)

- "No perf or profiling skill exists" (reader: ADAPT the hillclimb/perf cluster). REFUTED: `profiling-software-performance`, `extreme-software-optimization`, `system-performance-remediation-local`, and `ce-optimize` all exist; the first carries the same baseline-trace-hypothesis loop. Verdict became SKIP.
- "No Diátaxis-based document-mode selection exists" (reader: EXTRACT technical-writing). REFUTED: `documentation-website-for-software-project/references/DIATAXIS.md`. Verdict became SKIP.
- "No de-escalation policy for repeated bot comments exists". REFUTED: `ce-resolve-pr-feedback/references/pipeline-mode.md:19-20`.
- "No incumbent classifies or dedupes an incoming bug report". REFUTED: `user-support-triage-for-saas-and-open-source-projects/SKILL.md:58,219`.
- "We already have a typed local ledger" was REFUTED in the other direction only for the dispatcher's own domain: `dispatcher-ledger.sh` is a typed, tested (T1-T17 invariants), first-terminal-wins ledger. It is single-purpose; the general store gap stands, see architectural issues.
- "code-slop and Comment Sicko produce different outcomes on the same diff". REFUTED on the invoice fixture's comment lines: both rule sets flag the same lines.
- "Our tdd skill lacks the falsifiability check" was PARTIAL: the tautological anti-pattern overlaps; only the "five shapes that still pass when every import returns undefined" list is new.
- Our `thermo-nuclear-code-quality-review` (added 2026-09-01) shares near-verbatim wording with pstack's `interrogate/references/code-quality-review.md` (pstack's first commit: 2026-05-23). Our incumbent is descended from pstack material, so "ours independently covers this" is not a clean claim for that lens.

## The operator's four questions

### Where ours is stronger (verified, with the mechanism)

- Safety is code, theirs is prose. `git-guard.js` maps all five CLAUDE.md categories to named rules; `loop-guard.js` denies `gh pr merge`, `gh pr ready`, and the REST merge endpoint under `CLAUDE_LOOP_GUARD=1`; deny rules and PreToolUse hooks survive `--permission-mode bypassPermissions` (measured 2026-08). pstack's entire autonomy model, including autopilot-full's merge authorization, lives in the same natural-language channel a "going to bed" override travels in, and pstack ignores the `preToolUse` hook Cursor provides.
- Verification is enforced, theirs is invoked. `verify-on-stop.js` blocks a "done" while a resolved verify command fails; `work-spec-check.sh` refuses an issue missing Acceptance Criteria, Planted negative, or No-Claim Boundary before `gh issue create`; `gate-check.sh` fails an empty required-check set. Every pstack verification skill is `disable-model-invocation: true` with no mechanical backstop.
- Claims are distributed and expiring. `wt-new.sh` claims with a label plus session-stamped comment, read-after-write confirmation, 48h TTL, and `claim-reap.sh` fail-closed release, across hosts sharing one gh identity. pstack's orch lock is a local PID check with no host id (`store.ts:367-378`), and `ledger.record` overwrites a prior verdict for the same PR and SHA (`store.ts:1330-1352`) where our dispatcher ledger is first-terminal-wins with an audit-correction overlay.
- Authority widens by measurement. `dispatcher-ratchets.md`'s rung ladder, keep-rate and cost-per-kept knobs, `needs-human.sh`'s closed escalation-category table, and the $120 `MAX_USD` budget fence passed straight to `claude --max-budget-usd`. pstack grants autonomous merge as a playbook choice.
- Eval receipts exist. Four vet-fixture READMEs report executed runs with recall scores, false accusations, contamination catches, and dollar costs; `shape-audit` caught a model-drift false positive before trusting a CLAUDE.md change. pstack's `eval.md` has never been run by its authors (no results anywhere in the tree or the guide, confirmed by commit history).
- Skill visibility has four tiers via two cross-checked mechanisms (43 frontmatter-hidden, 37 settings-demoted, 35 name-only, 41 fully on), and `skill-mention-resolver.js` fixes the mid-message slash failure that `disable-model-invocation` designs create. pstack has the binary flag only.
- Resume asks first. `ce-handoff` stops and asks the user to pick among candidate prior sessions; pstack's `session-pickup.md` treats a single located trail as authoritative.

### Where theirs beats ours (verified)

- An N-way parallel multi-model adversarial review tier in one invocation (`interrogate`: one reviewer per configured model family, a lead-judgment filter with a 5-item Act-On cap and a mandatory Dismissed section). Our ladder has no panel step anywhere: `ce-code-review` runs exactly one external peer (`cross-model-review.md:3`), pro-gate is a single oracle, thermo-nuclear is single-session. The advantage is the mechanism, not the rubric: on fixture R the rubric text scored level with thermo-nuclear and below code-slop.
- A typed local state store for standing multi-day programs (`units.tsv`, `ledger.tsv`, `frontier.json`, `inbox/`, `gates.md`, a thin `orch.ts` CLI with atomic-rename writes and `--force-to-steal-lock` that prints whom it stole from). Our only local ledger is the dispatcher's single-purpose one, and `dispatcher-ratchets.md` says of Rung 3 parallelism "NOT a config flip ... budget that redesign when considered" (its literal "not designed yet by intent" is Rung 2's, for merge authority).
- Merge staleness keyed by `git patch-id` (`shipping.md` step 3) plus the rule that a verified PR above an unverified one waits (`06-verify-and-ship.md:85`). We have neither: `grep patch-id` over `scripts` and `ce-babysit-pr` hits only a comment, and no stack-ordering rule exists in CLAUDE.md or `harness/`.
- Near-zero always-on cost by design: 46 of 47 skills hidden, a one-line-per-principle index inside the router, leaf text read only when a principle is applied. Our CLAUDE.md pays about 7k tokens on every session and subagent stream, including streams `shape-audit` measured as unaffected by the content.
- A generated, diffable per-role model config (`setup-pstack` writes one rule file, validates every slug against the live model list, refuses unconfirmed slugs, and lets a deleted line fall back to the skill default). Our routing is CLAUDE.md prose plus `wf-pin-audit.py`, which audits pins but generates nothing.
- Eval blinding mechanics we lack: a literal banned-keyword list checked against everything the candidate can see, and a transcript chain-fidelity check ("grade from the files it really opened, never from its self-report"). Our vet fixtures score outputs only; `harness-vet/SKILL.md` never mentions chain fidelity.
- A worker Brief schema (GOAL, SCOPE, CONTEXT, ACCEPTANCE, VERIFY, TIMEBOX, FORBIDDEN, REPORT, STANDING) given to every spawned worker. `dispatcher-tick.sh:762-775` builds its child prompt by string concatenation; no `GOAL:` or `FORBIDDEN:` marker exists anywhere in the harness.
- Two small hygiene controls: a formula-injection guard on TSV cells (`log.sh:30-37`, `store.ts` `cleanCell`) that `dcg-update.sh`'s `history.tsv` writer and papercut's store lack, and a read-back after every side-effecting external write (`ledger.mjs` prepare/resolve) that `needs-human.sh:84-90` lacks after `gh issue create`.
- A per-repo generated verification skill with a user-POV feature map (`create-verification-skill`, 44 portable lines, no Cursor calls) and a baseline-versus-patched "does this PR fix its linked issue" proof (`verify-existing-fix.md`, three outcomes). Nothing in our harness generates a maintained app-driving recipe or proves an open PR against its issue by reproduction.
- A vendoring pipeline that proves full coverage: `UPSTREAM.json` pin, `check-upstream.sh` drift report, `parity.py` hash inventory (this vet used its inventory to prove the two candidates were one tree). Our `skills-patches/` UPSTREAM.md convention is hand-written prose with no hash list and no scripted drift check.

### Architectural issues in ours the comparison exposed (ranked)

1. **[major] The tracked dcg hook pin points at a version that does not exist.** `settings.json:532` names `~/.local/lib/dcg/v0.13.3/dcg`; the directory holds v0.10.0 through v0.14.4 with no v0.13.3; the live `~/.claude/settings.json:614` names v0.14.4; `dcg/README.md` still documents v0.6.5. A fresh `sync.sh install` from the repo would wire a broken guard path, and a missing hook binary fails open. `install.sh` L90-101 records this drift class once before (2026-08-06). Fix: correct the pin and add a harness-doctor assertion that the settings.json dcg version equals the installed symlink target. Security-posture file: proposed, not applied here.
2. **[major] Always-on cost is flat, not tiered.** CLAUDE.md (about 7k tokens, up 17% since the last measurement) reaches every subagent stream. pstack's index-then-leaf design is the concrete alternative. The fix is a measured compaction campaign with `shape-audit` as the instrument, not a rewrite by taste; candidate sections are the ones `shape-audit` already found inert in subagent streams.
3. **[major] Guards stop at the Codex boundary.** Nothing in `~/.codex/config.toml` gates a delegated `codex exec`; our hooks fire only on Claude Code's tool loop. codex-cli 0.153.2 has its own hook subsystem (`codex --help` lists `--dangerously-bypass-hook-trust`), so the gap is an unconfigured mechanism, not an absent one. Known and documented in memory, but CLAUDE.md routes implementation batches to Codex. pstack-codex's `CODEX.md` at least states the boundary in one paragraph ("Do not treat a persona's no-write instructions or `sandbox_mode` default as an independent security boundary"); `HARNESS.md` should say the same and the delegation scripts should default `--sandbox`.
4. [minor] `settings.json` carries `sandbox.enabled: false` next to a populated `sandbox.network.allowedDomains` list; per `code.claude.com/docs/en/settings-reference`, `enabled: false` means Bash runs unsandboxed and `allowedDomains` pre-allows traffic only from sandboxed commands, so the list is inert. Dead config or an unfinished intent; decide which.
5. [minor] `wt-sweep.sh` has no recent-session signal: its only liveness inputs are directory mtime (120 min) and a live `/proc` scan. A worktree a human was reviewing in chat minutes ago, with no process holding it and no write since, is sweepable. Our transcripts (`~/.claude/projects/<slug>/*.jsonl`, `cwd` field) make the signal cheap.
6. [minor] No N-way multi-model review tier (see above).
7. [minor] TSV writers (`dcg-update.sh` history, papercut) have no formula-injection guard; `needs-human.sh` has no read-back after `gh issue create`.
8. [minor] The `paths:` skill-loading channel is unused across all 158 skills, so every file-type convention we have reaches the model only by description matching.
9. [minor] The worktree route guard smears concurrent subagents (hit the test runner and several readers this run; memory note exists). Each occurrence silently degrades a fleet's coverage.
10. [minor] Standing multi-day multi-worker orchestration has no local state design (`dispatcher-ratchets.md` Rung 3: "budget that redesign when considered"); pstack's store layout is a reference design for when it is budgeted, not a cherry-pick now (no consumer, fails the Ceremony Test).
11. [minor] Doc drift caught in passing: the `claude-loop-default-budget-fence-raised-to-60usd` memory says $60, live `dispatcher.env` says `MAX_USD=120`; CLAUDE.md's review-ladder line says no tier judges design consistency, but `harness-tests.yml:1462` runs a `design-drift` self-scan that fails the build; `shape-audit/README.md`'s token figure is stale; `claude -p --allowedTools X "prompt"` swallows the prompt unless `--` precedes it (verifier reproduced twice).
12. [minor] Two zero-run-green modes named in `evidence-regime.md` §2 (a test selector matching nothing, a benchmark emitting null summaries) have no mechanical gate; only the CI-checks mode does.

### Synthesize or cherry-pick

Cherry-pick. No component earned ADOPT or ADAPT as delivered (one, `create-verification-skill`, would reach ADAPT only after a standalone sandbox run), and the value concentrates in about a dozen small, named patterns plus two architectural lessons. Wholesale adoption of either plugin would add 47 explicit-only skills for a runtime we do not use (Cursor) or a Codex plugin whose one Linux-relevant safety script is broken. Ranked list, "now" tier first:

| # | What | From | Into | Effort | Value status |
|---|---|---|---|---|---|
| 1 | Fix the dcg pin and add the harness-doctor version assertion | audit dividend | `settings.json`, `harness-doctor.sh` | S | real defect, operator applies |
| 2 | Formula-injection guard for TSV cells | `show-me-your-work/scripts/log.sh:30-37` | `dcg-update.sh` `record_outcome`, papercut writer | S | real gap, security-positive |
| 3 | Read-back after `gh issue create` | `pstack-codex ledger.mjs` prepare/resolve | `needs-human.sh:84-90` | S | real gap |
| 4 | `git patch-id` as the staleness key, plus "verified above unverified waits" | `shipping.md` step 3, `06-verify-and-ship.md:85` | `pro-gate-loop.sh` `digest_of`, `drive-dont-defer-merges.md` | S | measured: patch-id survived a line-shifting rebase, sha256 did not; caveat: context-window edits still change it |
| 5 | "Never fabricate a link, citation, or transcript reference; link only artifacts produced or read this session" | `poteto-mode/SKILL.md` Writing the reply | CLAUDE.md Honest Work (one clause; passes the armor test) | S | absent today; unverified value |
| 6 | Document and use the `paths:` channel, including the manual-invocation gotcha | `typescript-best-practices/SKILL.md:1-6` | `cc-skill-visibility-overrides.md`; one convention skill as the pilot | S doc, M pilot | platform fact verified live |
| 7 | Hash inventory plus upstream drift check for vendored skills | `pstack-codex parity.py`, `check-upstream.sh` | `skills-localize.sh audit`, a `check-upstream` script over `skills-patches/*/UPSTREAM.md` | S-M | real gap; this vet needed exactly this |
| 8 | Banned-keyword blinding and transcript chain-fidelity check | `playbooks/eval.md` steps 3 and 6 | `harness-vet/SKILL.md` phase 4, `evidence-regime.md` §6 | S | methodological; our fixtures score output only |
| 9 | Worker Brief schema with TIMEBOX and FORBIDDEN | `orchestrate.md:38-50` | `agent-swarm/SKILL.md`, `research-delegation.md`, `dispatcher-tick.sh` child prompt | S | observed defect class: under-specified worker packets (memory `parallel-fix-workers-need-the-exact-json-shape-pinned`) |
| 10 | N-way multi-model review panel skill between ce-code-review and pro-gate, using code-slop and thermo-nuclear as the lens content (not interrogate's rubric) | `interrogate` panel shape and lead-judgment filter, `arena` cross-judge rule | new `skills-local/panel-review`, Workflow-driven, user-invocable | M | doctrine text measured as no better than thermo and below code-slop (fixture R); the panel mechanism itself is unmeasured, deciding test = panel vs single reviewer on the invoice fixture |
| 11 | Certainty ladder and "find the one fact" triage | `blast-radius/SKILL.md:19-34` | `verify-review/SKILL.md` | S | smoke: recall 5.0 vs 4.5, honesty 2/2 vs 0/2, correctness flat |
| 12 | Recent-session signal for worktree sweeps | idea from `worktree-audit.sh` (our own implementation; the port's is broken) | `wt-sweep.sh` reading `~/.claude/projects/<slug>/*.jsonl` cwd | M | safety-positive, no observed incident |
| 13 | Rationale template (usage first) and six scrap tells | `architect/references/rationale-template.md`, `SKILL.md:66-70` | `codebase-design` overlay via `skills-patches/` | S | gap confirmed (`DESIGN-IT-TWICE.md` has no scrap phase) |
| 14 | Baseline-versus-patched proof for "PR fixes its issue" and the no-symptom-injection rule | `benny verify-existing-fix.md`, `control-adapter.md:68` | `verification-architecture.md` DoD steps | S | gap confirmed |
| 15 | Confidence tiers with required phrasing and Sources-consulted-with-nulls | `why/references/epistemics.md`, `synthesizer-prompt.md:99-109` | ce-explain local patch (`ce-plugin-local-patches.md`) or our explain conventions | S | gap confirmed; unverified value |
| 16 | Shared-record sweep and status-tag enum when resuming | `recall/SKILL.md` step 4, line 29 | `ce-handoff` resume path or a cass wrapper | S-M | gap confirmed (cass is transcript-only) |
| 17 | Bug-fix TDD escape conditions, evidence contract, five-shapes falsifiability, repro-commit-before-fix | pstack `tdd/SKILL.md:23-44`, `principle-test-behavior-not-implementation`, `bug-fix.md:11` | `tdd` overlay (jsm-managed) | S-M | partial overlap with existing anti-patterns |
| 18 | Missed-trigger transcript check and structural-enforcement demotion gate | `reflect` divergent-reviewer, synthesizer step 4 | `memory-dream` or `memory-mine` | M | gap confirmed |
| 19 | Automation pre-enablement checklist (7-point thread safety, coordinate freeze, coordinator-only writes) | `setup-benny/SKILL.md:244-266`, `triage-issue-reports/SKILL.md:19-42` | new `harness/automation-preflight-checklist.md`; consumer = the next outbound-sending automation (dispatcher Rung 2, HoV bots); defect class = ungated Discord sends named in CLAUDE.md | S | must pass the Ceremony Test at filing |
| 20 | Per-repo generated verification skill with feature map | `create-verification-skill`, `maintain-verification-skill` | `skills-local/create-verification-skill`, user-invocable, UPSTREAM.md pinned | M | EXTRACT until the deciding test runs: generate one for a SITES repo and run its live pass standalone; only then may ADAPT be rendered |
| 21 | CLAUDE.md index-then-leaf compaction | `poteto-mode` Principles index | CLAUDE.md sections `shape-audit` finds inert in subagent streams, leaves under `harness/` | M-L | measured before and after with `shape-audit`, never by taste |
| 22 | Two doctrine lines: persona no-write is not a security boundary; never emulate wakeups with a detached sleeping shell | `pstack-codex CODEX.md` | `HARNESS.md` Autonomy and Automation sections | S | absent today |
| 23 | Smaller ports: diagram-buildup and banned meta-commentary into `eli5`; explorer Open-Questions contract and reconcile-by-rereading into `codebase-archaeology`; incremental-since-last-edit and multiple-instances guard into `memory-mine`; attack-the-premise census into `docs/solutions/`; generated role-to-model config file | `teach`, `how`, `automate-me`, `principle-attack-the-premise`, `setup-pstack` | as named | S each | gaps confirmed, value unverified |
| 24 | Refresh #894 against `unslop` @ 2026-09-07 | `unslop/SKILL.md` | #894 | S | prior verdict, source moved |

Not cherry-picked and why: the orch store as a whole (Bun runtime, Graphite-only frontier, PID lock, overwrite semantics, no consumer today); watch-pr as a whole (ce-babysit-pr, pr-snapshot, and gate-check already cover it, `gh` does not truncate rollups, and the cited justifications are unverifiable); `check-plan.mjs` (no plan format to lint; `work-spec-check.sh` covers issues); benny and make-bot-ui as automations (Cursor Automations objects); the 23 principle leaves as installed skills (zero always-on cost but no demonstrated need beyond the three patterns above); `technical-writing`, `bro`, `no-comments`, `swarm`, `arena`, `figure-it-out`, `teach`, the pause and pickup playbooks (covered, see table).

## Verdicts (per component, target = global harness)

Rollup over 57 content rows: ADOPT 0, ADAPT 0, EXTRACT 17 (one of them, `create-verification-skill`, gated on the sandbox run that would justify ADAPT), SKIP-the-mechanism-but-EXTRACT-a-pattern 13, SKIP 26, REJECT 1; both delivery mechanisms SKIP. Placement for every SKIP and REJECT row is no installation.

| Component | Verdict | Placement / activation | Evidence | State |
|---|---|---|---|---|
| Cursor plugin delivery (`/add-plugin pstack`) | SKIP | none | Cursor is not a runtime here | no install |
| Codex plugin delivery (`codex plugin add`, `scripts/install.sh`) | SKIP | none | 47 explicit-only skills into `~/.codex`; our Codex use is `codex exec` delegation under our AGENTS.md; install registers a marketplace (security-posture); ships a Linux-broken safety script | no install |
| `poteto-mode` router (triggers, principle index, mode/reminder) | SKIP mechanism, EXTRACT index-then-leaf | doctrine idea, item 21 | C001 CONFIRMED (description matching covers routing), C002 CONFIRMED (mode/reminder unsupported), C102 CONFIRMED (inert) | proposed |
| `poteto-mode` Autonomy | SKIP | none | CLAUDE.md Autonomy plus code enforcement (C003 CONFIRMED) | covered |
| `poteto-mode` Writing the reply, Comments | EXTRACT one rule | item 5 | dividend: no citation rule in CLAUDE.md or skills; em-dash rule already in the harness writing rules | proposed |
| `poteto-mode` Subagents, model tiering | SKIP | none | CLAUDE.md Model Routing (lines 54-58, opened by the vet author), `wf-pin-audit.py` and `model-routing-forensics.md` read in full under C076 and C077 CONFIRMED | covered |
| `orchestrate.md`, `autopilot-full`, `autopilot-stack`, guide 07 | SKIP playbooks, EXTRACT Brief | item 9 | agent-swarm, Workflow, dispatcher ratchets; C055 CONFIRMED | proposed |
| `babysit.md`, `bugbot-triage.md` | SKIP | none | ce-babysit-pr; C064 REFUTED (de-escalation exists), C007 CONFIRMED (calibration log exists) | covered |
| `opening-a-pr.md` | SKIP | none | ce-commit-push-pr; C008 REFUTED is a style difference, not a gap | covered |
| `shipping.md` | EXTRACT | item 4 | C009 CONFIRMED, C063 PARTIAL (measured), C039 CONFIRMED | proposed |
| `worktree-cleanup.md`, upstream `worktree-audit.sh` | SKIP script, EXTRACT signal idea | item 12 | macOS-only; C099 CONFIRMED | proposed |
| `session-pickup.md`, `pause-safely.md` | SKIP | none | `ce-handoff/SKILL.md:44` ("MUST stop and ask the user to select a candidate") and `hooks/PreCompact/compact-preserve.js` opened by the vet author inline; the orchestration lens read ce-handoff in full | covered |
| `bug-fix.md` | SKIP (ordering rule folded into item 17) | none | ce-debug; C011 REFUTED (no repro-before-fix ordering in ce-debug) | covered |
| `feature.md` | SKIP | none | ce-work; C012 REFUTED (ce-plan bakeoff is conditional, a design choice) | covered |
| `investigation.md` | SKIP | none | ce-explain, C013 CONFIRMED | covered |
| `multi-phase-plan.md`, `check-plan.mjs` | SKIP | none | Cursor plumbing; no plan format to lint (C014, C051, C058 CONFIRMED absent, no consumer) | not planned |
| `hillclimb`, `perf-issue`, `runtime-forensics`, `trace-forensics` | SKIP | none | C015 REFUTED: four perf skills exist | covered |
| `prototype.md`, `visual-parity.md` | SKIP | none | C016 PARTIAL (our /prototype is UI-only, ce-prototype covers behavior), C017 REFUTED (design-drift is a different job); no pixel-parity task today | do-not-retry trigger below |
| `refactoring.md` | SKIP | none | isomorphic skills pin with golden outputs (C018 PARTIAL, ours stricter) | covered |
| `autonomous-run.md` | SKIP | none | /goal Stop hook, claude-loop budget fence (C019 CONFIRMED, C088 PARTIAL) | covered |
| `authoring-a-skill.md` | SKIP | none | skill-tuner, skill-creator, writing-for-agents (C020 PARTIAL) | covered |
| `eval.md` | EXTRACT | item 8 | C021 REFUTED our coverage; C093 CONFIRMED; C094 CONFIRMED pstack never ran it | proposed |
| 23 `principle-*` leaves, guide 08 | SKIP as skills, EXTRACT three patterns | items 17, 21, 23 | C022 PARTIAL, C023 CONFIRMED, C025 PARTIAL | proposed |
| `unslop` | EXTRACT (prior) | #894 | C024 REFUTED: source changed 2026-09-07 | tracked |
| `tdd` | EXTRACT | item 17 | reader gap plus C025 PARTIAL | proposed |
| `technical-writing` | SKIP | none | C026 REFUTED: DIATAXIS.md exists | covered |
| `typescript-best-practices` | SKIP content, EXTRACT `paths:` finding | item 6 | C027 REFUTED (paths supported), C028 PARTIAL (TYPE-SHRINKS covers), C103 CONFIRMED | proposed |
| `bro` | SKIP | none | C029 CONFIRMED collision, different skill | covered |
| `no-comments`, Comment Sicko | SKIP | none | code-slop; C031 REFUTED (same outcomes) | covered |
| `interrogate` | SKIP rubric text, EXTRACT panel mechanism | item 10 | fixture R: 13.5/18 vs thermo 13.25 vs code-slop 16.0; C032 CONFIRMED shared lineage with thermo-nuclear, C033 CONFIRMED single peer today | proposed |
| `reflect` | EXTRACT | item 18 | C034 CONFIRMED, C104 CONFIRMED | proposed |
| `arena` | SKIP | none | ce-bakeoff (C035 CONFIRMED no default panel table, minor) | covered |
| `architect` | EXTRACT | item 13 | C036 CONFIRMED | proposed |
| `blast-radius` | EXTRACT | item 11 | C037 CONFIRMED; fixture B smoke | proposed |
| `figure-it-out` | SKIP | none | work-spec template already requires falsifiable criteria and planted negatives; C038 CONFIRMED no single composing doc, no consumer | not planned |
| guide 04, 06 | EXTRACT two lines | items 4, 23 | C039 CONFIRMED | proposed |
| `why` | EXTRACT | item 15 | C040 CONFIRMED; C041 REFUTED (prose-only revisions upstream) | proposed |
| `how` | SKIP, EXTRACT explorer contract | item 23 | fixture H tie with ce-explain; C042 CONFIRMED | proposed |
| `teach` | SKIP, EXTRACT two rules | item 23 | C043 CONFIRMED | proposed |
| `recall` | SKIP mechanism, EXTRACT sweep | item 16 | C044, C045 CONFIRMED | proposed |
| `show-me-your-work`, `log.sh` | EXTRACT | items 2, 22 | C046 CONFIRMED, C107 CONFIRMED | proposed |
| `swarm` | SKIP | none | agent-swarm, Workflow; C047 PARTIAL (no cloud subagent primitive, session-level cloud exists) | covered |
| orch store, CLI, `bootstrap.ts` | SKIP, EXTRACT atomic-write pattern | item 3 | C048 CONFIRMED overwrite, C050 CONFIRMED no Graphite, C086 PARTIAL, C089 CONFIRMED | not planned |
| `watch-pr` engine | SKIP | none | C059 CONFIRMED single-source rollup, C060 REFUTED, C061 CONFIRMED read-only, C062 REFUTED citations | covered |
| benny `triage-issue-reports` | SKIP automation, EXTRACT idioms | item 19 | C066 REFUTED (partial coverage), C067 CONFIRMED no lock, C100 CONFIRMED no checklist | proposed |
| benny `reproduce-and-fix-issues` | EXTRACT | item 14 | C068, C069 CONFIRMED | proposed |
| `create-verification-skill`, `maintain-verification-skill` | EXTRACT (unverified value, deciding test named) | item 20 | C070 CONFIRMED gap, C071 CONFIRMED portable; the standalone sandbox run VERDICTS.md requires before ADAPT was not performed, so ADAPT is not rendered | proposed |
| `automate-me` | SKIP, EXTRACT guardrails | item 23 | C072 CONFIRMED absent (no demonstrated need), C073 CONFIRMED Cursor-only, C104 CONFIRMED | proposed |
| `make-bot-ui` | SKIP | none | Cursor Automations; C074 PARTIAL (webhook real, routine/SendToUser not found), C075 CONFIRMED | not planned |
| `setup-pstack` | SKIP, EXTRACT idea | item 23 | C076, C077 CONFIRMED | later |
| pstack-codex `CODEX.md` contract | EXTRACT two lines | item 22 | reader; C096 PARTIAL | proposed |
| pstack-codex vendoring pipeline | EXTRACT technique | item 7 | C080 CONFIRMED; dividend | proposed |
| pstack-codex `codex-agents/*.toml` | SKIP | none | C081 PARTIAL (Claude agents have no sandbox key; different tier) | covered |
| pstack-codex `standing-mode.md` | SKIP | none | `~/.codex/AGENTS.md` (142 lines, opened by the vet author inline) is the live standing-instruction file the port's method reproduces | covered |
| pstack-codex `validate.py`, `runtime.test.mjs`, `openai.yaml` policy | SKIP | none | harness-doctor, evidence-regime, skillOverrides (C082 PARTIAL, C092 PARTIAL) | covered |
| pstack-codex `ledger.mjs` | EXTRACT | item 3 | tests 8/8; C106 CONFIRMED no amend verb (ours has one); C109 CONFIRMED | proposed |
| pstack-codex `bridge.mjs` | SKIP (reference pointer) | none | C084 CONFIRMED no incumbent, no need | not planned |
| pstack-codex `worktree-audit.sh` | REJECT | none | red test shipped; Linux `stat -f` defect buckets recent worktrees as safe (measured) | rejected |
| pstack-codex translation methodology | EXTRACT note | `third-party-skill-vetting.md` | C085 CONFIRMED 47/47 touched, no leftover Cursor tokens | proposed |

## Price (surviving components)

- Context cost: every EXTRACT above lands in a harness doc, a script, or a user-invocable skill; none adds an always-on line except item 5 (one clause in CLAUDE.md Honest Work) and item 21, which removes lines. Item 10 adds one user-invocable skill description (about 300 bytes of roster). Item 20 adds one user-invocable skill plus a generated per-repo skill in that repo's `.claude/skills/`.
- Armor test: item 5 is one clause with zero caveats; item 22 is two sentences. Nothing else touches CLAUDE.md.
- Placement and off-switch: skills-local ports carry `disable-model-invocation: true` and a `LICENSE` plus `UPSTREAM.md` pin per `third-party-skill-vetting.md`; jsm-managed targets (`tdd`, `codebase-design`, `codebase-archaeology`) go through `skills-patches/` overlays; ce-explain changes go through `ce-plugin-local-patches.md`. Reload semantics unverified for the overlay path this run (PARTIAL).
- Delivery versus content: both plugin delivery mechanisms SKIP independently of content; dotfiles sync is the delivery for every item.
- Supply chain: no self-updating channels, no network calls, no writes outside declared scope in any read file. `bootstrap.ts` runs `bun install --frozen-lockfile` then re-execs; not ported. The port's `install.sh` registers a Codex marketplace; not run.

## Audit dividend (what vetting pstack exposed about the harness)

The items above numbered 1 through 12 under architectural issues, plus: (a) our own `thermo-nuclear-code-quality-review` descends from pstack material (2026-09-01 versus pstack's 2026-05-23 first commit), which the prior anti-slop vet did not record; (b) a sandbox built from `CLAUDE_CONFIG_DIR` plus `HOME` under `/tmp` still wrote a `debug/` log containing strings from the real session's settings (verifier could not reproduce on a second look; worth one deliberate probe before trusting that isolation for anything trust-sensitive); (c) `dispatcher-ledger.sh` fails open on lock contention by design while the port's ledger fails closed, and that trade-off lives only in an inline comment.

## Do-not-retry unless

- Cursor plugin delivery: Cursor becomes a runtime this harness targets.
- Codex plugin delivery: a Codex-native workflow needs pstack-style routing, the port's `worktree-audit.sh` passes its own test on Linux, and the port shows maintenance beyond its first two commits.
- `visual-parity.md`: a pixel-exact UI migration task appears (wsl-cdp can drive it; nothing scripted exists).
- `multi-phase-plan.md` and `check-plan.mjs`: `docs/plans/` gains a fixed structure that a deterministic linter could gate.
- orch store as a whole: dispatcher Rung 3 is budgeted; then read `orchestrate.md`'s store layout as the reference design.
- pstack-codex `worktree-audit.sh` (REJECT): `worktree-audit.test.mjs` passes on Linux at a newer port revision.
- Any row marked `covered`: the covering mechanism named in that row's evidence column is retired or materially changed, or a new target task no longer fits it; a matching name is never the trigger.
- Re-audit triggers for the EXTRACT items: pstack changes the source file named in the row (check with the item-7 upstream-drift script once it exists), or the incumbent named in the row is retired.

## Outcome

- Report and this note: carried by PR #1198; every state in this note is proposed until that PR merges, and the PR records the merge. Follow-ups filed: #1201 (the dcg pin drift, a security-posture fix for the operator) and #1202 (the 24 ranked EXTRACT items and the one proposed ADAPT, each to land as its own PR with an inward vet). Nothing installed, enabled, or ported.
- Fixture assets committed under `harness/vet-fixtures/pstack-2026-09/` (runner, 20 arm outputs, judge reports, candidate test log); answer keys stay in their sibling fixture directories, judge-only.
- Memory pointer: `pstack-harness-vet-2026-09` in the dotfiles project memory.

## Dispositions (2026-09-20)

Final state of the 24 rows in the cherry-pick table, copied from #1202 at close; the PR carrying this section closes that issue. PARKED rows are decided against until the named trigger fires and are not open work; CONDITION rows wait on a named external change. When a trigger fires, file a fresh work-spec citing the row here. Triage lenses (2026-09-19): ceremony test, friction and context cost, evidence strength, each refute-by-default.

- Landed: rows 2, 3, 7, 9, 11, 22 (line 1 only; line 2 already lived in a memory note), and 24 in PR #1208 (f7a4ac4); row 8 (harness-vet blinding list with the chain-fidelity deferral) in PR #1219 (d724144); row 20 in PR #1214 (d410fc3, issue #1213), ADAPT rendered after the deciding sandbox run passed on better-ccflare with startupbros environment-blocked; row 21 measured at 27,868 bytes, about 7,741 tokens, 3.9% of 7-day cache-read, with the /rent-check diffs in PR #1210. Row 1 (the dcg pin) was filed as #1201 and is closed.
- Conditional: row 4 (pro-gate staleness key) needs the runtime to accept a normalized-diff fact in its decision inputs; the script-only key was written, tested, and withdrawn in #1208 because it bypassed gate authority. Row 6: the `paths:` doc line landed in #1208; the pilot conversion waits on a convention skill that wants it. Row 12 (recent-session signal for wt-sweep) only if a worktree under live review is ever swept, suppress-only, dry-run against sweep history first.
- Parked: rows 5, 10, 13, 14, 15, 16, 17, 18, 19, 23. Row 10's pre-test (2026-09-19) scored lead-judgment synthesis over six existing reviews at 14.0/18 with 2.0 false accusations against the single code-slop reviewer's 16.0/0.0. Row 17: tdd is jsm-managed and the overlay copies whole files, so one added rule means a whole-file fork across every update. Row 23 was unbundled; the generated role-to-model config is dropped outright as a second source of truth beside CLAUDE.md Model Routing. Each remaining row's trigger is recorded on #1202.

Spin-off streams the vet produced:

- Row 21's judge-routing question: the `lean-reader` subagent type with `omitClaudeMd` (PR #1222, issue #1221), the experiment record with the retraction of an in-session stall claim (PR #1224, issue #1223), and the verdict "judge stages not worse than general-purpose at n=2" plus the CLAUDE.md routing clause (PR #1237). Record: `experiments/lean-reader-2026-09-19/RESULTS.md`.
- That measurement exposed better-ccflare aborting thinking-only streams as "no meaningful progress" (better-ccflare#356): fixed by a 14-minute pre-commit budget (better-ccflare#357, deployed 2026-09-20 and verified on production requests past the old window), the loop now passes `--thinking-display summarized` (PR #1226, issue #1225), and `showThinkingSummaries: true` is set in settings (PR #1246).
- Row 7's drift triage classified the 20 MOVED overlays (6 no change, 10 cosmetic, 3 upstream gone, 1 substantive) and re-pinned kill-ai-slop to upstream f6e2ae3 (PR #1231, issue #1230).
- Row 24's refresh: #894's first finalist, petergyang/no-ai-slop, measured SKIP on the prose fixture (PR #1240; incumbent 18.5 and 18.5 of 21 against 15.5 and 16.0, no false accusations on either). #894 closed with its items 7-19 deferred on trigger.
- Hazard found while running row 24's arms: the Workflow tool hands every arm the triggering user message verbatim, and an imperative message makes general-purpose arms act on it instead of the stage prompt (memory `workflow-arms-execute-the-relayed-user-request`). Measurement arms ran through the Agent tool instead.
