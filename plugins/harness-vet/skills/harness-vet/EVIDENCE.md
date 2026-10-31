# Evidence dossier

The receipts behind the default-SKIP prior and the supply-chain bar. Each
claim carries its source and a status flag: **[peer-track]** (academic work,
may still be preprint), **[vendor]** (company research or blog),
**[measured-here]** (observed on the harness this skill was mined from,
2026-07 through 2026-09), **[directional]** (source too weak to carry a
number — use the direction, drop the digits). SKILL.md's inline shorthand maps here as:
[research] = [peer-track] or [vendor]; [measured] = [measured-here]. The
dossier flag is the authoritative tier.

Meta-rule, itself part of the method: a percentage from an unreviewed preprint
or a vendor PDF is directional until replicated. What carries weight is
convergence across independent sources — and on "less context, fewer tools,
vetted sources" the convergence below is unusually strong.

## Why the default verdict is SKIP

- LLM-generated context files (AGENTS.md-style) *reduced* agent task success
  by 0.5-2% while raising cost 20-23%; human-curated ones helped only
  marginally (~+4%, and not for every agent tested). Authors' conclusion:
  context files should state minimal requirements only. Gloaguen et al., ETH
  Zurich SRI Lab, arXiv 2602.11988. [peer-track]
- Anthropic removed over 80% of Claude Code's system prompt for newer models
  with no measurable eval loss (blog, 2026-07-24); an independent replication
  on a small model reported score parity with 32% fewer input tokens
  (Antigma, 2026-07-25). [vendor]
- Pruning agent context to recent tool calls plus light summarization beat
  full-context retention 91.6% vs 71.0% task completion at ~64% fewer tokens
  on a 50-task agentic benchmark — stale context misleads, it is not neutral
  overhead. arXiv 2606.10209. [peer-track]
- Clutter can silently not work at all: a legacy rules format scored 0/9 rule
  compliance in one migration test where the current format scored 9/9 — the
  cost was paid, the behavior never fired. [directional]
- Base rate: across ~15 vets of popular, well-regarded candidates on the
  authoring harness, no multi-component candidate was adopted wholesale as
  delivered; single scoped components occasionally earned ADOPT, the modal
  outcome was EXTRACT of a handful of patterns, and two vets' chief value
  was the drift they exposed in the host harness. [measured-here]
- The starkest duplication receipt: a ~64KB, 7-file commercial skill's
  detection verdicts came back identical, item for item, to the authoring
  harness's existing ~170-line doctrine on a 7-item planted audit — same
  hits, same miss, zero false positives, both arms (2026-08-10).
  [measured-here]
- The audit dividend generalizes: in 3 of 3 dogfood runs, testing the
  candidate's described failure mode against the host harness produced the
  run's chief finding — a doctrine blind spot, a silently-failing nightly
  auth job, and a routing proxy structurally discarding model reasoning
  (2026-08). [measured-here]

## Tool count is a priced quantity

- Narrowing the tool set presented to the model raised tool-selection
  accuracy from 13.6% to 43.1% in the RAG-MCP study. [peer-track]
- Microsoft Research, citing OpenAI's own guidance: keep tool count under
  roughly 20; large toolsets showed performance losses up to 85%, and
  oversized tool *responses* (one tool emitted 557,766 tokens) degraded
  performance up to 91%. [vendor]
- The threshold moves with model generation — one production telemetry set
  showed a small model dropping below 90% accuracy at 10-15 tools while a
  larger one held to 20-30. Encode the *test* (measure selection accuracy at
  your tool count), never a fixed N. [directional]

## Supply chain

- Snyk scanned 3,984 public Claude Code skills: 13.4% carried critical
  issues, 36.8% carried some issue, 76 were confirmed malicious. [vendor]
- OX Security submitted a benign proof-of-concept package to 11 public MCP
  registries; 9 accepted it with zero security review. Named CVEs exist for
  protocol-level STDIO command injection (CVE-2026-30623, CVE-2026-30615).
  [vendor]
- Combined attacks — a prompt-injected description *plus* malicious bundled
  code — achieved 66.7-100% success where single-vector attacks scored far
  lower; reviewing only descriptions misses the highest-yield shape. Read
  the code. arXiv 2604.01905. [peer-track]
- Trust is transitive: approving a plugin approves every component author
  beneath it — its skills, hooks, binaries, and their update channels
  ("trust pyramid", Pluto Security). A component that rewrites its own
  instructions on a schedule extends that trust to every future version
  sight unseen [measured-here: one vetted skill pack ran a daily
  self-updater over its own instruction files]. [vendor]
