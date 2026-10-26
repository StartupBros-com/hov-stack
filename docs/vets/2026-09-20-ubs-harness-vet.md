# Ultimate Bug Scanner (`ubs`) — harness vet, 2026-09-20

**FINAL VERDICT: REMOVED, 2026-09-21.** Not adopted, not forked, not gated, not kept dormant.
See §26 for the disposition and the one-command reinstatement path.

*Round 1 (2026-09-20) measured the critical tier and left the licence open. Round 2
(2026-09-21, §12-17) measured the warning tier, priced a fork, and retracted two round-1
claims. The operator has since confirmed we are licensed to use it. Standing disposition:
keep the binary installed and dormant, skill corrected by overlay, nothing gated on it,
defects routed upstream (#134, #135) rather than forked.*

This is a re-vet of an **incumbent** — `ubs` was installed 2026-07-30 and has been
auto-updating daily since, without ever having been run on our code. The default
harness-vet prior (SKIP) applies to *deepening* the integration, not to the existing
install.

## 1. Source, target, run choices

- **Candidate**: `Dicklesworthstone/ultimate_bug_scanner`, CLI `ubs`. Installed binary
  **v5.4.9** at `/home/user/.local/bin/ubs`, 393,545 bytes, written 2026-09-19 03:52 EDT.
  Upstream latest tag at vet time: **v5.4.9** (2026-09-19T03:37:21Z). Repo HEAD had already
  moved past it (`ab5d3b47`, 2026-09-20T21:06Z).
- **Prompted by**: <https://x.com/doodlestein/status/2101194677802152084>. **That post is
  not about `ubs`** — it is about ~40,000 tests passing. `ubs` appears only in a reply
  further down the thread (2026-09-19T21:51:17Z), where the author tells @loadingalias
  "I have a super linter that I use for everything" and links the repo. In the author's own
  stated workflow the scanner sits *alongside* a very large test suite; the thread's thesis
  is that the tests are what give him confidence.
- **Targets**: global harness `~/.claude` (the installed binary + the `ubs` skill), and our
  real codebases under `~/SITES/` as measurement fixtures.
- **Landing depth**: PR-for-review. Nothing installed, removed, or rewired by this vet.
- **Prior verdict**: none. One adjacent memory note,
  `doodlestein-tool-autoupdate-posture-2026-08`, which **this vet supersedes in part** — see
  §6.

## 2. Ground truth: we do not actually use this

The operator's recollection was that we "use it in our projects." We do not. Three
independent lines of evidence:

| Evidence | Result |
|---|---|
| `ubs` as an executed command across all session transcripts | 0 real invocations (only skill-management loops and this vet) |
| Language-module cache mtimes (`~/.local/share/ubs/modules/`) | all 10 still frozen at the 2026-07-30 install date until this vet touched them |
| CI / pre-commit / `CLAUDE.md` / `AGENTS.md` wiring across `~/SITES` | none in any repo we own |

The only `AGENTS.md` hits are inside `~/SITES/coding_agent_session_search` and
`~/SITES/frankensqlite` — both clones of Dicklesworthstone's *own* repos. That is upstream's
wiring, not ours.

What *is* live: `tools-auto-update.timer` (daily ~03:46) promoted `ubs` 5.4.6 → 5.4.9 on
2026-09-19, checksum-verified, backup at `~/.local/lib/tool-backups/ubs-5.4.6`.

## 3. Measured, not inferred

Two independent measurements, on two languages, two codebases, by two different agents.
Second measurement reproduced exactly on re-run by an adversarial verifier.

### Python — `~/dotfiles/scripts`, 80 files

`ubs --format=json --ci --only=python` → **48 critical / 239 warning / 1,904 info.**

Critical tier: `python.lifecycle.file_handle` 35, `python.ctcompare.secret_eq` 5,
`python.taint.command` 5, `py.security.command-injection` 2, `py.security.hardcoded-secrets` 1.

Spot-checks (source read at the flagged line):

- `pro-lane-report.py:614`, `papercut-vendor.py:648`, `tokscale-timeout-alert.py:67` — all
  flagged as command injection / taint. All three are **list-form `subprocess.run` with no
  `shell=True` and hardcoded argv** (`[sys.executable, "-m", "py_compile", str(out)]`).
  False positives.
- `memory-mine.py:638` "hardcoded secret" is the literal string
  `"credential-looking content": "credential_looking_content"` — a detector's own label.
  False positive.
- `memory-audit.py:466/925` "secret compared with `!=`" is `digest(a) != digest(b)`, a
  content-drift check with no attacker and no authentication. False positive.
- The 35 `file_handle` hits (`open(p).read()` without a context manager) are a real style
  issue but are not *critical*.

### TypeScript — `~/SITES/better-ccflare/packages/proxy`, 266 files

`ubs --format=json --ci --only=js --exclude node_modules` → **749 critical / 628 warning /
13,068 info** in 40s wall-clock. Re-run independently by a second agent: byte-identical
counts.

Entire critical tier is 4 rules: `js.security.hardcoded-secrets` **476**,
`javascript.ctcompare.unsafe_secret_compare` **182**, `js.type-coercion.loose-equality` **60**,
`js.security.prototype-pollution` **31**.

**12 criticals spot-checked across all 4 rules and 8 files, test and production:
0 true positives.**

- **464 of 476** hardcoded-secrets hits are inside `__tests__/*.test.ts` on placeholders like
  `api_key: "test-key"`. The tool has **zero test-fixture awareness** — that alone inflates
  the critical count ~9x on this repo.
- The 3 unique production hardcoded-secrets sites are header *names* and an error string:
  `export const INTERNAL_PROBE_SECRET_HEADER = "x-better-ccflare-internal-probe-secret"`,
  `TOKEN_REFRESH_FAILED: "Failed to refresh access token"`. The rule matches on the
  *identifier* containing SECRET/TOKEN, with no entropy or literal-shape check.
- All sampled `loose-equality` criticals are the idiomatic, ESLint-endorsed `!= null` /
  `== null` nullish check.
- `prototype-pollution`: 31/31 in test files; the sampled hit is
  `process.env[MODULE_LEVEL_CONST] = "1"` — no attacker-controlled key anywhere.
- In `guard-correlation-auth.ts` it flags line 45 `decoded.toString("base64url") !== value`
  (a canonical-encoding round-trip check) and line 96 `typeof envelope !== "string"` (a type
  guard). Neither compares a secret.

> **CORRECTION, 2026-09-21.** This section originally claimed ubs flags the `byteLength`
> pre-check of the *correct* `timingSafeEqual` verifier in that file, and called it
> "penalising hardened crypto". **That was wrong** and is retracted. `ctcompare_js.py` carries
> an explicit `safe_compare_re` exemption and a `length|byteLength|size` exemption, and the
> real verifier block at lines 117-120 produces **no finding** — verified by scanning the file
> directly. The error came from carrying a producer agent's framing forward after its own
> adversarial verifier had already corrected it. The two lines above are what is actually
> flagged; still false positives, but a narrower claim. See §12 for the real root cause.

**Conclusion.** The critical tier is syntactic pattern matching with no entropy check and no
test-path awareness. Observed true-positive rate on criticals across both languages: **0 of 24
sampled**. Speed and coverage are fine; precision is the problem.

> **Second correction:** "no taint analysis" (stated elsewhere in the original) is also wrong.
> `helpers/ubs_core/analyzers/taint_{py,js,go,…}.py` exist. The analysis is intra-file only,
> with regex-matched sources/sinks and a 5-iteration fixed point over single-line assignments,
> and no cross-function flow. The accurate phrase is **shallow taint**, not absent taint.

## 4. Overlap: the gap ubs would fill is ~empty

*(This dimension's first pass returned a placeholder payload — `"test claim"` /
`"test evidence"` — and was redone by hand. Noted because the schema accepted the
garbage; see §6.)*

- **27** JS/TS repos under `~/SITES` already declare `lint` and/or `typecheck` scripts
  (eslint + `tsc`).
- **7** Python repos configure `ruff` and/or `mypy` (three public tools and four other local repositories).
- 3 repos run `pre-commit`.

The languages `ubs` uniquely covers — C/C++, Rust, Go, Java, Ruby, Swift, C#, Elixir,
Kotlin — are ones we barely write. The languages we *do* write are already covered by
tooling that is far better calibrated: `tsc` proves type errors, `ruff`/`mypy` are precise,
eslint is configurable per-rule. Meanwhile the existing review ladder
(`/review` → `/ce-code-review` → `/codex:adversarial-review` → `/pro-gate`) is *semantic*
LLM review, which catches the class of defect pattern-matching structurally cannot.

Residual gap `ubs` would close for us: **essentially none.**

## 5. Licence — the one item that needs the operator

`gh api .../license` reports `NOASSERTION` because the LICENSE is **not** stock MIT. It is
titled *"MIT License (with OpenAI/Anthropic Rider)"*, © 2026 Jeffrey Emanuel. Verified by
reading the raw file directly (3,939 bytes), not via summary:

> "Restricted Parties" means OpenAI, L.L.C.; Anthropic, PBC; any of their respective
> Affiliates; and any person or entity acting directly or indirectly on behalf of, for the
> benefit of, or under the direction of any of the foregoing (including any officer,
> director, employee, contractor, agent, consultant, service provider, or representative).
>
> Notwithstanding any other provision of this License, no rights are granted to any
> Restricted Party. […] For purposes of this rider, "use" includes, without limitation:
> copying, modifying, […] deploying, executing, benchmarking, testing, analyzing, indexing,
> or incorporating the Software or any Derivative Works into any dataset, training corpus,
> evaluation harness, or pipeline for machine learning or other automated systems.

Breach "automatically and immediately terminates" the licence, with injunctive-relief and
attorneys'-fees clauses.

**Calibrated reading (not legal advice).** One vet agent concluded this "plainly covers"
Claude Code running `ubs`, including the vet session itself. **That is an overread.** The
rider restricts *parties*, not *tools*. Will is an Anthropic **customer**; a customer is not
normally "acting on behalf of, for the benefit of, or under the direction of" the vendor,
and is not an officer/contractor/agent/representative. On the natural reading he is **not a
Restricted Party**, and ordinary local use falls under plain MIT terms.

What is true regardless of that reading:

1. It is **not an OSI-approved open-source licence.** Any process that assumes "MIT" is wrong.
2. **Do not vendor, fork, or redistribute it**, and do not ship it inside anything
   customer-facing (HoV marketplace, prbot, the members app) without a deliberate look — any
   redistribution must carry the rider unmodified.
3. The author has taken an explicitly adversarial posture toward AI-lab-adjacent use. That
   is a maintainer-posture signal worth weighing for a binary we **auto-update daily** from
   his release feed.

This is the operator's call, not the agent's. The rest of this vet stands either way.

## 6. Upstream health and supply chain

- **Velocity**: 196 lifetime releases since repo creation 2025-11-16; **17 releases and 353
  commits in 90 days**; 5 releases in the 2 days 2026-09-17→09-19. HEAD moves daily.
- **Bus factor 1.** Contributors: `Dicklesworthstone` 1,207, `github-actions[bot]` 7. The
  three human author-name variants resolve to one account. `branches/main/protection` → 404:
  **no required reviews, no required status checks** before pushing to main.
- **CI is genuinely thorough** — 444-line `ci.yml` with a self-scan gate, a 447-case sharded
  manifest suite, shellcheck, and macOS/Windows/Docker smoke — **but it does not gate
  releases.** `release.yml` fires independently `on: push: tags: [v*]` with no `needs:`, and
  `cut-release.sh` re-runs only the local self-scan. A tag can ship without the full suite
  green.
- **Release signing is strong by design**: minisign, cosign keyless bound to the Actions OIDC
  identity, SLSA provenance, SPDX SBOM. `install.sh` does call its own verify functions (the
  dead-code defect recorded in our 2026-08 note has been fixed upstream, ref their issue #87).
- **But our updater does not use any of it.** `scripts/tool-update.sh` does
  `gh release download --pattern ubs --pattern SHA256SUMS` and compares sha256 between two
  assets **from the same release** — no minisign, no cosign, anywhere. Same-source checksum
  only. That is weaker than what upstream ships and is worth knowing, though the residual
  threat (GitHub release-asset tampering) is narrower than a CDN/MITM substitution.
- **Open-issue backlog is small and healthy**: 4 open, all <11 days; 92 closed. Issues are
  concrete defects from real external reporters, closed in hours-to-days.

## 7. The installed skill is actively wrong

`~/.claude/skills/ubs/` (2026-07-30, `user-invocable-only`, 6KB SKILL.md + 21KB references).
**Backed up correctly** — `jsm verify ubs` → `✓ ubs [6074651a7f2c]`, matching published v2,
no local edit drift. (An earlier suspicion of unbacked local state was a false alarm:
`sync.sh` delegates skill backup to `jsm`.)

The problem is content drift against the v5.4.9 CLI, confirmed by execution:

1. **`--category=security` is a silent no-op.** `--category=security`,
   `--category=js.security` and `--category=nonexistentzzz` all produce byte-identical
   output; the CLI prints `⚠ Unknown category filter` to stderr and runs an **unfiltered**
   scan, exit 0. The skill documents this as its flagship "Security Audit" workflow. A CI job
   built on it would believe it ran a scoped security scan.
2. **`--only=ts,tsx` is backwards.** `--only=js` already scans `.ts`. `--only=tsx` is not a
   recognised value — it yields `no supported languages detected` and **exit 3**. The skill
   annotates its example with "(`--only=js` excludes TS!)", which is false. A TS/TSX gate
   built from this scans zero files.
3. **The entire numbered category taxonomy is fabricated.** SKILL.md/TRIAGE.md map 3→Async,
   4→Resource, 8→Error handling. Real js numbering: 5→Async, 19→Resource, 6→Error handling,
   7→Security. Every `--skip=N` example silences the wrong rules.

Also note `--skip=N` is language-unstable by upstream's own design (their issue #52) —
`--skip-LANG=CSV` is the correct form in polyglot repos.

## 8. Operational notes

- **`ubs doctor` exits 2 today** (checksum mismatches on every language module never yet
  scanned). This is **not** a correctness risk: a stale module never silently runs, it either
  self-heals over the network on first real use or fails loud. Verified live — scanning
  `--only=js` and `--only=rust` healed exactly those two and left the other seven red.
  It *is* a latency/availability risk for any network-restricted CI use.
- **`tool-update.sh` updates the binary and never the module cache** (the `ubs` row is a
  single-asset pipeline; the smoke check only confirms `ubs --version` runs). So binary/module
  skew is real after every auto-update, papered over by lazy self-heal.
- **`install.sh --easy-mode` is better engineered than feared** — it explicitly refuses to
  modify user-level `~/.claude/settings.json`, writes atomically with timestamped backups, and
  detects our existing DCG guard registration. It *does* unconditionally add a blocking
  PostToolUse scan hook to whatever **project** it is run against. Assessed by reading source;
  deliberately not executed non-dry-run.

## 9. Verdicts

| Option | Verdict | Why |
|---|---|---|
| (a) Leave as user-invocable skill, binary auto-updating | **ADOPT** | Zero ongoing cost, zero operational risk, keeps optionality for the polyglot case |
| (a′) Fix the skill's three drift defects, or delete the skill | **ADOPT — do this either way** | It currently mis-teaches every session that reads it |
| (b) Add module refresh to `tool-update.sh` | **DEFER** | One-line, cheap, strictly beneficial — but pointless if the licence call removes the tool |
| (c) Promote skill to always-on | **SKIP** | Inverts our own 2026-07 demotion policy, for a tool with 0 measured true positives and 0 usage |
| (d) Pre-commit or CI gate in any repo | **REJECT** | 749 criticals / 0 TP on 266 TS files. This gate blocks on noise and would be switched off within a day |
| (e) Wire into the review ladder as a cheap pre-pass | **REJECT** | Every tier of the ladder would spend its budget triaging false positives ahead of real review |

**Re-evaluation triggers**: (1) we take on a real C/C++/Rust/Go/Swift codebase — that is the
only scenario where the coverage breadth earns anything; (2) upstream ships test-path
awareness and data-flow/taint analysis for the security rules; (3) the licence rider changes.

## 10. Corrections this vet makes to existing records

- **`doodlestein-tool-autoupdate-posture-2026-08` is stale.** It states nothing installs a new
  binary for these tools without the operator typing a command. `tools-auto-update.service`
  has shipped since and does exactly that, daily, checksum-verified. It promoted `ubs`
  5.4.6→5.4.9 on 2026-09-19.
- The same note's claim that ubs's `fetch_checksum_bundle`/`verify_download_checksum` are
  **dead code** no longer holds at upstream HEAD — `install.sh` calls both on the default
  path. (Our updater still does not use them, which is a separate point — §6.)

## 11. Method note — a workflow failure worth recording

The 4-dimension vet workflow ran 8 agents / 660k tokens / 0 errors. One agent (overlap)
returned `"test summary sentence." / "test claim" / "test evidence"` — a placeholder payload
that **satisfied the JSON schema and was reported as success**. Its adversarial verifier
correctly refused it (`refuted=true`) only because the fallback instruction said to refute
what it could not reproduce.

Lesson: a schema validates *shape*, not *work*. Pair every producer with a verifier that
re-derives from primary sources, and read the returned content before trusting an
`agents_error: 0` count. Related: `low-finding-count-hides-a-blind-tool`,
`verify-subagent-counts-before-classification`.

---

# Round 2 — 2026-09-21: use it at all, or fork it?

The operator settled the licence question (we are licensed) and asked the sharper pair:
**should we use it, and do we need to fork it?** Answer: **no to both.** Keep it installed
and dormant; fix the skill; file upstream instead of forking.

## 12. The warning tier — the gap round 1 left

Round 1 measured only criticals, so "do not gate" was safe but "do not use at all" was not
yet earned. Measured now, same two targets:

| Tier | Sampled | True positives |
|---|---|---|
| Critical | 24 | **0** |
| Warning | 24 | **2 (8%)** |

Both warning-tier true positives are minor robustness nits, not defects: an uncaught
`JSON.parse` in a WAL load path (`pending-rotation-wal.ts:115`, whose caller loops over all
WAL files with no try/catch, so one corrupt record aborts loading every account's state), and
a `subprocess.run` with no `timeout=` in a vendoring build script. Notably, neither is caught
by ruff/eslint defaults — so there is a sliver of unique signal, at roughly 1-in-12 odds.

The false positives share one root cause: **no scope tracing.**

| Shape | Why ubs is wrong |
|---|---|
| `os.open()` inside `try:` with `finally: os.close(fd)` | No exception-scope tracing |
| `a / b` with an inline `if b else 0` guard | No guard-expression tracing |
| `switch` whose every `case` ends in `return` | Reported as fallthrough |
| `new Uint8Array(0)` | Reported as "sparse array creation" |
| `type(x) is not int` (deliberate, to exclude `bool`) | "Fix" per the rule would introduce a bug |

The info tier (13,068 TS / 1,913 py) is 63% two idiomatic TS rules; a Python `unreachable-code`
rule accounting for 35% of that tier appears to be an outright tool bug, firing on ordinary
`return None` guard clauses.

## 13. Configuration can cut volume, but cannot reach the worst rule

Measured on the same 266-file TS target:

| Configuration | Criticals |
|---|---|
| Baseline | 749 |
| `--exclude='node_modules,__tests__'` | **116** |
| …plus `--skip='js.security,js.type-coercion,js.proto-object'` | **59** |

All 59 survivors are one rule, `javascript.ctcompare.unsafe_secret_compare` — and it
**cannot be turned off**.

**Reproducible upstream bug.** `--skip=js.security` suppresses `js.security.hardcoded-secrets`
and `js.security.jwt`, but not `javascript.ctcompare.unsafe_secret_compare`, *even though that
rule reports `category_id: js.security`*. No warning is printed. `ctcompare_js.py`'s `run()`
emits `"rule": f"javascript.ctcompare.{_KIND}"`, so the filter — which matches the rule-id
prefix `js.` rather than the resolved `category_id` — never sees it. Every `javascript.*` rule
is unskippable. Repro: `scripts/../../.claude/jobs/*/tmp/skip-repro.sh` (2-line fixture).

**Root cause of the type-guard false positives — operand pairing across `||`.**
`clean_operand_text()` truncates each operand at the first boolean connective and keeps `[0]`.
For `if (!isValidSecret(secret) || typeof envelope !== "string")`, `compare_re` matches on the
`!==`, making `left` everything before it; the split then keeps `!isValidSecret(secret)` — a
term from the *other* side of the `||`. That substitute carries the token `secret`, so the
comparison fires. Taking `[0]` is correct only when the connective *follows* the comparison.

Both filed upstream: **#134** (skip) and **#135** (operand pairing), each with a minimal repro.

## 14. Fork cost — lopsided against forking

- The directory a fork would patch, `modules/helpers/ubs_core`, is **335 files / 84,087 lines**
  — 74% of the repo's Python, ~10x the meta-runner (8,376 lines).
- **+8,401 net new lines in 34 days** in that same directory, almost entirely new detector
  files: an active language-porting campaign, not stabilisation.
- 358 commits in 12 weeks, **85% of them in the final 3 weeks**; 26% touch `ubs_core`.
  `sql_injection.py` was patched twice in 24 hours.
- Bus factor 1. A fork means owning 84k lines of someone else's detector engine.

Crucially the split does not favour forking: **everything configuration can fix does not need
a fork**, and the one thing a fork would need to fix — real interprocedural taint — is a
rewrite, not a patch.

**The custom-rule case is already served.** `ast-grep scan` natively supports `--rule`,
`--inline-rules`, `sgconfig.yml` projects and SARIF output. ubs is *itself* built on ast-grep,
which we already install (0.42.1), already prefer per CLAUDE.md, and already hold rule assets
for. Forking a wrapper to reach a tool we use directly is backwards.

**Upstream is the cheap path.** 12 distinct false-positive issues closed since 2025-12; #94
closed same-day; #133 closed **47 minutes** after an external report. Two good issues cost ~20
minutes against owning a fork indefinitely.

**Licence, narrowly.** A private, never-published fork does not engage the rider. A *public*
fork plausibly does — public visibility is itself "making available… to or for any Restricted
Party". Not legal advice.

## 15. Portfolio — "we use many of his repos" is true for 2 of 7

| Tool | Invocations / sessions | Wiring |
|---|---|---|
| `cass` | 623 / 41 | 3 systemd services, own skill family |
| `dcg` | 320 / 52 | PreToolUse hook on **every** Bash call, fleet-wide |
| `csctf` | 30 / 8 | none |
| `ru` | 9 / 3 | none |
| `xf` | 5 / 2 | in weekly smoke test |
| `ubs` | 0 organic | none |
| `tru` | 0 direct | transitive only — ubs's toon encoder |

Only dcg, cass and xf appear in `tool-smoke.sh`. So ubs is not an outlier from a strong
portfolio — it is the clearest case of the idle majority, and the portfolio argument for
keeping it is weaker than it looks.

## 16. Alternatives — nothing worth buying

- **Semgrep CE** (free OSS): intraprocedural only. Cross-file taint is Semgrep Code/Pro,
  behind a platform account. The free hosted tier caps at **10 repos / 10 contributors**; we
  have ~34 JS/TS + Python repos.
- **CodeQL**: free for public repos only; ours are private.
- **Incumbents**: eslint + tsc (27 repos), ruff + mypy (7 repos), plus the LLM review ladder.

Recommendation: leave the slot empty. The incumbents plus semantic LLM review are the right
stack for a shop that writes ~only TypeScript and Python.

## 17. Round-2 actions taken

1. Upstream issues **#134** and **#135** filed with minimal repros.
2. Skill corrected via tracked overlay at `skills-patches/ubs/SKILL.md` (whole-file
   fork; re-check on each `jsm update` and drop the overlay once upstream matches).
3. Two claims from round 1 retracted in place — the `timingSafeEqual` framing (§3) and
   "no taint analysis". Both were producer-agent framing that survived past a verifier's
   correction.

---

# Round 3 — 2026-09-21: simulating upstream's actual gate on our PRs

Rounds 1-2 measured whole-repo scans. That was a strawman: upstream does **not** scan whole
repos. §12-17 established his real pattern — changed files only, compared head-vs-base, failing
only when counts increase. This round simulates **that** gate on our own merged PRs.

Prompted by the operator's observation that we have an ARC fleet plus Blacksmith, so the cost
objection to a CI gate does not apply to us. Correct — and it is not the reason the gate fails.

## 18. Method

For each recently-merged PR: `base = <mergeCommit>^1`; changed files via
`git diff --name-only --diff-filter=ACMR base sha`, filtered to
`.ts/.tsx/.js/.jsx/.py/.rs/.go/.sh` and excluding `node_modules`, `dist`, `build`, `.next`,
capped at 25 files; head and base versions of exactly those files materialised into separate
scratch trees with `git show`; each tree scanned with `ubs --format=json --ci`; gate fails iff
the head count exceeds the base count. Two gate settings and two file filters were measured.

Scripts preserved under the job scratch dir (`gate-multi.sh`, `gate-notests.sh`,
`arena555b.sh`); re-run before citing, the numbers decay.

## 19. Results — 53 PR-evaluations, 7 repos, TS and Python

**Config A — test files included** (25 PRs across the members app, a private research repository, a private repository,
oracle, another private project, a private evals repository):

| Gate setting | Pass | Block |
|---|---|---|
| Criticals only | **24** | 1 |
| Criticals + warnings | 15 | **10 (40%)** |

**Config B — test files excluded** (28 PRs, same repos plus better-ccflare):

| Gate setting | Pass | Block |
|---|---|---|
| Criticals only | **27** | 1 |
| Criticals + warnings | 21 | 7 |

**Config C — independent re-derivation.** An adversarial verifier re-ran the Config-A method
from scratch on oracle, another private project and the members app, sampling **10** merged PRs per repo instead
of 5: **18 evaluable PRs, 2 blocks (11%)**.

> **CORRECTION — the block rate above is understated.** Configs A and B capped at 5 PRs per
> repo, which biased the sample toward the most recent PRs. The deeper 10-per-repo sample found
> **2 blocks in 18 (11%)**, roughly 2.8x the 1-in-25 (4%) the capped runs implied. Cite ~1 block
> in 9-14, not 1 in 25. The two extra blocks were oracle #1 (critical 11 → 16) and the members app's
> #3532 (0 → 1).

**Every block across all three runs is a false positive. Zero true positives in any run.**
The two additional blocks found by the deeper sample are *also* `js.type-coercion.loose-equality`
— five new `==`/`!=` hits in oracle's `thinkingStatus.ts`, and one `== null` inside the members app's
`card-backfill.test.ts`. That single rule accounts for every criticals-tier block observed.

### The two blocks

**Config A — a private repository's #555, +5 criticals.** Every new finding is in the repository's test directory:

```
py.security.archive-extraction  archive fixture             z.extractall(isolated)
py.security.command-injection   three launcher-fixture lines
py.security.hardcoded-secrets   credential fixture          env["EXAMPLE_API_KEY"] = "test-only-fake-key"
python.ctcompare.secret_eq      mode-selection fixture      if credentials == "api_key":
```

A literal `"test-only-fake-key"` reported as a hardcoded secret, and `credentials == "api_key"`
— a mode label, not a secret. With tests excluded this PR's criticals *drop* 3 → 2 and it
passes, confirming the block was entirely test noise.

**Config B — better-ccflare #350, +1 critical.** `RequestCostBadge.tsx:23`,
`const unknown = summary?.costUsd == null;` — the ESLint-endorsed nullish idiom, rated
**critical**. Third independent appearance of this false-positive class in this vet.

## 20. The finding that settles the gate question

An earlier draft of this section asserted that excluding test files would make the gate
**never fire** (25/25 pass). **That was an inference, and measuring it proved it wrong** —
it still fires once in 28. Recording the correction because the inference was the kind that
reads as a measurement.

What the measurement actually shows is sharper:

> Tuned loose (criticals + warnings) the gate blocks 28-40% of PRs. Tuned tight (criticals
> only) it blocks roughly **1 in 9-14** — and **every one of those is still wrong**. There is
> no setting at which the gate both fires and is right.

Every criticals-tier block observed across all three runs traces to a single rule,
`js.type-coercion.loose-equality`, firing on the ESLint-endorsed `== null` / `!= null` nullish
idiom. Disable that one rule and the gate goes almost completely silent; leave it on and the
gate is wrong every time it speaks.

Supporting detail: test files are 4-12 of the changed files in most of these PRs and dominate
the finding counts. `--exclude __tests__` does **not** catch our co-located `.test.ts` /
`.test.tsx` / `.spec.ts` files, so the no-test-awareness defect is materially worse for our
layout than the `__tests__` figure in §3 implied. Two repos (another private project, a private evals repository) produced
essentially no findings at all across their sampled PRs.

## 21. Two things ubs could not see — both found by verifying, not by scanning

**(a) A silently unscanned directory.** ubs's default scan of a private repository's #555 ran only the
python module. The repository's `bin/*.sh` — including **three new production launcher scripts** added
by that PR (`recover.sh`, `start-collector.sh`, `start-owner.sh`) — was never scanned at all.
Cause: ubs's build-output heuristic drops any directory literally named `bin` when no file in it
carries an extension in its hardcoded `SOURCE_EXTENSIONS` list, and **`.sh` is not in that
list**. Forcing an explicit bash-module scan of those five files found 0 critical / 4 warnings,
so the verdict is unchanged — but the coverage gap is silent, undocumented, and means "no new
critical in production code" holds only for the languages ubs chose to scan. Any repo with a
`bin/` directory of shell scripts is invisible to a default `ubs .`.

**(b) A deleted lint suppression ubs's ratchet cannot see.** An earlier draft of this section
claimed the `shell=True` finding in one production module was pre-existing and that
a private repository's #555 "merely shifted it down six lines". **Both halves were wrong.** Verified against the real
commits: the PR restructured the surrounding function (widened the callback return type, added
retry-on-failure, wrapped the caller in try/except) *and* **deleted the `# noqa: S602`** that
suppressed the finding. Base line 106 carries the comment; head line 112 does not:

```diff
-  proc = subprocess.run(args.on_new_cmd, shell=True, env=env, check=False, timeout=900)  # noqa: S602
+  proc = subprocess.run(args.on_new_cmd, shell=True, env=env, check=False, timeout=900)
```

So the only genuinely interesting change in that PR is a silently dropped suppression on a
`shell=True` line — and **ubs's ratchet is structurally blind to it**, because ubs does not
honour `# noqa` and therefore flagged the line identically at base and at head. Its count did
not move, so the gate stayed green on the one change a reviewer would have wanted to see. (The
underlying call is low severity — `args.on_new_cmd` is argparse-supplied, i.e. operator-chosen —
but the disappearing suppression is exactly the kind of thing a diff gate exists to catch.)

**Method lesson:** a sample-level diff keyed on `rule|path|line` reports a line-number shift as
a newly-introduced defect. Gate logic must compare **counts** (as upstream's does) or
content-addressed findings, never `path:line` tuples.

## 22. Revised recommendation

- **Blocking CI gate: REJECT**, unchanged, now on 53 PR-evaluations across 7 repos and both
  languages rather than on a whole-repo scan. The reason is no longer cost — our fleet makes
  running it free — it is that no threshold both fires and is right.
- **Advisory (non-blocking) run: WEAKER THAN §9 SUGGESTED.** Round 2 argued for it on the basis
  that false positives cost nothing when nothing blocks. True, but this round measures the
  other half: across 53 PR-evaluations it would have surfaced **nothing real**. The 2-in-24
  warning-tier true positives in §12 came from deep-sampling a whole-repo scan, not from PR
  deltas. If run at all, run it advisory, expect no catches, and never read its silence as a
  safety signal.
- Option (b) from §9 (module refresh in `tool-update.sh`) is unaffected.

## 23. Method integrity — all three round-3 claims were refuted before publication

Before this section was committed, its three load-bearing claims were handed to independent
adversarial verifiers instructed to re-derive from primary sources and default to `refuted`.
**All three came back corrected:**

| Claim as drafted | Verdict | Correction |
|---|---|---|
| criticals-only gate blocks 1 in 25 | **refuted** | 2 in 18 (11%); the 5-PR-per-repo cap biased the sample toward recent PRs |
| the one block is entirely test-file noise | confirmed | …but ubs silently skipped the repository's `bin/*.sh`, so "no new critical in production code" covers only the languages it scanned |
| the `shell=True` finding is pre-existing, merely line-shifted | **refuted** | the PR also deleted its `# noqa: S602`; it did not merely shift |

Separately, a fourth claim — "exclude test files and the gate never fires" — was an *inference*
in an earlier draft. Measuring it refuted that too: it still fires once in 28.

Four claims, four corrections, none of which changed the verdict but all of which changed what
the record says. Two of the four (the `1 in 25` rate and the `merely shifted` framing) would
have read as measurements to any later reader. This is the third time in this vet that a claim
survived past a verifier's correction and had to be retracted later (see §3 and §17) — the
difference here is that the verification ran *before* publication rather than after.

**Standing rule this vet now demonstrates three times over:** a number produced by a capped or
convenience sample is not a rate, and a `path:line` comparison is not a defect diff. Verify
before the claim becomes permanent, not after.

---

# Round 4 — 2026-09-21: the two salvage hypotheses, and the disposition

The operator asked the two fair questions left: **use it selectively for whichever language a
repo is written in**, and/or **extend it into the languages we actually use**. Both were tested.
Both fail. The tool is removed.

## 24. Selective per-language use — no language wins

Bash was the strongest candidate: it produced the only genuine critical seen in the whole vet
(the dynamic-execution finding in §21a), and we write a lot of it — 288 `.sh` files in dotfiles
alone. It does not survive measurement.

**shellcheck is already the incumbent** — wired into `harness-tests.yml` and
`install-smoke.yml` here, plus the author's infrastructure repository, hov-marketplace and hermes-agent, installed
via mise 0.11.0.

Head-to-head on 40 real scripts from `scripts/`:

| | findings |
|---|---|
| shellcheck | **72** |
| ubs (`--only=bash`), warning-or-above | **9** |

And ubs's bash output is substantially **shellcheck, relabelled** — `bash.shellcheck.SC2088`,
`SC2010`, `SC1090`, `SC2045` are literally shellcheck codes re-emitted under ubs rule ids, on
the same lines shellcheck reports directly.

Its three *original* (non-shellcheck) bash findings, read at source:

| Finding | Verdict |
|---|---|
| `bash.robustness.cd_without_exit` — `cd "$WORKDIR"` in `backup-supabase.sh:51` | **False.** `set -euo pipefail` is active at line 21, so a failed `cd` already aborts. ubs does not track `set -e`. |
| `bash.syntax.test_compound_operator` — `harness-weekly.sh:898` | **False.** The code is `[ -f X ] && [ Y ]` — two separate tests joined *outside* the brackets, which is the correct form. The anti-pattern is `&&` *inside* single brackets. |
| `bash.security.eval-variable` — `pro-lane-health.sh:85` | Arguable. A real indirect-expansion construct; bash's `${!name}` is safer. Not a vulnerability here (names are script literals). |

**0 clear true positives, 1 arguable, 2 false** — behind a wrapper around a tool we already run.

Summary across every language we actually write:

| Language | ubs result | Incumbent already in CI |
|---|---|---|
| TypeScript | 0/24 criticals true | eslint + tsc (27 repos) |
| Python | 0 sampled true | ruff + mypy (7 repos) |
| Bash | largely a shellcheck wrapper; 0/3 original clear | shellcheck (mise 0.11.0) |
| Rust / Go / C++ / Java / Swift / C# / Elixir | where its breadth lives | *we do not write these* |

There is no language where selective use wins.

## 25. Extending it — possible, pointless

**Correction to §13.** An earlier claim that `--rules=DIR` "silently does nothing" was **wrong
and is retracted**. It works: a custom ast-grep rule fires correctly under `--only=js`
(`[warning] custom-no-console-log (1 found)`) and `--only=python` (2 found). Only the **bash**
module ignores it — filed upstream as #138, along with the secondary defect that a nonexistent
`--rules` directory is accepted silently.

So extension is mechanically available for TS. It is still not worth doing, because what you
would be authoring is **ast-grep rules** — and `ast-grep scan --rule` / `--inline-rules` runs
those natively today, emits SARIF, and is already installed (0.42.1) and already preferred by
CLAUDE.md. ubs is itself built on ast-grep.

Routing custom rules through ubs instead buys multi-language fan-out (we need two), HTML and
baseline reports, and the ratchet — while dragging along the rule pack that produced 749 false
criticals, which must then be suppressed category-by-category, except `--skip` cannot reach the
`javascript.*` rules at all (#134). For React specifically the harness already adopted
`eslint-plugin-react-doctor` per-app plus shadcn/lint, both purpose-built and calibrated.

## 26. Disposition: REMOVED, 2026-09-21

| Surface | Action |
|---|---|
| `ubs` skill | added to `retired-skills.txt` (so jsm cannot silently re-add it) |
| `skills-patches/ubs/` | deleted — the overlay fork created earlier today, and its standing drift obligation, are gone |
| `scripts/tool-update.sh` | `ubs` row removed from `TOOLS`; daily auto-update no longer pulls it |
| `scripts/tool-staleness.sh` | `check_tool ubs` removed |
| `settings.json` | skill-visibility entry removed |
| binary (`~/.local/bin/ubs`) | moved off the host — no longer on `PATH` |
| 8 `tool-backups/ubs-*` | moved off the host |
| skill, both trees | gone from `~/.claude/skills` and `~/.codex/skills`; reconciler reports policy in sync |
| `~/.local/share/ubs` (8 MB cache), `~/.config/ubs` (8 KB) | **still present** — see below |

**Honest note on the two leftovers.** `dcg` gates `mv` of a dotfile tree under `$HOME`
(`core.filesystem:mv-sensitive-source-root-home`), which covers `~/.local/share/ubs` and
`~/.config/ubs`. That guard is correct — the shape it blocks is the relocate-then-delete
bypass — and routing around it with a script file would be exactly the smuggling CLAUDE.md
forbids. Both directories are **inert**: nothing on the host reads them now that the binary,
the skill and the `tool-update.sh` row are gone, and no timer will repopulate them. They are
8 MB of dead cache, not a live surface, so they were judged not worth an operator
`dcg allow-once` interrupt. Clear them opportunistically with `dcg allow-once` whenever
convenient.

**Left alone — and the original reason given here was wrong.** This section first said `tru`
was "installed only as ubs's TOON encoder and now has no consumer", and flagged it as a
candidate to sweep. **That is retracted.** `tru` is the Rust TOON encoder
(`Dicklesworthstone/toon_rust`; upstream names the binary `toon`, we install it as `tru`
because `cm` rejects that name — hence `tru --version` printing `toon 0.2.4`). Its real
consumer is **`cm`**, still installed at v0.2.13: `strings` on the binary shows
`function isToonOutput(options)` / `if (format === "toon")`, and the 2026-07 memory face-off
recorded that cm's TOON path shells out to `tru`.

**Sweeping `tru` would have silently degraded cm**, not broken it — `cm doctor` never checks
for the encoder, so its absence falls back to JSON with no error. That is the same
silent-degradation class this vet spent four rounds on, and it would have been introduced by
acting on an unverified "no consumer" claim. ubs was a *secondary* consumer; removing ubs
changes nothing about tru's status. **Keep `tru` installed.**

> **Update 2026-10-01.** That consumer is gone: the operator retired `cm` after a minimal retest of
> cm 0.4.0 found no recall gain over 0.2.13 on the 2026-07 face-off suite. `tru` was then dropped
> from `tool-update.sh` and `tool-staleness.sh` and uninstalled, after a search found no other
> caller in this harness or `~/SITES` (cass compiles the toon crate in and does not need the binary).

**Other skills referencing `/ubs`** (`saas-billing-patterns-for-stripe-and-paypal`,
`documentation-website-for-software-project`, `seo-for-saas-businesses`) name it as an
*optional* helper and degrade gracefully when it is absent; they will simply skip it.

**Reinstatement**, if we ever take on a Rust/Go/C++ codebase, is the upstream one-liner
installer from `Dicklesworthstone/ultimate_bug_scanner` (`install.sh`, piped to bash). That
reinstall cost is exactly why keeping it installed carried no option value.

## 27. What this vet returned

Five upstream issues, all with minimal verified repros:

| Issue | Defect |
|---|---|
| [#134](https://github.com/Dicklesworthstone/ultimate_bug_scanner/issues/134) | `--skip=<category>` silently misses `javascript.*` rules that report that category_id |
| [#135](https://github.com/Dicklesworthstone/ultimate_bug_scanner/issues/135) | `ctcompare` pairs operands across a `\|\|`, so a `typeof` guard reads as an unsafe secret compare |
| [#136](https://github.com/Dicklesworthstone/ultimate_bug_scanner/issues/136) | a directory named `bin/` is silently pruned, hiding a real dynamic-execution critical; exit 3 reads as a pass |
| [#137](https://github.com/Dicklesworthstone/ultimate_bug_scanner/issues/137) | `loose-equality` rates the idiomatic `x == null` nullish check as critical |
| [#138](https://github.com/Dicklesworthstone/ultimate_bug_scanner/issues/138) | `--rules=DIR` ignored by the bash module; missing rules dir accepted silently |

Plus the transferable lessons, which outlast the tool: a schema validates shape and not work
(§11); a capped convenience sample is not a rate (§23); a `path:line` diff is not a defect diff
(§21); and verify *before* a claim becomes permanent, not after — this vet retracted five of its
own claims, and the ones caught pre-publication cost nothing.
