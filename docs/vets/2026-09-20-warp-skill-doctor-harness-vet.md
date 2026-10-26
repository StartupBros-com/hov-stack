# Harness vet: Warp `skill-doctor` (warpdotdev/common-skills) against skill-tuner, the HoV catalog and the global harness

- Date: 2026-09-20. Skill: harness-vet. Tracking: work-spec #1228 (shared with the `claude plugin eval` vet, PR #1229; the operator added this candidate mid-run). Landing: this note and a memory pointer. Nothing installed, enabled, or ported.
- Candidate: the `skill-doctor` skill directory in `github.com/warpdotdev/common-skills` (`.agents/skills/skill-doctor/`), main @ `69b47536` (2026-09-16, "Add compliance scorers to skill-doctor (#101)"). Repo: 585 stars, 33 forks, MIT, created 2026-04-30; the skill changed five times between 2026-08-26 and 2026-09-16. Fetched as a tarball into scratch (`/tmp/pe-vet-20260920/warp/`), no git against any checkout. 14 files, 1.33 MB: `SKILL.md` (10.4 KB), two references, four scorer rubrics, `scripts/collect_sessions.py` (62 KB), `warp_decoder.py` (12 KB), `render_report.py` (27 KB), two test files, `assets/pierre-diffs.js` (1.16 MB, minified `@pierre/diffs` bundle) and a Warp icon.
- What it does (its own words): "Grades agent skills by scoring agent conversations for efficiency, code quality, procedure compliance, and verbosity, then drafts concrete skill edits and a shareable report." The collector condenses recent local transcripts from Warp, Claude Code, Codex, Pi, Grok Build and ZCode into a scratch directory; the running agent grades each against the four rubrics; means are curved (`0.5 + 0.5 * score`) and weighted into an overall; edits to skills are drafted only from failed conversations under a written gate; a self-contained `report.html` renders the scorecard, diffs and a share-as-PNG card, and the skill instructs the agent to end every response with a link to Warp Factories' request-access page.
- Name: it is called `skill-doctor`, the same name as Claude Code's built-in `/skill-doctor` usage report (v2.1.252+), which the sibling vet in this PR exercised.
- Targets: T1 skill-tuner (a competing "grade and fix your skills" product with a different evidence standard), T2 the HoV catalog, rent-check and papercut in particular (transcript-derived verdicts on rules and friction), T3 the global harness (own skills, the Honest Work rule against self-certification, transcript privacy).
- Install state: not present in `~/.claude/skills`, `~/.agents/skills` (47 skills, `.skill-lock.json`-managed), `~/.codex/skills`, or `skills-local`; no prior note in memory, `docs/vets/`, or `harness/`. Related note reused: the built-in `/skill-doctor` result from the plugin-eval vet (229 rows, 113 never used).
- Run decisions (unattended): report-only for this candidate, sized as a single-skill vet (2 readers, 1 verifier, 1 rubric judge); all runs read-only on transcripts and confined to scratch; condensed transcripts deleted from scratch at the end of the session.

## Method and coverage