- Anthropic's official posture puts vetting on the operator: install skills
  only from trusted sources and audit the skill file plus bundled scripts —
  no platform sandboxing guarantee is claimed. [vendor]
- A release pipeline can suppress its own integrity signals: one desktop
  candidate set a null signing identity, disabled notarization, had CI *fail
  the build if signed*, and self-updated silently on a 6h timer behind a
  SHA-256 produced by that same pipeline. Deliberate suppression is the
  signal — an unfunded project that merely lacks a certificate is not
  [measured-here: local-mcp / chat-on-steroids vet, 2026-09].
- Terms are the operator's call, and their own uptime is the evidence: the
  same vet flagged a candidate's chatgpt.com automation as disqualifying on
  OpenAI's terms while this harness's own terminal review gate drove the
  same site the same way — 309 runs in 7 days, months of operation, one
  anti-scraping trip ever (2026-07-03, under 3 parallel runs), no account
  action. The vet had read phase 1's warning that same session and applied
  the clause anyway. Where a verdict *does* rest on terms, its re-eval
  trigger is a documented API, since commits cannot change what the terms
  permit [measured-here: local-mcp / chat-on-steroids vet, 2026-09].
- A sandbox is not all-or-nothing: that vet's candidate engaged Landlock and
  blocked network egress correctly, yet two live probes escaped it because
  the writable allow-list was derived from caller-supplied arguments (the
  write target's parent directory; the caller's `cwd`). Working confinement
  plus a caller-defined boundary is the shape to probe for — and it is a
  reason not to run the artifact, not a reason to skip reading it
  [measured-here: same vet].

## Method gates (mined from failed shortcuts)

- **Model confound**: before trusting any before/after transcript delta,
  control for model mix — one naive -1.35pp effect dissolved to -0.36pp
  (n.s.) once model drift was controlled. [measured-here]
