# rent-check evidence dossier

The research behind the rubric tiers, verified 2026-08-10 by fetching every
primary source (papers via arXiv, tools by reading their actual source files,
blog posts by direct scrape). Single-source claims are flagged; treat them as
leads, not laws.

## Controlled studies

- **"Guardrails Beat Guidance" (arXiv 2604.11088, Apr 2026)** — 5,000+ Claude
  Code runs, 25,532 rules mined from 679 real rule files, SWE-bench Verified.
  Random rule sets tied expert-curated sets (both +13.8pp over no-rules
  baseline; Cochran's Q p=0.697) — a content-independent priming effect.
  Per-rule ablation (n=35): negative constraints all helped (+5.7 to +20.0pp),
  positive directives all hurt (−8.6 to −14.3pp), polarity split Fisher
  p=0.029. "Distortion averaging": 14/18 individually harmful rules canceled
  out in ensemble; pass rate flat from 0 to 50 stacked rules. Limitations
  (self-disclosed): single model/benchmark/language; the one significant
  per-rule result would not survive multiple-comparison correction. License
  CC BY-NC-SA — cite findings, do not reproduce prose.
- **Instruction-adherence RCT (arXiv 2605.10039, May 2026)** — fractional
  factorial, 1,650 Claude Code sessions, 16,050 function-level observations.
  File size (25–500 lines): null, BF10=0.096 (affirmative null, robust across
  prior sweep). Direct cross-file conflict: null, BF10=0.053. Instruction
  position and single-vs-split architecture: null but without Bayes-factor
  support. The one large effect: within-session decay, OR=0.944 per generated
  function (~5.6% lower compliance odds per unit; p≈1e-49), direction
  reproduced across three model/codebase cells. Task identity dwarfed every
  structural variable (26pp spread between tasks). Limitation: the dependent
  variable is a trivial marker rule; transfer to demanding rules untested.
- **"Evaluating AGENTS.md" (arXiv 2602.11988, ETH Zurich, v2 Jun 2026)** —
  own 138-task benchmark + SWE-bench, multiple agents/models. Context files
  did not generally improve success (human-written ~+4%, LLM-generated ~−3%)
  while adding >20% inference cost. Explicit instructions in the file ARE
  followed (tool-trace-verified); repository overviews — the most-recommended
  content class — are not useful. Recommendation: skip LLM auto-generated
  files; keep human files minimal, only non-inferable conventions.
  Independently corroborated by press and three citing tools.
- **Configuration smells (arXiv 2606.15828, SCAM 2026)** — six-smell taxonomy
  (Lint Leakage 62%, Context Bloat 42%, Skill Leakage 35%, Conflicting
  Instructions 28 instances at 57% detector precision, Init Fossilization 24,
  Blind Reference 16) across 100 popular repos; Apriori co-occurrence
  (conflicts+skill-leakage → bloat, conf 0.83). Caveat: its Context Bloat
  threshold (200 lines) and conflict smell are imported from folklore, and
  the RCT above directly tested both and found nulls — use the taxonomy as a
  *prevalence* catalog, not causal claims.
- **ContextCov (arXiv 2603.00822)** — compiling instructions into executable
  gates (PATH shims, Tree-sitter queries, import-graph validators): 88.3%
  constraint compliance vs 67.0% prompt-only vs 50.3% LLM-self-review
  (which scored *below* prompt-only — "critique-induced drift"), on 300
  SWE-bench Lite tasks. **Single-source and unverifiable code**: the claimed
  GitHub repo 404s. Cite the direction (enforcement > prose > self-critique),
  not the numbers, until independently reproduced.
- **HANDBOOK.md (arXiv 2607.25398, Surge AI, Jul 2026)** — 65 tasks under
  20–124-page standing policy docs, 824 deterministic two-sided criteria.
  Best of 30 frontier configs passed 36.2% strict; agents' own compliance
  self-reports were the least trustworthy artifact in the trajectory. Failure
  taxonomy: proximate-request-overrides-standing-rule; check-performed-then-
  ignored; detail decay over ~17-step horizons; false self-report.

## Vendor evals (primary-source verified, incentives noted)

- **Vercel (Jan 2026)** — teaching a framework outside training data:
  baseline 53%, skill-left-to-fire 53% (uninvoked in 56% of cases; the unused
  skill scored below baseline on tests), skill+forced-instructions 79%,
  compressed AGENTS.md docs-index 100% at 80% less token weight. Recipe: a
  pipe-delimited path→file index in the always-loaded file, full docs on disk
  read on demand.
- **Augment Code (Apr 2026)** — golden-PR benchmark: 100–150-line files plus
  a few linked references were the top performers (10–15% gains, reversing
  past that band); a 30+-don't file made a CRUD task ~2x slower and ~20% less
  complete; a 3-row decision table +25% on best-practices adherence;
  discovery hierarchy measured: root file ~100%, linked references >90%,
  nested READMEs ~40%, orphan docs <10%.
- **philschmid.de synthesis** — a tool named in the context file was invoked
  ~160x more than an unnamed equivalent (single-source; consistent with the
  ETH finding that explicit instructions are followed).

## First-party (Anthropic, verified against product and posts)

- **`/doctor`** (alias `/checkup`; full checkup v2.1.205+, CLAUDE.md trim
  v2.1.206+) — 10 checks including unused-extension detection vs context
  cost, CLAUDE.md dedup, derivable-content trim, always-loaded→lazy
  migration, slow-hook flagging. Confirm-gated. Verified three ways: binary
  strings, official docs, launch blog post. Do not duplicate it — rent-check
  cites checks `/doctor` covers and adds the layers it doesn't.
- **"New rules of context engineering for Claude 5 generation models"
  (2026-07-24)** — Anthropic removed >80% of Claude Code's system prompt for
  Claude 5-gen models with no measured eval loss. Six shifts: rules→judgment,
  examples→interface design, upfront→progressive disclosure,
  repetition→single statement, CLAUDE.md-as-memory→auto-memory, simple
  specs→rich references (code > prose > screenshots).
- **"Steering Claude Code" (2026-06-18)** — the 8-row mechanism matrix
  (root/subdir CLAUDE.md, rules, skills, subagents, hooks, output styles,
  append-system-prompt) by load timing, compaction behavior, and cost; the
  five mapped anti-patterns ("every time X do Y" prose → hook; "never do X"
  prose → PreToolUse gate or managed settings; ~30-line procedures → skill;
  unscoped API rules → path-scoped; personal prefs in project files → user
  files). Root guidance: <200 lines, owned, reviewed like code.
- **Docs (memory/rules)** — path-scoped rules trigger on *read*, not on every
  tool use (the write-blindness gap); memory index: first 200 lines load.
- **System-prompt corpus (265 versions, third-party archive)** — emphasis
  keywords converged: IMPORTANT 12→4, density ~7.5→~1.4 per 1k words.

## Multi-layer resolution semantics (verified 2026-08-11, primary docs)

- **Claude Code (additive)** — "CLAUDE.md and CLAUDE.local.md files in the
  directory hierarchy above the working directory are loaded in full at
  launch"; subdirectory files "are included when Claude reads files in those
  subdirectories"; "All discovered files are concatenated into context
  rather than overriding each other." (code.claude.com/docs/en/memory,
  /large-codebases). `claudeMdExcludes`: glob-based skip, merges across
  settings layers, managed-policy files exempt; docs say it also covers
  rules files — **contested** by open issues reporting rules exclusion
  broken in practice; verify per CLI version.
