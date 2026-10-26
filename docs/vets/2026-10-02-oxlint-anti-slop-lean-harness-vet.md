# Harness vet: oxlint, anti-slop, oxlint-plugin-jev and Lean as deterministic validation of agent work

- Date: 2026-10-02. Skill: harness-vet. Issue dotfiles#1513. Landing: report plus this note, PR for review. Nothing installed into any target; hook and settings changes are proposed below, not applied.
> **Reading this after the rollout:** Measurements and original proposals below describe the 2026-10-02 vet. The dated closeout in §7 records what subsequently shipped and what remains planned. The linked unified plan supersedes the original implementation sketches.

- Operator ask: "oxlint and Lean being used to validate agent work in deterministic, fast ways. Is this something we would want to bring into our harness and our Claude Code CLI / Codex desktop setup?" Judged for a solo developer who wants set-and-forget long-running agents that produce better work.

## Verdict in one screen

**The fast deterministic layer is worth building. The specific artifacts in the links mostly are not.**

1. **oxlint itself: real, measured, future-safe for native rules.** On the members app (3,472 TS files) ESLint with the repo's own config takes 53-55s cold; oxlint native takes 1.3-1.5s (about 40x); one file takes about 1.0s under ESLint and 0.2-0.3s under oxlint. oxlint 1.86.0 also loads the members app's in-house ESLint plugin unmodified and fires 9 of its 10 rules. Native rules follow semver; the JS-plugin API is explicitly exempt and alpha.
2. **anti-slop: SKIP in every target.** Its own suite is green and the plugin is clean AST-only code, and the planted fixture caught 17 of 17 defects. On real code the sampled precision was 1 true positive in 73 hits on the members app, about 12 in 150 on better-ccflare, and 6 in 114 on oracle. Nearly every hit is a test fixture, a boundary parser that legitimately takes `unknown`, or a formatting opinion. No rule reached the enable bar in any repo. Issue #895 (the 2026-09-02 trial proposal) is closed by this evidence.
3. **oxlint-plugin-jev: REJECT for the harness, SKIP per repo.** It is an LLM judge inside a linter: non-deterministic by construction, ships raw source to a third party on every cache miss, and fails open (exit 0, one warning) in every run where the `CI` variable is unset, which is every hook and background job here.
4. **Lean: SKIP as a gate; the essay's own example has a specification hole.** Both gists compile without `sorry` on Lean 4.34.1, and the proved type `List α → SortedList α` is satisfied by a sort that returns the empty list, because the spec never requires a permutation. Writing fleet code in Lean has no fit. Boris Cherny's "model the SDK, 16 PRs" claim is video-only and unverifiable. A one-shot smoke of his workflow on this harness's own loop-guard did produce a real bug (the guard fails open when its state directory is unwritable), but every finding was confirmed by a Node probe and none needed Lean; the keeper is the state-machine property test, not the 3 GB toolchain.
5. **The real gap is diagnostic delivery and verified coverage, not another linter.** The inspected formatter discarded diagnostics. Automatic JavaScript/TypeScript Stop selection did not add lint, although custom verification commands and Python Ruff already supported it. The inspected Codex configuration did not demonstrate post-edit or completion parity. The proposals use the repos' own linters; their implementation and client-acceptance status are separate facts, recorded in §7.

**Recommended now (proposals, operator applies):** (A) a model-visible per-edit lint feedback hook that runs the repo's own fast linter on the edited file; (B) lint in the Stop gate for repos whose lint is under the 180s budget; (C) Codex hook parity for A and B. **Recommended per repo:** turn on `preserve-caught-error` (found real cause-dropping rethrows in all three repos) in each repo's own linter. **Not recommended:** vendoring anti-slop, jev, a 3 GB Lean toolchain, or replacing ESLint in the members app this quarter.

## 1. Source identity, targets, run choices

### Candidates (all normalised into `/tmp/hv-oxlint-lean-20261002/`)

| Artifact | Identity | Shape |
|---|---|---|
| dmmulroy/anti-slop | `c44ef22ca116d0ba62a3ff663a0bd13a3f3fa40b` (2026-09-10), package `oxlint-plugin-anti-slop` 0.1.2 `private: true`, MIT, 5,106 stars, 35 commits, one dominant author (31 of 35) | oxlint JS plugin: 18 generic rules, 5 opt-in Effect rules, shared scope helpers, a vendored eslint-stylistic padding engine (about 1,050 lines), and a bundled `install-anti-slop` skill whose `install.mjs` is a 21-line `cpSync` |
| wobsoriano/oxlint-plugin-jev | `d9a1838f32e3b5a15b441dec91b2ef816802006f`, npm 0.1.3 (2026-09-24), MIT, 66 stars, created 2026-09-19, README: "experimental" | one rule `jev/ask`; plain-English yes/no questions answered by the TypeSafe Jev API through `@typesafe-ai/sdk` on a synckit worker |
| ngrislain, "Don't vibe, prove" | essay 2026-03-12, two gists (`2f0c8486…` insertion sort, `19eff850…` merge sort) | Lean 4, core only, no imports |
| X posts | Mulroy 2087537790061850984 and 2087531327000117630 (anti-slop launch); Tan 2089067865098113024 (elimination hierarchy); Cherny 2077460395279692197 (automation thesis) and 2102543349102338309 (Lean/TLA+ on the Agent SDK); Larson 1992381784299114698 ("99%" oxlint anecdote); Soriano 2101080178617471088 (jev); Steigerwald 2102510340311544275 (quotes the essay) | fetched in full via the X API this run |

### Targets and concrete task