- One workflow: 2 Sonnet lean-readers at medium effort (execution surface: the three scripts read in full; doctrine: `SKILL.md`, references, scorers and the incumbents' skill files), 1 Sonnet verifier with a REFUTED default, 1 session-model rubric judge. 4 agents, 274k tokens, 65 tool calls, 8 minutes. 9 component rows, 22 claims, 22 verdicts: 22 CONFIRMED, 0 PARTIAL, 0 REFUTED. The judge's behavioural test is in "Measured, not inferred".
- Vet-author runs before the fleet: the candidate's own tests, the collector on this host's sessions, the name-collision test, and the bundled-asset checks.
- Coverage gaps recorded: the doctrine reader did not open the `loop_quality` modules beyond `validation.py`; the execution-surface reader skimmed the two test files by test name; the 25 other skills in the repository were not read (this vet covers `skill-doctor` only, so they are not triaged either).

## Measured, not inferred

### Its own tests

`uvx pytest -q test_collect_sessions.py test_render_report.py`: 26 passed in 0.13 s (the system Python has no pytest; the suite is stdlib plus pytest).

### The collector on this host (read-only, output in scratch)

`collect_sessions.py --harness claude --repo /home/user/hov-stack --days 7 --max-sessions 3 --include-global-skills`, exit 0:

| Reported | Value |
|---|---|
| skills found | 203 (37 "used" in the window), discovered across `~/.codex/skills`, `~/.agents/skills`, `~/.claude/skills` |
| sessions in window | 158 records, 68 in scope for the repo, 48 scoreable |
| sampled | 3, written as condensed Markdown transcripts of 46.8 KB, 54.6 KB and 55.1 KB (156 KB total) |

- The first sampled transcript's header says "skills detected: cass-vec, saas-billing-patterns-for-stripe-and-paypal" for a session about nightly PowerShell errors; its condensed body reproduces the full injected `workflow-authoring` skill text as a `[user]` turn. How detection and condensation work is settled by the fleet below.
- At roughly 4 bytes per token, three transcripts are about 40k tokens of grading input; the skill's default of 12 sessions is about 160k, and its instruction to "process datasets of 50 transcripts or fewer in a single batch" would exceed any current context window.

### Name collision with the built-in `/skill-doctor`

With the skill copied into a throwaway `CLAUDE_CONFIG_DIR` as `skills/skill-doctor/`, `claude -p "/skill-doctor" --tools "" --max-turns 1` (Sonnet, $0.04) answered with Warp's flow ("I'll start by checking which harness is executing this skill" and a read of `references/supported-harnesses.md`), not the built-in usage report that the same command produces with the real config. Installed under its own name, the skill shadows a built-in command.

### Bundled JavaScript

`assets/pierre-diffs.js` is one minified 1,531-line bundle identifying itself as `@pierre/diffs`; it contains no `fetch(`, `XMLHttpRequest` or `sendBeacon`, one `navigator.` reference, and no `http://` or `https://` string. `render_report.py` embeds it inline (`<script>{embedded_diffs_script()}</script>`, line 314) and the page's only outbound link is the Warp call-to-action (`cta_url`, default `https://warp.dev/factories/request-access`, line 312).

### The rubrics applied to one real session (judge agent, session model, medium effort)

The smallest sampled transcript (46.8 KB, an unattended diagnosis of nightly PowerShell errors that ended in a systemd drop-in, a `sync.sh` registration and a 14/14 test suite) was graded exactly as `SKILL.md` step 2 prescribes:

| Scorer | Label | Score | Reason (condensed) |
|---|---|---|---|
| Efficiency | mostly_inefficient | 0.4 | two guard blocks before the sanctioned command shape, then three failed decodings of `wevtutil` output before `LC_ALL=C`; a memory note and `dcg explain` would have prevented both |
| Code quality | approve | 1 | real diff, repo convention matched, two self-caught test bugs fixed and re-run before done |
| Procedure compliance | mostly_compliant | 0.8 | no protective-rule breach; docked for trial-and-error instead of the guard's own tip |
| Verbosity | proportionate | 1 | short causal handoffs, no restated summaries |

- The edit gate would not fire: the one sub-0.5 score traces to the agent not consulting existing memory, which the gate itself excludes ("the existing instruction already required the correct behavior").
- Nothing new: the guard friction is papercut's domain and already in a memory note; the self-caught test bugs are the Honest Work rule being followed; the "skills detected" line on this session is a defect in the candidate's collector, not in the harness.
- Cost: about 11.7k tokens to read this one transcript once, before rubrics, drafting and rendering; about 140k for the skill's default of 12 sessions.

### Verifier findings (22 of 22 CONFIRMED, file:line or command output for each)

- **Skill detection is substring-based.** `detect_skill_candidates` (`collect_sessions.py` lines 283-291) matches `skills/<name>/` path fragments and `"skill"|"name"|"bundled_skill_id":"..."` keys in raw tool-argument text; only a literal tool named `Skill` is special-cased (lines 393-396); a second pass (lines 1280-1297) rescans the condensed transcript and the union is filtered to installed names (lines 1562-1570). This explains the two false attributions on the first sampled session.
- **Injected text survives.** `looks_injected` (lines 428-437) skips only text blocks whose first 80 characters start with `<` and name one of nine tags; the injected `workflow-authoring` skill body in the live transcript starts with a `<command-message>` wrapper and was written verbatim as a `[user]` turn.
- **No redaction, default permissions.** Tool results are truncated to 500 characters (line 31) with an `error|failed|traceback` heuristic (lines 398-403); a grep for secret, token, api_key, password and aws finds no redaction routine; `mkdir` and `write_text` pass no mode (lines 1315, 1600, 1650), and the produced files are mode 644 under umask 022.
- **Scope.** `--all-conversations --days 7 --max-sessions 1` on this host: 208 records, 196 in scope, 121 scoreable, with `cwd` values across about 25 project directories (a private research repository, the members app and 11 of its worktrees, the author's infrastructure repository, papercut, pro-gate, dotfiles and 5 worktrees, oracle, the async research fleet). Session discovery globs every project directory (lines 197-216); the repo filter runs after parsing and is skipped entirely under `--all-conversations` (lines 1351-1355). Worktree sessions match a repo by path prefix (lines 1224-1244); the 68 in-scope dotfiles sessions include 5 worktree cwds.
- **Clean surfaces.** Exactly two `subprocess.run` sites, both read-only `git rev-parse` (lines 108, 1262); stdlib-only imports; the renderer reads local files and calls `webbrowser.open` on a `file://` URI; the JS bundle's one `navigator.` use is a Safari-detection `userAgent` read.
- **Doctrine claims.** The grading runs in the local agent process (`SKILL.md` line 92); the curve floors the worst efficiency label at 0.60 and the worst verbosity label at 0.55; `report.json` stores only curved values; the closing CTA line is mandatory; the edit gate's two sentences are at `skill-improvements.md` lines 13 and 29; rent-check's Phase 4.5 verifier, skill-tuner's three-skeptic panel, `loop_quality/validation.py`'s `SelfCertificationError`, papercut's non-scoring capture and rent-check's Boundaries clause all read as claimed.

## Verdicts

Delivery verdict (all Claude Code scopes): **REJECT** installing the skill as delivered. Two affirmative defects, both measured or read at file:line: under its own name it shadows Claude Code's built-in `/skill-doctor` (observed above), and `SKILL.md` lines 179-184 instruct the agent to end every response with a third-party request-access link, which is a vendor instruction in the operator's output channel (rent-check's own Boundaries doctrine, lines 257-259, treats embedded instructions that steer the auditor's output as an injection-surface finding). A renamed fork with the closing line removed would drop to SKIP on the content verdicts below.

| Component | Target | Verdict | Placement / activation | Evidence | State |
|---|---|---|---|---|---|
| Collector (multi-session, multi-harness transcript harvest) | T1 skill-tuner | **SKIP** | none | different input class: skill-tuner probes one document with a skeptic panel; a harvest of conversations has no analogue and no demonstrated need there | — |
| Collector | T2 rent-check, papercut | **SKIP** | none | the one real capability gap: papercut mines only the current session on request (papercut SKILL.md lines 368-374) and rent-check audits files, not windows of sessions. But the collector detects "skills used" by substring and regex over tool-call text and a full-transcript rescan (`collect_sessions.py` lines 283-291, 379-397, 1280-1297), which mis-attributed two skills on the first sampled session here; its injected-text filter is a short tag allowlist (lines 428-437) that let a whole injected skill body through as a user turn; it redacts nothing and writes plaintext transcripts with default permissions (lines 1313-1315, 1600). An unaudited 62 KB script is the wrong seed for a papercut feature | — |
| Collector | T3 global harness | **SKIP** as covered | none | multi-session search and retrieval is `cass` (indexed transcripts, timer-maintained; memory notes `cass-index-timer-must-stay-enabled`, `cass-retrieval-model-eval-vs-live-wiring`); dispatched-run grading is `scripts/lib/loop_quality/`. Neither is a rubric grader of interactive sessions, and no need for one was stated | — |
| Four rubrics (efficiency, code quality, procedure compliance, verbosity) | all | **SKIP** | none | the grading agent runs "in the current local agent process" (SKILL.md line 92) over its own harness's transcripts with no answer key, no blinding and no independent verifier: self-certification as `loop_quality/validation.py` lines 1-18 and the CLAUDE.md Honest Work rule define it. rent-check's Phase 4.5 refute-by-default verifier (its SKILL.md lines 171-186) and skill-tuner's three-skeptic panel are the incumbents' answer to the same problem. The rubric texts are competent reviewer checklists; nothing in them is absent from the harness's review skills | — |
| Aggregation and curve | all | **SKIP**, red flag | none | `curve(score) = 0.5 + 0.5 * score` (SKILL.md lines 107-113) floors the worst possible rubric at 0.55 to 0.60 and the weights are asserted without derivation; `report.json` stores only curved values (line 135). The "overall" is a presentation number, and skill-tuner's own doctrine already bars single-run composites presented as measurement (tune SKILL.md lines 96-108) | — |
| Edit-drafting gate (`references/skill-improvements.md`) | T1 skill-tuner | **EXTRACT** two sentences into `tune`'s step 3: the causal-necessity test ("would a competent agent with the current instructions still be expected to fail this way? If yes, there is a gap. If no, defer.", line 13) and "When nothing clears this bar, open no change and say, per finding, why not — that is a success. A speculative change is worse than none." (line 29) | doctrine wording only; adversarial read before landing | tune's "Fix what it found" acts on confirmed findings but has no explicit would-the-rule-have-prevented-it test | proposed, comment on skill-tuner #52 |
| Edit-drafting gate | T2 rent-check | **EXTRACT** the same two sentences beside rent-check's removal test (its SKILL.md lines 163-164) | doctrine wording only; adversarial read before landing | rent-check has the removal test but no "no change is a success" clause for PROMOTE/FIX | proposed, rent-check issue |
| Edit-drafting gate | T3 global harness | **SKIP** as covered | none | CLAUDE.md Honest Work already states "Truthful null results are successful outcomes" and harness-vet's VERDICTS.md states "Absence from the incumbent is not itself evidence of value" | — |
| Report, share card, CTA | all | **REJECT** as delivered (see delivery verdict); the renderer itself is clean | none | `render_report.py` makes no network request and embeds the 1.16 MB `@pierre/diffs` bundle inline (lines 98-106, 314); the bundle has no fetch, XHR or beacon and one `navigator.userAgent` read (line 1521); the CTA is hardcoded at line 312 and mandated by SKILL.md lines 179-184 | — |
| Harness gate (`supported-harnesses.md`) | all | **SKIP** | none | sound design (identify the harness from runtime context, never from files on disk; stop before reading history if unsupported), but it does not prevent the name collision, since Claude Code is a supported harness | — |
| Warp decoder | all | **SKIP** | none | no target uses Warp; read-only sqlite with a hand-rolled protobuf reader that silently skips unknown fields | — |

Rollup: T1 skill-tuner: 1 EXTRACT (wording), the rest SKIP, delivery REJECT. T2 rent-check and papercut: 1 EXTRACT (wording), the rest SKIP, delivery REJECT. T3 global harness: all SKIP, delivery REJECT. Not deep-vetted: the 25 other skills in the repository; this vet covered `skill-doctor` only.

## Price

Only the EXTRACT survives, and it is two sentences of doctrine: zero runtime cost, no tools, no placement beyond the two skills' own instruction files, an adversarial read as the activation gate. Everything else was priced as SKIP or REJECT before this phase: installing the skill would add a 1.33 MB directory with an unaudited collector to a skills tree, a permanent `/skill-doctor` shadow, and a vendor line in every response.

## Audit dividend

1. **A user skill can shadow a built-in slash command.** Installing Warp's skill under `skill-doctor` made `/skill-doctor` run the skill instead of Claude Code's usage report. The operator's own skill trees were checked for collisions with built-in commands (result below); a `harness-doctor` check that diffs skill names against the CLI's built-in command list is a two-line guard.
2. **A harvested transcript is mostly harness text.** The condensed Claude Code transcripts the collector wrote carry injected skill bodies and system reminders as user turns; any transcript-grading instrument in this harness must strip them first, or it grades the doctrine rather than the session. `cass` indexes raw JSONL, so its retrieval hits carry the same weight of injected text; worth a look at what its reranker sees.
3. **Substring skill detection over tool-call JSON is worthless here.** 203 skills and a skill roster injected into every prompt guarantee false positives; the built-in `/skill-doctor` counts real invocations and is the right source.
4. **Transcript dumps in scratch default to world-readable files.** The collector wrote 156 KB of session content to `/tmp` with mode 644. The same applies to any of the harness's own tools that write transcript excerpts to scratch; the `/tmp/<unique-dir>/` convention does not set a mode.
5. **A vendor CTA in a SKILL.md is now a live pattern in a 585-star skills repo.** rent-check's Boundaries doctrine already covers it for audited content; the skill-vetting checklist in `harness/third-party-skill-vetting.md` should name "mandated closing lines" beside self-updating instruction channels.

Collision check run this session: no directory under `~/.claude/skills` (134), `~/.agents/skills` (47) or `~/.codex/skills` matches a built-in command name (`init`, `doctor`, `skill-doctor`, `review`, `code-review`, `security-review`, `simplify`, `loop`, `run`, `schedule`, `compact`, `config`, `model`, `memory`, `plugin`, and the rest of the list checked). Clean today; the guard is for the next install.

## Do-not-retry unless

- The skill is forked under a name that does not collide with a built-in command and the mandated closing CTA is removed.
- Skill detection reads `Skill` tool_use events rather than substrings, injected system and skill text is stripped before grading, and transcripts are redacted or written with restrictive permissions.
- The scoring step gains an independent verifier or a planted-defect answer key, or the harness states a need for a rubric grader of interactive sessions that `cass` plus `loop_quality` cannot meet.
- Warp becomes a runtime here (the decoder then matters).

## Outcome

- Landed in this PR: this note. Nothing installed, enabled, or ported.
- Scratch state the operator should know about: the collector's condensed transcripts and inventories (156 KB from the three-session run, plus the one-session `--all-conversations` run) are still under `/tmp/pe-vet-20260920/warp-report/` and `/tmp/pe-vet-20260920/warp-report-all/` at mode 644. Two deletion attempts from this session were refused by its permission policy, so they were not removed; they are plain files in `/tmp` on a single-user host and go with the next `/tmp` cleanup, or sooner by hand. The tarball copy of the repository and the kept `/tmp/claude-eval-*` sandbox directories from the sibling vet are in the same state.
- Landed the same day (2026-09-20): rent-check #11 via PR #12 (v0.3.1, published with an announce receipt on 2026-09-20; the mirror test before any FIX or PROMOTE rests on a transcript, rescoped after a refute-by-default read showed the first draft fused two exclusions and contradicted thesis 2); the `tune` step 3 edit gate via skill-tuner PR #54 (v0.9.0, shipped as v0.9.1 after review).
- Landed: the `harness-doctor` check and the vetting-checklist items via dotfiles #1247 / PR #1248 (section 7 warns when a skill directory under `~/.claude`, `~/.agents` or `~/.codex` shares its name with a built-in slash command, with a ten-assertion hermetic test; the typosquat bullet gained the built-in collision check and the prompt-injection bullet the mandated-closing-line example, quoting rent-check's Boundaries clause). Two refute-by-default lenses ran on that diff first and removed a `case`-glob bug, an uncited list and an over-asserting message.
- Memory: `warp-skill-doctor-harness-vet-2026-09` (pointer to this note).
- Spend for this candidate: one headless call ($0.04) plus about 274k subagent tokens; the collector and tests ran without model calls.