- **Instrument validity**: verify the detector before believing a zero — one
  audit's grep tool silently skipped hidden directories; never trust a
  detector whose matches you have not read. [measured-here] A second,
  independent hit of the same failure class, and the one that forced this gate
  into the Verify phase: a lint plugin resolved the design system it checks
  against from a config file that was not an ancestor of the app directories,
  so discovery silently found nothing when it ran from there. It did not return
  zero — rules still fired wherever they could resolve locally, giving a
  plausible **32** findings with every app green under `--max-warnings 0`. The
  real count, once the setting was declared explicitly, was **3,203**. Only a
  planted known-positive caught it; every intermediate measurement was
  self-consistent and reproducible. Partial discovery failure, not total
  failure, is the dangerous shape: a broken detector that emits zero or an
  error is self-evidently suspect, while one that emits a plausible low count
  reads as a clean codebase. [measured-here: shadcn/lint vet, 2026-09-20,
  dotfiles#1239]
- **Numbers decay**: a merged PR's stated verification numbers failed to
  reproduce from its own squashed code weeks later; re-run before citing.
  [measured-here]
- **Fabricated documentation exists in the wild**: a popular skill pack's
  feature docs described platform commands that do not exist — 5 of 5
  checked claims were confabulated. Official docs are the reference, the
  candidate's prose is the claim. [measured-here]
- **Vibes dressed as data**: sources whose headline numbers came from
  self-validation or vendor-hosted, unreviewed PDFs get flagged and their
  digits excluded from verdicts — the flag itself goes in the eval note so
  the exclusion is auditable. [measured-here]
- **A documented opt-out is per-mechanism, not per-promise**: one vendor's
  data-use page named an environment variable and a CLI flag as equivalent
  opt-outs. Measured per channel on the same fixture, each control in
  isolation, **no single documented control closed everything** — the env var
  left the score upload (private repo owner/name, HEAD commit SHA, every
  finding's file path) *and* the per-dependency lookups running; the flag
  closed three of four but not the lookups; a committed config file closed the
  opposite pair, leaving crash and trace telemetry live. They were separate
  gate functions reading different inputs, so the names implied an equivalence
  the wiring never had. Two further traps from the same run: the recipe that
  did close everything was then stripped by the target's own task runner
  (turbo 2.10.12, strict `envMode`, no `globalPassThroughEnv`), so a control
  verified at a bare shell is not verified where it will run; and two of five
  readers in that vet asserted the task runner defaulted to loose mode, which
  a direct measurement and the runner's own `--dry=json` both refuted.
  [measured-here: react.doctor vet, 2026-09-20, dotfiles#1227 / #1233 / #1234]


## Scope-aware adoption: primary sources checked 2026-09-05

These sources guide the v0.2 design; they are not measurements of this skill.
Historical numbers above belong to their original studies and harness runs,
not a guaranteed effect or a universal skill-count budget.

- **Platform scope is source-specific.** The [Claude Code skills reference](https://code.claude.com/docs/en/skills) distinguishes personal, project,
  managed, plugin and nested sources, along with precedence, activation and
  hosted-session differences. A plugin namespace prevents some name conflicts,
  not semantic duplication. Check the current host rather than freezing this
  inventory as a portable law. [vendor]
- **Progressive disclosure, not universal installation.** Anthropic's
  [Agent Skills engineering guide](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)
  separates discovery metadata, the invoked body, references and executable
  resources, and warns to inspect trusted provenance and bundled behavior.
  Price these layers separately at the scope where they load. [vendor]
- **Measure useful skills as well as clutter.** [SkillsBench](https://arxiv.org/abs/2602.12670) compares curated skills with matched
  no-skill runs and deterministic task verifiers. Its current abstract reports
  benefits that vary by model/harness and skill composition. This supports
  target-task paired evaluation, not a blanket claim that skills hurt or help.
  Results are study-specific; do not import their gains into this harness.
  [peer-track]
- **Composition is not availability.** [AgentSkillOS](https://arxiv.org/abs/2603.02176) reports structured composition outperforming
  flat invocation with the same skill set, using model-judged artifact quality.
  Its benchmark is not proof that every small project needs an orchestrator.
  [peer-track]
- **Instructions are operational supply-chain content.** [Agent Skill registry
  attacks](https://arxiv.org/abs/2605.11418) studies metadata/instruction attacks
  on discovery, selection and admission. Review whole instruction files and
  execution surfaces; registry badges and benign descriptions are not enough.
  Project-local loading does not make malicious instructions safe. [peer-track]
- **Keep the mechanism small.** Anthropic's [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents) recommends
  the simplest system that works and adding complexity only when needed.
  [Seeing like an agent](https://claude.com/blog/seeing-like-an-agent) describes
  revisiting tool assumptions as models change. Recheck changed premises and
  prefer native scoping/evaluation tools over another permanent service.
  [vendor]

The target/task applicability and cross-location note rules are this skill's
engineering design, not a claimed vendor standard. The v0.2 regression cases
exercise decision behavior; they do not prove SEO or estate-planning quality,
actual runtime containment, or a general improvement across all harnesses.

## Discovery and the comparison protocol: sources checked 2026-10-25

These sources guide the v0.3.0 discovery step and the phase-4 protocol
additions; the only measurements of this skill's own discovery text are the
blind probes at the end of this section (the first on a draft shape, the
second on the draft paragraphs, the third on the shipped ones), and they are
measurements, not gates.

- **Single-run deltas are inside the noise.** [On Randomness in Agentic
  Evals](https://arxiv.org/abs/2602.07150) reports, across 60,000
  trajectories, single-run pass@1 estimates varying by 2.2-6.0 percentage
  points, with standard deviations above 1.5 points even at temperature 0,
  and recommends multiple runs per task. Phase 4 therefore runs every arm at
  least 3 times and treats a delta below the run-to-run spread as noise.
  [peer-track; abstract and introduction read]
- **Pairwise verdicts flip with position.** [All Verdicts are Not
  Equal](https://arxiv.org/abs/2610.12083) reports judge verdicts changing
  across identical replications at temperature 0 and position swaps
  flipping most verdicts on hard tasks, with holistic rubric scoring more
  trustworthy than pairwise win rate. [AgentSkillOS](https://arxiv.org/abs/2603.02176)
  judges every pair in both orderings and records conflicting preferences
  as ties. Phase 4 adopts both-order judging with flips as ties and keeps
  rubric scores beside the win/loss; skill-creator's `agents/comparator.md`
  (read in full, 2026-10-25) judges once, in one order, and instructs the
  judge that ties should be rare — it is the paired instrument only with
  that rule added. [peer-track; vendor]
- **A skill can displace a stronger native strategy.**
  [SkillsBench](https://arxiv.org/abs/2602.12670) App. F reports
  self-generated skills scoring 8.1-11.5 points BELOW the no-skill baseline
  on affected tasks, with a heavyweight pipeline crowding out a simpler path
  and activation displacing a native strategy as named harm patterns; App.
  D.1 reports normalized gain (skill minus vanilla, over one minus vanilla)
  to avoid ceiling artifacts, and deltas as paired differences on the same
  task. Phase 4 adds one control task the bare arm already solves and
  reports normalized gain beside the absolute delta. [peer-track; HTML read]
- **Proxies steer selection.** [Agent Skill registry
  attacks](https://arxiv.org/abs/2605.11418) reports functionally
  equivalent skills chosen 77.6% of the time against a 50% chance baseline
  when only the description text differed. The digest's contender row
  therefore carries content facts only — no stars, likes, follower counts,
  recency or author — so nothing downstream can rank on them. [peer-track]
- **Non-discriminating items pad the denominator.** skill-creator's
  `agents/analyzer.md` flags assertions that pass in every configuration as
  unable to differentiate skill value; phase 4 drops fixture items that pass
  or fail in every arm from the arm comparison. [vendor]
- **Scanned and not borrowed.** An oracle-skill arm (per-arm config
  isolation already forces each skill into its arm, so retrieval error is
  not a variable here); the registry study's paired-choice description test
  (a vet is not a registry choosing among near-duplicates, and phase 5's
  supply-chain read covers injected description text); Bradley-Terry
  aggregation (at most six arms on one fixture).
- **Blind planted-positive probe, 2026-10-25.** One task (annotated,
  editable vector technical illustrations with named parts), a four-item
  key held by the judge and never shown to the searcher, the v1 discovery
  shape with no X client. Found 2 of 4 (the candidate skill itself and one
  programmatic SVG library) plus 6 unplanned relevant upstreams admitted at
  triage; missed one X-only project (the record reads `not searched: lane
  (c) / X`) and one reachable project (query wording). The candidate skill
  appeared under seven listing sites and two names before dedup; the library
  was reached only through vocabulary learned in the first follow-up pass;
  `gh search repos` returned empty for every query, so GitHub coverage was
  thin; the searcher overran its own 3-query cap by 2 and only the written
  record showed it. This probe measures detection of partial search failure
  on one task, bounded by what the designer thought to plant (the same
  limit the fixture rule above states); it does not estimate recall over
  the unknown universe and did not select the design. [measured-here]
- **Second blind probe, 2026-10-26, draft v0.3.0 paragraphs, X available.**
  Same task and four-item key; three independent searchers each ran the
  draft discovery paragraphs with no candidate named, under a 40-search-call
  budget the probe imposed; one key-holding judge per record. Found 2, 2 and
  1 of 4 (union 2: the skill and the library); 12, 7 and 9 unplanned
  relevant upstreams admitted at triage; no proxy language in any contender
  row. The X-only project was missed in all three runs although X answered
  every query with zero or off-topic results, so the record shows a thin
  lane, not an unreachable one, and the errored-source rule cannot catch
  this; the hidden-line backend was missed in all three. The library was
  reached from a name-free query in every run (a lane query in two, a pass
  in one). The skill's two finds each carry a query naming it logged in a
  lane cell, so those records cannot show whether the find was name-free;
  the third run filed a name-bearing follow-up in a lane cell too, but its
  name-free first hit was on record. One run slated a CAD module whose own
  row said headless export was unsupported, a hard mismatch the text says
  to drop. Lane cells ran up to 12 queries before passes began, and one run
  hit the probe's call budget and had to file it under the access stop.
  Four text changes followed: a 4-query cap per lane/source cell, a cell
  covered only by its own queries from a source that answered, hit-derived
  queries logged as pass queries, and a budget named in stop (c). The same
  limits as the first probe apply: one task, a key bounded by what the
  designer planted, no estimate of recall over the unknown universe.
  [measured-here]
- **Third blind probe, 2026-10-26, shipped v0.3.0 paragraphs, X
  available.** Same task, key, call budget and judge; three searchers on
  the text as shipped. Found 3, 2 and 1 of 4 (union 3: the skill, the
  library and the hidden-line backend); 8, 11 and 10 unplanned relevant
  upstreams admitted; no query naming a key item in any lane cell
  (hit-derived queries were logged as passes, as the new rule says); no
  proxy language; every record complete. No cell fell to `not searched`:
  the rate-limited GitHub queries sat in cells other queries had answered,
  and each run disclosed them in the cell's caps text and in the
  recommendation's not-searched clause. The X-only project was missed
  again in all three runs with X answering zero results on nearly every
  query: six of six runs with X available. The lane was not thin; the
  queries were the wrong shape (the next bullet). Every run overran
  the 4-query cell cap in at least one GitHub cell (multi-word `gh search`
  queries returned empty arrays and short retries followed) and one run
  ran a fifth pass; each overrun was disclosed in the record, so the cap
  worked as a disclosure line, not a wall. One run said two of its queries
  came from the searcher's own prior knowledge rather than a hit. The slate
  differed by run (the skill in all three, the library in two, a CAD
  library in two, a diagram skill and a vector viewer once each): one run's
  slate is not the slate, which is the N>=3 rule applied to discovery
  itself. Same limits as above. [measured-here]
- **X query shape, 2026-10-26, `search_posts_all` (full archive), same
  task.** The six probe runs' 21 X queries (extracted from the two probe
  records and counted by script): 19 were keyword strings of four to ten
  terms, every one requiring `SVG`; the other two were three-group queries
  with `SVG` inside an OR-group whose last group was `(LLM OR agent OR
  Claude)` or `(Claude OR Codex OR agent)`; none of the 21 carried `skill`.
  The X-only project's post says "skill" and "exploded-view illustration"
  and never "SVG". Six queries run the same day, result count and whether
  that post was in the results: `"exploded view" (illustration OR diagram) (agent OR
  Claude OR skill) -is:retweet` 5, present (a live run's own first X query,
  reproduced); the same with `SVG` in place of the second group, 4, absent;
  the same with `skill` dropped from the third group, 4, absent; `"exploded
  view" (illustration OR diagram) skill -is:retweet` 3, present; `"exploded
  view" (skill OR agent) -is:retweet` 10 on the first page, absent from it;
  a probe-style string `exploded view technical illustration SVG agent
  generated parts labels` 0. So each group needs the word posts use and no
  group may require a format or library word; the discovery text now says
  so. Not re-measured: whether the rule holds on other tasks, and X results
  drift by the day, so the counts date this receipt. [measured-here]
- **First live run, 2026-10-26, the `teardown` vet (harness-vet#25; note
  `docs/vets/2026-10-26-teardown-harness-vet.md` in dotfiles, PR #2024).**
  v0.3.0 text at `446464d`, read from the checkout. Discovery reached all
  four probe key items for the first time: the X-only project came from the
  first X query (three groups, the words posts use) and was dropped on
  content; slate linework and anatomy with the third slot left empty; stop
  (b), an incomplete search; the GitHub implementation cell overran the cap
  by one and said so, as in every probe run. Phase 4: 24 runs, all ok,
  N = 3 per arm per task, both-order judging, 108 judge calls. The
  candidate lost 9 of 9 pen pairs to bare with both orders agreeing in 18
  of 18 calls (re-tallied from `judge.tsv` by a second session), and sat at
  0.50 on the displacement task; verdict SKIP, nothing installed; about
  $35. Two isolation gaps, now in the phase-4 text (#27): a per-arm config
  directory plus a scratch `--user-data-dir` still wrote the default Chrome
  profile's crash-reporter settings until the XDG pair was set per run and
  per scorer call, and the forked runner exited 0 on an error result. Not
  measured: the contenders against bare (not predeclared), the viewer and
  PDF paths, and egress by interception. [measured-here]

## Rule selection is a separate decision from instrument validity

- A detector can be provably live and still be adopted wrong, because "does it
  fire" and "which of its checks do we enable" are different questions. Measured
  on `eslint-plugin-react-doctor` (906 rules; `configs.recommended` enables 566)
  against the UI package of one of the author's private apps, 2026-09-20: a 9-rule subset selected as "the
  rules that caught planted defects" produced 44 findings of which **4** were
  correct and in live code. Its dominant rule supplied 33 of the 44 and scored
  **1**, in a component nothing imports; on one file its suggested fix would have
  broken a working animation. Re-ranking the same broad run by sampled precision
  surfaced two rules the original selection missed entirely, which found 6 real
  defects in 6 hits — including five components defined during render that were
  remounting a live application sidebar on every route change. Shipped as
  a PR in that private app. [measured-here]
- The two rankings that failed both look like evidence. A fixture-derived subset
  carries a demonstrated true positive for every rule in it, and says nothing
  about the rules never exercised; a frequency ranking of a broad run promotes
  high-volume stylistic rules and buries structural ones (the rule that found the
  worst defect fired 5 times and fell below the reporting cut, while the rule
  with 1-in-33 precision ranked #2 by count). Agreement between the two is not
  independent confirmation: neither measures whether a hit is a true positive.
  [measured-here]
- Corollary observed in the same pass: a claim that an existing rule "already
  covers this" is worth one command. `react-hooks/static-components` was asserted
  to catch the nested-component defect; run directly with a known-positive control
  proving the rule was live, it found nothing on the affected file.
  [measured-here]