- **T1** the global harness: `~/.claude` hooks and settings, `~/.codex/hooks.json`, the Windows-side Codex desktop config at `/mnt/c/Users/user/.codex/config.toml`. Runtime: interactive and unattended background jobs on WSL2.
- **T2** the members app (`acme-org/announce-bot` @ `619f94f`): Turborepo, 10 Next.js apps, TypeScript 5.9.3, ESLint 9.39 with eslint-config-next, turbo, and the in-house ESLint plugin (10 incident-derived rules).
- **T3** better-ccflare (@ `78d584b`): Bun monorepo, TypeScript 6.0.2, Biome 2.4.10 recommended rules as lint plus format.
- **T4** oracle (@ `b6ee5f7`, fork of steipete/oracle 0.15.2): TypeScript 7.0.2, the one fleet repo already on oxlint (`^1.73.0`).
- **Task** (operator's words, made concrete): an agent edits TypeScript in one of these repos during a long run; the validation layer must catch low-evidence patterns deterministically, fast enough to run per edit or at Stop, and feed the finding back to the agent. Judged by planted known-positives under the real tree layout, sampled precision on real code, and measured latency against the incumbents.

### Run choices

- Targets inferred from the ask (recorded as inferred). Codex desktop is treated as a runtime surface of T1.
- Sweep: 5 readers, 3 verifiers, 1 Lean smoke run (workflow `wf_bca1fa23-6b8`); 4 precision judges and 1 speed verifier (workflow `wf_246f726a-d42`). Readers and verifiers on Sonnet via lean-reader or lean-collector; judges at the session model. About 1.0M subagent tokens across both workflows.
- Landing depth: PR for review (no explicit instruction; `docs/vets/` is this repo's established location).

### Install state and prior verdicts

- oxlint: installed only in oracle (`^1.73.0`, resolves to 1.73.0 live). No global oxlint, biome, lean, elan or lake binary on PATH. ESLint and tsc shims exist. `settings.json` allows `Bash(eslint:*)`, `Bash(biome:*)`, `Bash(tsc:*)` and has no oxlint entry.
- anti-slop, jev: no copy anywhere under `~/SITES`, `~/.claude`, `~/.codex`. The npm name `oxlint-plugin-anti-slop` is squatted by an unrelated publisher (prior vet).
- **Prior verdict reused.** anti-slop was vetted 2026-09-02 (dotfiles#892, PR #893, memory note `anti-slop-skill-list-vet-2026-09`) as SKIP with trial proposal #895, open and unactioned. Its artifact findings carry: `install.mjs` is a copy with no network; the npm name is squatted. This run re-opened fit because the candidate changed (+3 generic and +4 Effect rules since `e8c4880`) and the task changed (harness-level deterministic gate for long-running agents, never vetted). Related method notes reused: react-doctor vet 2026-09-20 (select rules by sampled precision, never by fixture hits), shadcn/lint vet 2026-09-20 (plant a known-positive before trusting a count), memory `codex-harness-enforcement-2026-07` (Codex desktop has no global hooks).
- Searched: `docs/vets/` (11 notes), `memory/-home-user-hov-stack/`, `~/.claude/projects/*/memory/`, `harness/`, `HARNESS.md`, `CONCEPTS.md` for oxlint, anti-slop, jev, typesafe, lean, biome, react-doctor. No note on jev, Lean, or oxlint as a harness gate.

## 2. Measured, not inferred

All runs on WSL2, Node 24.12.0, pnpm 10.33.2, Claude Code 2.1.287, Codex CLI 0.160.0. Scripts and logs are under `/tmp/hv-oxlint-lean-20261002/{scripts,results}/` (scratch, not committed). Other agents were active on the host during the timing runs; differences under 2x are noise.

### Toolchain and own suites (fresh HOME sandbox)

- `pnpm add -D oxlint@1.86.0 @oxlint/plugins@1.86.0 oxlint-tsgolint@latest typescript@latest`: exit 0 (tsgolint 7.0.2003, TypeScript 7.0.2).
- anti-slop `pnpm install --frozen-lockfile` then `pnpm check` (oxlint, 24 RuleTester files via tsx, `tsc --noEmit`, skill-asset drift check): exit 0 in 19.8s. The skill's bundled assets equal `src/` minus the 24 test files (diff -rq). The vendored copy, pinned upstream to oxlint 1.78.0, loads and fires under oxlint 1.86.0.
- jev `npm ci --ignore-scripts`, `npm run build`, `vp test`: 126 tests passed, 1 live test skipped (needs `JEV_LIVE=1` and a key). No key was set and api.typesafe.ai was never contacted.
- Lean: elan into a sandbox `ELAN_HOME` (3.0 GB after the stable toolchain), Lean 4.34.1. `InsertionSortList.lean` exit 0 in 0.93s with two deprecation warnings (`if_pos`, `if_neg`); `SortList.lean` exit 0 in 2.74s, no output. Zero `sorry` in either file.

### Planted known-positive (instrument validity)

`fixtures/planted-slop.ts` (17 labelled defects P1-P17) and `fixtures/planted-control.ts` (only documented-allowed constructs) were copied into `git archive` tree copies of all three targets at real app paths (`apps/acme-web/app/__hv_planted/` and equivalents) and linted with the toolchain oxlint and the anti-slop config.

- slop.ts: **17 of 17 planted rules fired** at the expected lines (13 anti-slop, `oxc/no-accumulating-spread`, `eslint/no-unused-vars`, `eslint/no-debugger`, `typescript/no-explicit-any`). Native-only config: the 4 planted native rules fired (plus an unplanted `unicorn/no-useless-spread` on the same line as P9), the anti-slop ones correctly did not.
- control.ts: **0 findings from any semantic anti-slop rule**; 2 findings from `require-readable-spacing` (lines 6 and 45), the stylistic rule, which therefore carries a measured false-accusation rate even on honest code.

### Broad runs (oxlint 1.86.0, `--format json`, correctness error + suspicious and perf warn across eslint/typescript/unicorn/oxc/react/import/promise/node, plus `typescript/no-explicit-any`)

| Target | Files | Native diagnostics | Native wall | + anti-slop diagnostics | + anti-slop wall | Plugin overhead |
|---|---|---|---|---|---|---|
| the members app (whole monorepo copy) | 9,114 | 57,659 | 4.08s | 165,804 | 13.82s | 3.4x |
| the members app's apps/acme-web | 3,496 | 13,534 | 1.32s | 51,307 | 5.35s | 4.1x |
| better-ccflare apps+packages | 1,197 | 5,644 | 0.61s | 49,388 | 4.38s | 7.2x |
| oracle (own `.oxlintrc.json`) | 350 | 3 | 0.30s | — | — | — |
| oracle (broad preset) | 355 | 510 | 0.18s | 11,463 | 1.58s | 8.8x |

Top anti-slop producers in the members app: `require-readable-spacing` 77,532, `require-safety-comment-for-type-assertion` 14,071, `no-unsafe-dictionary-type` 4,359, `no-unknown-parameters` 3,458, `no-runtime-typeof` 2,837, `no-known-value-widening` 2,153, `no-chained-type-assertions` 1,444. `react/react-in-jsx-scope` (49,305) is the legacy-JSX-transform rule and a preset artefact, not a finding. The broad preset is untuned; these counts are inputs to precision sampling, not a quality comparison (ESLint reports 0 diagnostics on the members app under its tuned config).

### Precision sampling (6 evenly spaced hits per rule, read in the target copy; TP = a change a careful reviewer would ask for, NEC = necessary or idiomatic, STYLE = faithful to the rule but no evidence value)

| Repo | Rules judged | Samples | TP | TP in live code | Rules reaching ENABLE | Rules reaching TRIAL |
|---|---|---|---|---|---|---|
| the members app, anti-slop semantic (16 rules) | 16 | 73 | 1 | 1 | none | none (`no-runtime-typeof` needs types) |
| the members app, volume + native (19 rules) | 19 | 114 | 17 | 15 | `no-explicit-any`, `no-unused-vars` (see caveat) | `preserve-caught-error`, `set-state-in-effect`, `no-unstable-nested-components` |
| better-ccflare (28 rules) | 28 | about 150 | 12 | 12 | none | `no-unsafe-dictionary-type` (2 of 3 live), `no-object-parameters` (1 of 2 live), `set-state-in-effect`, `preserve-caught-error` (4 TPs, one pattern in one file) |
| oracle (32 rules) | 32 | 114 | 6 (7 rule-level hits; one line flagged by two rules) | 6 | `preserve-caught-error` (4 of 6) | `no-chained-type-assertions` scoped to `src/` (1 live TP, n=1) |

Caveat on the members app ENABLE row: the `no-explicit-any` and `no-unused-vars` true positives are all in one app's component story gallery, where that app's own `eslint.config.mjs` lines 27-28 turn both rules off on purpose, and ESLint already runs both everywhere else. oxlint re-found a deliberate exclusion, not a capability gap. Also `no-module-mocking` scored 0 hits on the members app because the tests use node:test `mock.module`, which the rule does not match; on oracle its 62 hits were all `vi.mock` in tests and all judged taste for a CLI that mocks Chrome DevTools, network and the filesystem.

Representative true positives: a members-app service double-casts a database client five times because generated RPC types are missing (fix: regenerate types); four API rethrows discard the status callers check; oracle `bin/oracle-cli.ts:1596` double-casts a field whose precise type exists at `src/sessionManager.ts:285`. Representative false accusations: oracle's `isRecord` type guard at `src/config.ts:243`, flagged by three rules at once; a members-app metadata helper whose conditional spread intentionally distinguishes absence from explicit undefined; a provider-object helper using hardened `Reflect.get` on hostile objects.

### Speed against the live incumbents (live checkouts, read-only invocations)

| Measurement | ESLint (repo config) | oxlint native | oxlint + anti-slop | Biome |
|---|---|---|---|---|
| the members app's apps/acme-web, cold, whole app | 55.35s / 52.83s | 1.47s / 1.28s | 5.22s / 5.10s | — |
| the members app single .tsx file, n=5 | 0.93-1.01s (median 0.97) | 0.19-0.34s (median 0.25) | 0.29-0.45s (median 0.37) | — |
| the members app `pnpm lint` at root (turbo, AGENTS.md's command) | 39.41s (one logged run; an earlier run in the same session measured 73.85s before its log was overwritten; cache status not recorded) | — | — | — |
| better-ccflare whole repo | — | 0.55s / 0.51s | 4.02s / 4.05s | 0.60s / 0.53s |
| better-ccflare single .ts file | — | 0.14-0.36s (n=3) | — | 0.06-0.07s (n=3) |
| oracle, own config, live (oxlint 1.73.0) | — | 0.13s | — | — |

Reading: native oxlint is about 40x faster than ESLint cold on this repo and at parity with Biome; the anti-slop JS plugin costs 3-9x over native (a few seconds of fixed start-up plus per-file bridge cost) but stays under 15s on a 9,114-file monorepo. Every single-file latency is far inside the 15s auto-format hook timeout; even ESLint at about 1s per file is hook-feasible. The official oxlint claim is "50 to 100 times faster than ESLint" for native rules with no stated conditions; Brad Larson's "99%" is a different repo and includes formatting, so it is neither confirmed nor contradicted here (97.5% measured for native on the members app, 90.5% with the plugin). Note: the members app's ESLint is **not** type-aware (resolved config has no `project` or `projectService`), so the 53s is syntactic linting of about 132 rules.

### Platform facts (fetched from official docs this run)

- oxlint JS plugins are "currently in alpha"; the `createOnce` speed path is "Right now it isn't [faster]. But it will be soon" (oxc.rs writing-js-plugins). JS plugins cannot be type-aware (js-plugins page, "Not supported yet").
- Type-aware oxlint needs `oxlint-tsgolint` and "TypeScript 7.0+ is required"; the members app (5.9.3) and better-ccflare (6.0.2) are blocked, oracle (7.0.2) is not. Irrelevant to the members app today: none of its 132 enabled rules is type-aware.
- Versioning (oxc.rs versioning page): "JavaScript custom plugins - The plugin API and behavior may change without notice" in any patch or minor; nursery and type-aware rules likewise. Native rules follow semver; minors add rules and "are not considered breaking changes even if they cause new errors". Release cadence is weekly (1.81.0 2026-09-01 through 1.86.0 2026-09-28).
- `@oxlint/migrate` 1.86.0 generates `.oxlintrc.json` from an ESLint flat config but "cannot migrate ESLint plugins from file paths in the same repo", so the members app's in-house ESLint plugin is hand-wired.
- Claude Code hooks (code.claude.com/docs/en/hooks): a PostToolUse `decision: "block"` "adds the reason next to the tool result. Claude still sees the original output"; `hookSpecificOutput.additionalContext` is "added to Claude's context alongside the tool result"; a Stop `decision: "block"` "prevents Claude from stopping". This harness already uses the PostToolUse block shape in `hooks/PostToolUse/worktree-claim-advisory.js:209,234`.
- Codex hooks (learn.chatgpt.com/docs/hooks): PostToolUse `decision: "block"` "replaces the tool result with that feedback"; Stop `decision: "block"` "creates a new continuation prompt ... using your reason"; "Non-managed hooks must be reviewed and trusted before they run" via `/hooks`, keyed to the hook's hash. Desktop-app support is not stated; the Windows config's `hooks.state` shows a WSL project hook was loaded, so the desktop does run hooks.

### jev degrade paths (run, not read)

| Condition | Result |
|---|---|
| no key, `CI` unset, `ci:"skip"` | one stderr warning, 0 diagnostics, exit 0 |
| no key, `CI` unset, `ci:"fail"` (the shipped example config) | same: skips, exit 0 ("Outside CI it always skips") |
| no key, `CI=1`, `ci:"skip"` | warning, exit 0 |
| no key, `CI=1`, `ci:"fail"` | thrown plugin error naming `TYPESAFE_API_KEY`, exit 1 |

Egress: only `https://api.typesafe.ai` appears in the plugin and SDK dist; `TYPESAFE_BASE_URL` redirects both the source snippets and the bearer key to any host with no allowlist (`src/index.ts:57-60`). Every request body carries raw source for up to 25 matched nodes of up to 4,000 characters each (`src/jev.ts:117-139`). The SDK exposes no seed or temperature; the default model id `jev-latest` floats and the cache key uses the alias (`src/jev.ts:193-196`). TypeSafe's site and docs state no data-retention terms (fetched this run). Pricing is "$42 per billion input tokens"; a 3,000-file repo with two function rules is roughly 3,000 requests per cold run.

### Lean modeling smoke run (W2, n=1)

One general-purpose agent, Lean 4.34.1 in the sandbox, subject = the harness's own loop-safety pair (`hooks/PreToolUse/loop-guard.js`, `hooks/Stop/verify-on-stop.js`), budget 12 `lean` invocations.

- Outcome: a compiling model (`lean/smoke/LoopModel.lean`, 8 theorems, no `sorry`) in **4 invocations** (one wasted on the elan shim without `ELAN_HOME`, two compile-error rounds, one clean). Proved: call `max+grace+1` is a hard stop when every state write persists; the Stop gate blocks at most once per turn. Stated as counterexample theorems: fail-open when state never persists; fenced denials never advance the counter; a failing verify can still end in an allowed Stop.
- The agent then confirmed the counterexamples against the **real JS**, not the model, with a probe script and a throwaway HOME (`CLAUDE_LOOP_MAX=3`, grace 2). I re-ran the probe on a fresh HOME this session with identical output:

| Case | Observed |
|---|---|
| A normal | allow allow allow deny deny HARDSTOP HARDSTOP HARDSTOP |
| B 12 fenced `gh pr merge` calls | deny x12, no state file written |
| C state dir unwritable from the start | **allow x12** |
| D state dir made read-only after 2 calls | **allow x12** |
| E state file corrupted after the hard-stop zone | HARDSTOP HARDSTOP then allow allow allow |

- The agent's own assessment, which I share: the Lean step added "barely" anything over a careful read; its one contribution was forcing the stored-state versus in-memory-state split, which raised the question "what advances when `persisted` is false" and led to case C. Every finding was confirmed by the Node probe, not by Lean; the model verifies the transcription, not the program, and a refactor would invalidate it silently. A plain Node property test would have found the same in less time and stays attached to the code. See §6 for the harness findings this produced.

### Not independently verified

- Boris Cherny's "16 PRs" (no public PR in `anthropics/claude-agent-sdk-typescript` or `-python` matches "lean" or "formal verification"; the post is video-only).
- The anti-slop vendored padding engine against its claimed eslint-stylistic base commit `435c3ea0` (no diff performed; `UPSTREAM.md:28` itself says the upstream suites were not ported).
- Whether `@shadcn/lint` runs correctly under oxlint `jsPlugins` (configured in the probe, produced no findings on the fixture; unknown whether the fixture was a valid trigger).
- jev wire traffic (static read only; no API call was made by design).

## 3. Verdicts

The State column records the original vet disposition, not the later rollout. See §7 for shipped changes.

| Component | Target | Verdict | Placement | Activation | Evidence | State |
|---|---|---|---|---|---|---|
| oxlint native linter | T1 harness | **EXTRACT** the pattern, not the tool: model-visible per-edit lint feedback from the repo's own linter, plus lint in the Stop gate | new `hooks/PostToolUse/lint-feedback.js` and a `lint` branch in `hooks/Stop/verify-on-stop.js`; Codex twins in `codex/hooks.json` | repo-config-driven: fires only where a lint config and local binary exist | single-file 0.2-1.0s measured; feedback contract confirmed in both platforms' docs; harness precedent exists | **proposed, not applied** (security posture); value unverified, deciding measurement in §4 |
| oxlint native linter | T2 members app | **SKIP as replacement now.** The future shape, if ever, is a TRIAL beside ESLint (a single-file pre-pass with the members app's own rule set); that trial is deferred and not proposed this quarter (§4 "Not proposed") | would be `.oxlintrc.json` from `@oxlint/migrate` plus `jsPlugins` for the in-house plugin dist | not now | about 125 of 132 enabled rules native; 9 of 10 in-house rules fire under oxlint; six open items (below) | no installation |
| oxlint native linter | T3 better-ccflare | **SKIP** | — | — | Biome at parity (0.5s), already runs in-loop; oxlint ignores `biome-ignore` so a second linter re-flags suppressed code | no installation |
| oxlint native linter | T4 oracle | already the repo's linter (upstream choice); **EXTRACT**: run it at Stop | fork-local `.claude/verify.sh` running `pnpm lint` (`tsc --noEmit && oxlint`), or `CLAUDE_VERIFY_CMD` | — | 0.13s; today no hook ever runs it | proposed |
| `eslint/preserve-caught-error` (native oxlint rule; also an ESLint core rule) | T2, T3, T4 | **EXTRACT** into each repo's own linter | the members app `tooling/eslint/base.js`; better-ccflare Biome equivalent if one exists, else a Grit plugin or an oxlint pre-pass rule; oracle `.oxlintrc.json` (turn the rule back on) | error after baseline cleanup (the members app has no warn tier) | TP 2 of 6 members app, 4 of 6 better-ccflare, 4 of 6 oracle; real cause-chain loss each time | proposed |
| anti-slop generic rules (18) | T2 members app | **SKIP** | — | — | 1 TP in 73 samples; most hits in tests and boundary parsers | no installation |
| anti-slop generic rules | T3 better-ccflare | **SKIP** (two rules at TRIAL on 2-3 live samples, below the enable bar) | — | — | 12 TP in about 150 samples across 28 rules | no installation |
| anti-slop generic rules | T4 oracle | **SKIP**; close #895 | — | — | 6 TP in 114 samples; `no-chained-type-assertions` 1 live TP; `no-module-mocking` 0 TP on 62 `vi.mock` | no installation; #895 closed by this note |
| anti-slop generic rules | T1 harness | **SKIP** (no global rule set) | — | — | false-accusation shapes are repo idioms; a rule set must live with a repo config | — |
| anti-slop Effect rules (5) | all | not applicable | — | — | no fleet package declares `effect`; the rules fire on any `_tag` literal if misapplied (`src/effect/rules/*.ts`) | — |
| anti-slop `require-readable-spacing` and `require-safety-comment-for-type-assertion` | all | **SKIP** | — | — | 77,532 and 14,071 hits in the members app; the comment rule accepts `SAFETY: x` (regex `require-safety-comment-for-type-assertion.ts:37-45`), so an agent can satisfy it with boilerplate, the very fake evidence the plugin targets | — |
| anti-slop delivery (`install-anti-slop` skill, `install.mjs`, `update.md`) | all | **SKIP** | — | — | copy is safe (no network, no lifecycle hooks, MIT travels); but per-repo vendoring with agent-merged three-way updates, a semver-exempt plugin API, and a skill that enables 19 rules at error at once and adds `.claude/**` to the lint ignore list | no installation |
| oxlint-plugin-jev | T1 harness | **REJECT** for any hook or Stop placement | — | — | fails open whenever `CI` is unset (`src/index.ts:85,235,305`, run this vet); non-deterministic remote model; raw source egress by default; `TYPESAFE_BASE_URL` redirect with no allowlist | no installation |
| oxlint-plugin-jev | T2, T3, T4 | **SKIP** | at most a CI-only overlay config after a precision trial and written retention terms | — | adds a snippet-only classifier where the review ladder already gives full-context LLM review | no installation |
| Lean W1 (production code in Lean with dependent types) | all | **SKIP** | — | — | requires a language change; the flagship spec omits the permutation property (`InsertionSortList.lean:20-29,81-91`; `SortList.lean:142-161`) | — |
| Lean W2 (model existing code in Lean or TLA+, hunt bugs) | T1 | **SKIP the toolchain; EXTRACT the discipline** as a Node property test for small state machines (loop-guard first) | `hooks/tests/loop-guard.test.js` grows cases B-E from the probe; no Lean on PATH | — | smoke n=1: executable end to end, 3 actionable findings, all confirmed by a JS probe, none needed Lean to confirm; 3.0 GB toolchain; Boris anecdote unverified | probe reproduced by the vet; test not written |
| "Turn corrections into lint rules" (Tan, Cherny) | T2 members app | **already adopted** | the in-house ESLint plugin | — | 10 incident-derived syntactic rules with RuleTester coverage and `incident/fix/bypass` messages | n/a |
| Codex hook parity (PostToolUse, Stop) | T1 | audit dividend, **proposal** | `codex/hooks.json` (synced to `~/.codex/hooks.json`); desktop needs `/mnt/c/Users/user/.codex/hooks.json` | requires `/hooks` trust after every change | `~/.codex/hooks.json:1-26` has PreToolUse only | proposed |

Rollups: **T1** 2 EXTRACT (one pattern, one parity proposal), 1 REJECT (jev), 4 SKIP. **T2** 1 TRIAL-beside, 1 EXTRACT (one rule), 1 already-adopted, 4 SKIP. **T3** 1 EXTRACT (one rule), 4 SKIP. **T4** 1 EXTRACT (Stop wiring), 1 EXTRACT (one rule), 4 SKIP, #895 closed. Delivery verdicts are separate from content and are all SKIP or n/a.

## 4. Original proposed changes (historical)

These are the vet's initial sketches, not current implementation instructions. The [unified feedback plan](../plans/2026-10-02-1851-feat-deterministic-validation-feedback-plan.md) supersedes their independent-hook ordering, automatic linter discovery and unproven native-desktop assumptions. Its explicit enrollment and actual-client acceptance requirements govern any future rollout. The original combined-budget assumption in B was not established: subsequent cold members app typechecking alone exceeded 180 seconds.

### A. Model-visible per-edit lint feedback (T1, security posture: a new hook)

- **Rationale.** The only in-loop tool today is `hooks/PostToolUse/auto-format.js`, which runs `biome check --write` or `prettier --write` on the edited file, swallows failures in two empty `catch` blocks (lines 80-86), pipes and never reads stdout/stderr (line 76), and returns its input unchanged on every path, so the model sees nothing until Stop. Diagnostics that reach the model per edit are the cheapest possible "turn the correction into a rule" loop (Lauren Tan's tier 2 in-loop rather than in CI).
- **Exact change.** New `hooks/PostToolUse/lint-feedback.js`, registered after auto-format in the `Edit|Write|MultiEdit` group of `settings.json` (timeout 30). Resolution per edited `.ts/.tsx/.js/.jsx/.mjs/.mts` file: oxlint if `.oxlintrc.json` or `oxlint.config.*` plus a local `node_modules/.bin/oxlint` exist; else Biome `check` (read-only) if `biome.json*`; else ESLint `<file>` if an `eslint.config.*` is found at or above the file (about 1s measured); else no-op. Emit `hookSpecificOutput.additionalContext` with the diagnostic lines (cap 2,500 chars, head not tail), never `decision: block`: the react-doctor and anti-slop readers both show that a blocking lint message can push an agent toward a worse rewrite (`no-array-filter-map.ts:11` recommends iterator helpers that need Node 22+; `no-conditional-empty-object-spread.ts:34-35` recommends a mutable build-up). Codex twin: a `PostToolUse` entry matching `Edit|Write` in `codex/hooks.json` emitting `additionalContext` (Codex adds it as developer context).
- **Provenance and pin.** Harness-authored; no vendored code. Depends only on each repo's own linter and config.
- **Deciding measurement before calling it valuable (this is a behaviour-shaping port with unverified value).** Over 20 agent sessions in the members app and better-ccflare, with and without the hook: count of lint diagnostics present at Stop, count fixed before Stop, and extra tool calls per session. Adopt if findings-at-Stop drop without a tool-call increase above 10%.
- **Price.** Context: at most 2,500 characters (roughly 600 tokens) added per edited file, and only when the linter reports something; zero on clean edits. Tools: none added. Latency: 0.07-1.0s per edit, measured. Supply chain: none (no vendored code; each repo's own linter). Armor test: not a rule, so no caveat budget. Placement and off-switch: profile-gated like auto-format; a repo opts out by having no lint config. Delivery and content are both harness-authored.
- **Rollback.** Remove the settings.json entry; the hook has no state.
- **Off-switch.** `run-with-flags.js` profile gating, same as auto-format.

### B. Lint in the Stop gate (T1 mechanism, T2 and T4 content)

- **Rationale.** `verify-on-stop.js:146-147` auto-detects `typecheck` and `type-check` scripts only; lint reaches Stop only through a repo's `.claude/verify.sh` or `CLAUDE_VERIFY_CMD`. The members app's `verify.sh:19` runs turbo typecheck only; better-ccflare and oracle have no verify.sh. So the ten in-house members app rules and oracle's oxlint never gate an agent's Stop.
- **Exact changes.** (1) the members app `.claude/verify.sh`: append `pnpm lint` (affected, 39-74s across the two runs noted in §2, inside the 180s budget) after typecheck. (2) oracle: add `.claude/verify.sh` with `exec env CI=1 pnpm lint` (0.13s oxlint plus tsc). (3) Optional harness change: teach `verify-on-stop.js` to also run a `lint` script when the typecheck passes, behind an env flag, so repos without a verify.sh get it; this is a hook edit and needs the operator's go.
- **Limits that stay.** The gate blocks once per Stop cycle (`stop_hook_active`, line 337) and returns the last 2,500 characters of output (lines 92, 397-398), which for a large lint run drops the first errors. Consider head-first truncation in the same PR.
- **Rollback.** Revert the one-line script changes.

### C. Codex hook parity (T1)

- `~/.codex/hooks.json` carries PreToolUse dcg and git-guard only. Add PostToolUse (A) and Stop (B) entries in `codex/hooks.json`, run `codex/sync.sh install`, then trust them in `/hooks` (memory `codex-git-guard-hook-untrusted-inert`: any hooks.json change lands untrusted until a human re-trusts). The Windows desktop config has no global hooks.json at all (`/mnt/c/Users/user/.codex/`), a gap recorded in 2026-07 and still open; the desktop's `hooks.state` shows it loaded a WSL project hook, so a `/mnt/c/Users/user/.codex/hooks.json` would be honoured.

### D. One rule, three repos: `preserve-caught-error`

- the members app: `tooling/eslint/base.js`, ESLint core `preserve-caught-error: 'error'` (available in ESLint 9.x), after fixing the sampled sites (two sampled files; expect more, the members app has no warn tier so the backlog must be cleared or carved out first).
- better-ccflare: the four `api.ts` rethrows are one pattern; fix them and check whether Biome 2.4 ships an equivalent rule before adding a tool.
- oracle: `.oxlintrc.json` currently turns `eslint/preserve-caught-error` off (line 15); turning it back on is a fork-policy choice with 9 live hits, 4 of 6 sampled real.

### Not proposed

- Any oxlint install in the members app or better-ccflare this quarter; any vendored anti-slop copy; any jev config; any Lean toolchain on PATH.
- An oxlint entry in `settings.json` allowlists until a repo actually runs it.

## 5. Shared artifact findings versus target fit

**Shared (hold for every target):**
- anti-slop content is clean: no `node:` imports beyond the plugin API, no `child_process`, `fetch`, `eval`, file or network access in `src/` (grep over all 18 rules and 7 helpers); only a module-level `WeakMap` cache and an escaped `RegExp` built from the configured markers. `install.mjs` imports only `node:fs`, `node:path`, `node:url`. No lifecycle scripts, no telemetry, no self-update.
- anti-slop analysis limit: imported bindings are registered as opaque type bindings (`src/shared/type-alias-resolution.ts:75-81`), so in a monorepo where types come from `@kit/*`, Supabase generated types or zod inference, every alias-resolving rule is a syntactic check on the literal annotation. `as unknown as X` is caught regardless; laundering through an imported alias is not.
- anti-slop delivery risks: `install.mjs:9-10` takes any destination including `..`; `--force` merge-overwrites without removing stale files (line 19); `SKILL.md:35` has the agent `npm view` and install the latest registry version with no age or provenance check; `SKILL.md:44-57` adds `.claude/**` and `.codex/**` to `ignorePatterns`; `update.md:26-27` uses `$(mktemp -d)`, which this harness's shape guard refuses. Effect rules fire on any `_tag` literal or chained ternary if registered (`prefer-effect-match.ts:35-50`, `no-manual-tagged-construction.ts:23-34`).
- jev: fail-open outside CI, raw-source egress, unpinned model alias in the cache key, base-URL redirect. These are design choices documented in its README, not hidden behaviour, and they disqualify it as a gate rather than as software.
- Lean essay: `Sorted` is adjacent-pairs with no transitivity requirement; `total` is a hypothesis on every theorem; `isSorted` has no soundness theorem; the gist header prompt asks the AI to define the spec type, contradicting the essay's "human writes the type" workflow (`InsertionSortList.lean:1-2`).

**Target-specific fit (changes with the repo):**
- the members app: no type-aware rules anywhere; the `no-unsafe-*` "off" lines in `base.js:46-52` switch off rules that were never on. `no-restricted-syntax` (3 `getSession` selectors) has no oxlint equivalent; six apps carry `eslint-suppressions.json` with no oxlint equivalent found; carve-out globs are dual-form for turbo's per-package cwd. Lint is merge-blocking: the `Lint` step runs inside the required "ʦ TypeScript" job.
- better-ccflare: Biome `check --write` already runs per edit via auto-format (silently); `typecheck` excludes test files (AGENTS.md:120-125), so the Stop gate misses stale test call sites.
- oracle: upstream deliberately turned off `typescript/no-explicit-any`, `no-unsafe-type-assertion` and `preserve-caught-error`; 500 of the 510 broad-preset native hits are rules upstream switched off on purpose; only 10 are rules it never enabled.

**Prior notes reused and applicability changes:** the 2026-09-02 anti-slop SKIP stands and is now backed by sampled precision on three repos (the first vet ran only the plugin's own suite). The react-doctor lesson (fixture-derived subsets do not select rules) held a third time: 17 of 17 on the fixture, about 1-10% precision on real code.

## 6. Audit dividend and triggers

### Audit dividend (what vetting these exposed about the harness)

Historical findings at the inspected revisions; §7 separates repaired defects from remaining feedback work.

1. **loop-guard fails open when its state cannot be written before the cap is crossed.** `loop-guard.js:447-450` says "Fail closed", but the `!persisted` check at line 451 lives inside the over-budget branch; with an unwritable state directory the count never grows, so that branch is unreachable and every call is allowed (cases C and D above, 12 of 12, reproduced twice). Companion gaps: fenced denials (lines 393-394) never consume a call slot, so a loop on a fenced call is denied forever and never hard-stops (case B); a corrupted state file resets the counter (case E, `session-state.js:103-105`); and in `verify-on-stop.js:337,343-347` the verify block and the handback block share the single `stop_hook_active` exit, so under `CLAUDE_HANDBACK_MODE=enforce` an unresolved PR passes the second Stop once verify has used the block. Filed as dotfiles issues (see §7).
2. **The inspected formatter drops diagnostics.** `auto-format.js` discards Biome diagnostic output and returns unchanged input; that path does not deliver lint findings to the model. Structured PostToolUse output is a different transport and needs actual-client verification. Stop verification already offered a separate diagnostic path. Proposal A addresses edit-feedback delivery, not merely linter speed.
3. **Automatic JavaScript/TypeScript Stop selection did not add lint.** At the inspected revisions, the members app's `verify.sh` was typecheck-only and oracle had no repository Stop command. This was not a universal absence of lint: `.claude/verify.sh`, `CLAUDE_VERIFY_CMD`, and Python Ruff already supported it. The members app repository and oracle repository gaps were subsequently addressed in §7.
4. **The inspected Codex configuration did not demonstrate edit-feedback or completion parity.** A `hooks.state` entry is not proof of native-desktop execution, delivery, or effective trust. The unified plan requires separate WSL and native-desktop acceptance before either is claimed supported.
5. **The members app's ESLint is syntactic.** No `projectService`; the disabled `no-unsafe-*` rules were never active, so `any` flows are unchecked by any tool. On TS 5.9 tsgolint is unavailable; ESLint's `projectService` on a rule subset is the only type-aware option, priced in lint seconds.
6. **One cheap cross-fleet rule fell out:** `preserve-caught-error` found cause-dropping rethrows in all three repos (proposal D).
7. **The fixture-versus-precision lesson, third instance.** A 17 of 17 planted score and a roughly 1% live precision came from the same rule set. Detection fixtures validate the instrument; only sampling real code selects rules.
8. **Tooling gotchas logged as papercuts:** oxlint rejects an entire config for one unknown rule name with "Failed to parse oxlint configuration file" (a validation error wearing a parse error's message); `oxlint --rules` prints nothing without a TTY (use `--rules --format=json`); oxlint does not honour `biome-ignore` comments.
9. **jev's shape is a general warning:** any gate whose correctness depends on a network call must fail closed in hooks and background jobs, and `CI`-gated behaviour differs between CI and agent sessions by default.

### Do-not-retry unless

- **anti-slop (any repo):** a rule, scoped to non-test files with `parse*`/`is*`/`assert*` functions exempt, reaches sampled precision at or above 0.6 on live code in that repo; or upstream ships that scoping; or oxlint's JS-plugin API enters semver (versioning page changes). The npm name squat is irrelevant to this trigger because the project says never to install from npm.
- **oxlint replacing ESLint in the members app:** the six open items close: `no-restricted-syntax` selectors re-expressed, an `eslint-suppressions.json` equivalent found, `@shadcn/lint` and the remaining react-doctor rules verified under `jsPlugins`, the plugin stack timed at monorepo scale, a parity diff of the native React compiler rules against eslint-plugin-react-hooks 7, and the carve-out globs ported. Or the members app moves to TypeScript 7 and wants tsgolint.
- **jev:** TypeSafe publishes retention terms, the plugin fails closed by default regardless of `CI`, and the base URL is allow-listed; even then CI-only, never a hook.
- **Lean W1:** a self-contained module whose correctness is worth a machine-checked proof and can ship as a Lean-compiled artifact. **Lean W2:** a pilot on one concurrency-heavy module (better-ccflare's account selection or rate-limit tracking is the natural candidate, TLA+ first) produces a bug confirmed by a failing test against the real code.
- **Proposal A value:** the deciding measurement in §4 runs; absence of the hook is not evidence either way.

### Search record

Searched this run: `docs/vets/*.md`, `memory/-home-user-hov-stack/*.md`, `~/.claude/projects/*/memory/*.md`, `harness/*.md`, `HARNESS.md`, `CONCEPTS.md` (oxlint, anti-slop, antislop, oxlint-plugin, typesafe, jev, lean, lean4, formal verif, tla+, biome, react.doctor, shadcn/lint). GitHub: `dmmulroy/anti-slop` commits and contributors, `wobsoriano/oxlint-plugin-jev`, `anthropics/claude-agent-sdk-{typescript,python}` PR search, `bcherny` public PRs since 2026-08-15. Registry: `oxlint`, `@oxlint/plugins`, `@oxlint/migrate`, `oxlint-plugin-jev`. Docs: oxc.rs js-plugins, writing-js-plugins, type-aware, versioning, linter pages; code.claude.com hooks; learn.chatgpt.com hooks; typesafe.ai and docs.typesafe.ai.

## 7. Disposition and closeout

### Initial vet handoff — 2026-10-02

The following records what the vet itself shipped, before the approved implementation work.

- This note: PR from branch `harness-vet-oxlint-lean` (tracking issue #1513); closes #895 (the 2026-09-02 anti-slop trial proposal) on merge.
- Memory pointer: `~/.claude/projects/-home-user-hov-stack/memory/oxlint-anti-slop-lean-harness-vet-2026-10.md` plus an index line in `MEMORY.md` (live memory; the repo mirror syncs on its own schedule).
- Filed, not built: dotfiles#1514 (loop-guard fail-open before the fence, with the probe table as acceptance criteria), dotfiles#1515 (verify-on-stop and handback share one `stop_hook_active` budget), dotfiles#1516 (proposals A-D above, each needing an operator go).
- Papercuts logged: oxlint's "Failed to parse oxlint configuration file" on an unknown rule name; `oxlint --rules` empty without a TTY.
- Nothing installed, enabled, or changed in any target repo, in `~/.claude`, or in `~/.codex`. Scratch under `/tmp/hv-oxlint-lean-20261002/` (toolchain, target copies, Lean sandbox, logs, probe script) is disposable; the probe script is worth copying into `hooks/tests/` when #1514 is picked up.

### Approved rollout closeout — 2026-10-03

The vet merged in dotfiles PR #1517; tracking issues #1513, #1514 and #1515 are closed. Subsequent implementation used existing repository linters, not the rejected candidate toolchains.

| Slice | Merged change | Delivered boundary |
|---|---|---|
| Loop-guard accounting and persistence | dotfiles #1520, head `93420f93` | Fail-closed corrupt/unwritable state, strict accounted updates, bounded consecutive fenced denials, and clock sampling inside the lock. |
| Initial-Stop verify/handback composition | dotfiles #1521, head `26d731c9` | Both gates contribute initial feedback; the active-retry escape remains. Head/tail output clipping replaces tail-only clipping. No persistent retry-eligibility state was added. |
| Repository lint at Stop | a members-app change, head `ef1c41c`; [oracle #10](https://github.com/StartupBros/oracle/pull/10), head `c5c66a6` | Existing repository commands now include lint. The members app uses changed-file lint with shared-input fallbacks, not the original one-line full-lint sketch. |
| Cause preservation with privacy boundaries | a members-app change, head `8c2f1068`; [better-ccflare #412](https://github.com/StartupBros/hov-router/pull/412), head `b5385a72`; [oracle #11](https://github.com/StartupBros/oracle/pull/11), head `f53fa93` | ESLint, Biome and oxlint respectively enforce their native cause-preservation rules. Deliberately opaque credential/error translations retain tested redaction boundaries. |
| Requirements and implementation plan | dotfiles #1522, head `e006dfd8` | The unified plan is complete as a handoff, not as implementation or activation of feedback. |

**Verification and activation:** All implementation worktrees completed `wt-done` closeout. Dotfiles activation reported `live` at `3666ddd` with `dotup result=ok`; a rerun against the activated hook source passed 213 tests with zero failures or skips. The other repositories reported `activation: n/a`, which is not application deployment. The members app CI run 37090888995 passed all 14 jobs. Its TypeScript job ran all 26 Stop regressions with zero failures or skips and executed the custom ESLint plugin build. That CI checkout was synthetic merge `4185953d3925b1f4e8c33cd2c9fa21005b0f1d6e`, containing PR head `ef1c41ccd3ba7396e5192c05e53badd7d0d8e61b`; it was not the final squash commit `35f1ed3c1257a735e926b87d4b680a2974652b02`.

**Limits retained:** Cold members app typechecking alone exceeded the existing 180-second Stop budget; the rollout does not guarantee timely completion for every workload or enlarge that budget. The operator enabled auto-merge on a members-app change after Pro stopped with 0 P0 and 1 disputed P1 about lockfile-only selection. A members-app issue closed the shipping decision, not the technical dispute. No extra review round or governor override was performed, and the recorded Pro verdict remains `FIX-FIRST`.

**Remaining scope:** dotfiles #1516 remains open. The [unified plan](../plans/2026-10-02-1851-feat-deterministic-validation-feedback-plan.md) owns U1–U7: actual-client probes, a bounded runner, an enrolled Claude/better-ccflare pilot, completion integration, separately proven Codex WSL/native adapters, and ordinary-session evaluation. None of those units is claimed implemented by these prerequisite changes. No anti-slop, jev, Lean toolchain, replacement ESLint policy, or global feedback hook was enabled. The shipped phase is closed out; the remaining feature requires separate implementation authorization.