- **Codex (concatenate + positional precedence)** — one file per directory
  from project root down to cwd plus a global file, "concatenates files
  from the root down"; "Files closer to your current directory override
  earlier guidance because they appear later in the combined prompt";
  PROJECT-chain size capped by `project_doc_max_bytes` (32 KiB default),
  which truncates leaf files first; the global file is exempt — it loads in
  full via a separate uncapped path (source-verified 2026-08-11 against the
  openai/codex implementation: cap constant `config_toml.rs:70`, leaf-first
  truncation `agents_md.rs:130`, uncapped global read
  `codex-home/src/instructions/mod.rs:24-67` — a foreign-repo audit
  corrected this entry's earlier doc-derived wording). `AGENTS.override.md` fully replaces (not
  merges) the same directory's AGENTS.md and is git-tracked by default.
  (developers.openai.com/codex/agent-configuration/agents-md)
- **agents.md convention** — "The closest AGENTS.md to the edited file
  wins" (site FAQ) — but this is an informal convention page, not a formal
  spec, and nested-file discovery is a Codex-specific extension other tools
  don't uniformly implement. A v1.1 draft formalizing parent-child
  precedence exists as an open, unmerged issue (agentsmd/agents.md#135) —
  watch item, not citable behavior.
- **Cross-layer auditing frontier** — third-party linters now do
  nesting-aware parent-child analysis (one treats child-overrides-parent as
  info-severity, not a conflict); Anthropic's `/doctor` dedups only
  same-directory CLAUDE.local.md vs. checked-in CLAUDE.md, leaving true
  cross-directory contradiction hunting to manual review — the M-family's
  differentiation.

## Contradiction map (folklore vs. measured)

| Community claim | Status |
|---|---|
| "Keep it under 200 lines or compliance drops" | Size null 25–500 lines (BF-supported). Keep short for *load cost*, not compliance. |
| "Put critical rules at the top" | Position null. The real lever is session decay → enforcement/re-injection. |
| "Split big files into many" | Architecture null. Split for load class, not compliance. |
| "Conflicting rules confuse the model" | Direct conflict tested null (BF-supported) on a trivial rule; still flag conflicts as maintenance debt. |
| "Curate rules carefully — wording matters" | Random tied curated. Polarity is the only content variable with measured per-rule effect (single-source). |
| "Prune MCP servers to save context" | Stale where tool schemas are deferred (name-only cost). Check load class first. |

## Measured negative results (cite before re-attempting these designs)

- **On-demand retrieval gating of skills/rules is dead on a base-rate wall**
  `[single-source, measured]` — a pilot replacing force-loaded skills with a
  keyword/embedding retrieval hook measured precision-when-firing ≤0.4% for
  both gate families on a real ~900-skill catalog; genuine-need moments were
  ~0.11% of triggers. The author shipped shadow-mode only and kept skills
  force-loaded. Retrieval-vs-always-loaded is a measured trade, not a style
  preference.
- **Minimal context is faster, not safer** `[single-source, n=1]` — a
  12-cell layered ablation found the stripped-to-load-bearing-layers cell
  ran ~2.6x fewer turns at ~half the cost of the full-context cell, while
  pitfall avoidance depended on specific layers being present. Presence
  buys correctness; curation buys speed and cost. Both matter; neither
  substitutes for the other.

## Known gaps (open problems, honestly held)

- No public study ablates rule *content* classes beyond polarity; no study
  tests rule-interaction effects.
- All LLM-judge evals in this space share model family with the system under
  test; no cross-vendor judging exists yet.
- Every published sample size is small and the honest authors say so; a
  verdict resting on one study stays `[single-source]` here no matter how
  much the ecosystem quotes it.
