# Harness vet: pstack `no-comments`, Comment Sicko and the comment-clutter concept

**Date:** 2026-11-24
**Ask (operator):** "i want to /harness-vet:harness-vet this concept or skill. we have comment
clutter in many codebases, so this is likely a useful skill to add throughout our stack and
perhaps wire into our skills like /harness-optimizer:harness-optimizer etc", with six X posts
and `cursor/plugins` `pstack/skills/no-comments/SKILL.md`.
**Tracking:** the pull request that adds this note, branch `no-comments-vet`.
**Fixture:** `harness/vet-fixtures/no-comments-2026-11/`. The decision rule and its three
amendments, each dated before the runs it governs, are that directory's `prereg.md`.
**Prior vets:** `docs/vets/2026-09-18-pstack-harness-vet.md` recorded `no-comments` and Comment
Sicko as SKIP, covered by `code-slop`, on claim C031 ("same outcomes"). This note measures
that claim and appends a dated correction there. The 2026-11-14 pstack re-vet has no row for
them. The repo names behind section 2 live in a private copy of this note in the operator's
dotfiles `docs/vets/`; here they are R1 to R12.

---

## Headline

- **Models already clean up comment clutter when asked. The gap is that nobody asks.**
  - The bare arm (no skill) removed 12, 12 and 13 of the 13 planted clutter comments and lost
    none of the 20 decision and keep-list facts in all 3 runs.
  - That triggered the pre-registered reading "models do this when asked" (Amendment A item
    3): skills matter only on the six separating items, and the job's gap is routing.
  - The routing gap is measured. 9 of 12 product repos add clutter in their merged pull
    requests (the need rule). Of 130 sessions that opened a pull request, 11 ran
    `ce-simplify-code` (8.5%), and counting hov-stack `code-slop` as well, 13 to 15 ran any
    comment pass (10% to 11.5%).
- **pstack `no-comments` with Comment Sicko: SKIP, because it deletes the comments that
  matter.**
  - It scored 8, 12 and 10 on the separating items (bare: 8, 8, 8).
  - It lost 14, 14 and 13 of the 20 decision and keep-list facts (bare: 0, 0, 0), which is a
    finding against it under the pre-registered countermetric.
  - It kept every keep-list item and deleted the decision comments: 14, 14 and 13 of 14.
    Comment Sicko's keep-list covers licence headers, behaviour forced by an outside
    dependency, justified suppressions, API contract docs and issue links. A decision about our
    own code is not on it.
  - Its step that encodes a constraint before deleting it fires on comments that say "do not
    remove" or "talk to X". That wording appears in 1 of 834 labelled comments from the real
    repos, and that one is a false match. Decisions are 472 of the 831 comment units those
    repos added, so the loss would carry over.
  - The 09-18 SKIP stands, but its reason changes from "covered" to this loss.
- **No skill beat bare without losing facts.**

  | Arm | Separating score | Facts lost |
  |---|---|---|
  | bare | 8, 8, 8 | 0 |
  | comment-ratchet | 7, 7, 3 | 0 |
  | comment-audit-skill | 8, 7, 7 | 0 |
  | code-comments | 9, 7, 7 | 3, 10, 1 |
  | hov-stack `code-slop` | 6, 6, 8 | 0 |

- **CE's `ce-simplify-code`, the incumbent, did not run as designed.** In 3 of 3 runs it
  skipped its reviewer subagents; two reports cite the repo's small size. It is reported as
  not-run, with no verdict on its Comment Reviewer. Its inline path lost 8 to 10 facts per
  run.
- **The one pattern that beat bare is fixing the bug behind a suppression, and it is not
  landed.**
  - The candidate's gain on the separating items came from this pattern.
  - A one-line rule extracting it (arm `a8-extract`) scored 10, 10 and 10, with no decision
    fact lost.
  - It failed its pre-registered pass rule: a keep-list fact was lost in 1 run.
  - The hand-check found two more problems. It broke the fixture script's documented command
    in 3 of 3 runs, and it removed a `noqa: B006` marker while keeping the bug in 3 of 3.
  - Status: proposed, with the measurement that would decide it (4.2).
- **Debt mining, BowTiedDevil's idea, qualifies as an extract.**
  - In one product repo, 20 of 26 excuse comments were confirmed as real, live, fixable and
    untracked debt (77%). The pre-registered bar was 60% and at least 5.
  - Status: proposed. No skill text is ported.
- **A blanket "no new comments" lint, poteto's suggestion, is not viable.**
  - Decision and keep-list comments are 49% to 79% of what each repo that needs cleanup adds;
    the bar was 25%.
  - Commented-out code was 0 of 831 units, so ruff ERA001 would have nothing to catch.
- **Wiring into harness-optimizer: SKIP.** It has no product-code lane.
- **Landed by this PR:** this note, the fixture and a dated correction to the 09-18 note.
- **Proposed for the operator:** one `CLAUDE.md` line asking for a comment pass before
  `gh pr create` (4.2). It is unmeasured, and `CLAUDE.md` is the operator's file.

## 1. Identity, targets and run choices

- **Candidate.**
  - `cursor/plugins` at `ca782ed8b3c2c521cead8e1720d55c3a5dbf2347` (pstack 0.15.48, main on
    2026-11-24).
  - The skill is `pstack/skills/no-comments/SKILL.md`, which dispatches
    `pstack/agents/comment-sicko.md`; both were read in full.
- **Concept.** Six posts, plus the first page of replies across four of their threads (10
  posts; later pages not fetched, see 1.1):

  | Author | Date | Point |
  |---|---|---|
  | poteto | 2026-10-13 | "ban and delete most if not all code comments"; a workaround comment spreads because agents copy it |
  | poteto | 2026-11-20 | "give /no-comments from pstack a try! or better yet, ask your agent to turn it into a lint rule" |
  | Matt Pocock | 2026-11-20 | A prompt that sorts every comment into tautology, excuse, stale, decision and so on |
  | BowTiedDevil | 2026-11-18 | An agent read every comment for workarounds, second sources of truth and hacks, and added 46 cleanups to the backlog |
  | davekiss | 2026-10-27 | Quotes Bun's write-time test: keep a comment only if the next agent "would spend multiple tool calls trying to understand" it |
  | eeuoss | 2026-08-26 | An anecdote that heavily commented files had more defects |

  - Not verified: eeuoss's defect claim has no data.
  - Triaged, not run: Bun's test is about keeping new comments out while writing, which this
    fixture does not measure.
- **Targets.**
  - **T1, the operator's active product repos.** The job is to remove existing clutter and
    keep new clutter out. It is judged by a planted-defect fixture built from the clutter
    shapes measured in those repos: six separating items, 20 facts that must survive, and 13
    clutter comments.
  - **T2, hov-stack skills.** The job is to wire comment discipline into the stack's skills;
    harness-optimizer was named.
- **Install state.**
  - pstack: not installed anywhere.
  - compound-engineering: 3.38.3 installed. `ce-simplify-code` is its comment-pruning path,
    through the Comment Reviewer persona.
  - hov-stack `code-slop`: shipped. Its local note already fences pstack's
    `style-no-hack-scars`.
  - Checked and found not to cover code comments: `kill-ai-slop` (prose and visuals) and
    `thermo-nuclear-code-quality-review`, where "comments" means review comments.
- **Prior verdicts.** Searched the vets folders of this repo and of dotfiles, plus the 2026-08
  vetting index, for every contender's name and upstream. Only the 09-18 pstack row matched.
- **Run choices.**
  - Claude Code 2.1.331; every arm on `sonnet`, 3 runs, unattended.
  - Landing depth: pull request.
  - Ultracode was on, so discovery, classification, the debt pilot and verification ran as
    workflows.

### 1.1 Discovery record

The search seed was the job, "clean up existing code comments and keep new clutter out",
never the candidate's name. The GitHub alternatives lane ran with the name withheld.

**GitHub** (`gh search repos`, `gh api`):

| Cell or pass | Queries or seed | Admitted |
|---|---|---|
| Alternatives (name withheld) | "remove comments skill", "comment cleanup", "stale comments", "AI comments cleanup" | trim-code-comments, comment-audit-skill, comment-tune, toller, DimwitLabs no-comments, windbag, comment-ratchet. Multi-word natural queries returned nothing; 2–3 word queries worked |
| Implementation | "no comments lint", "eslint-plugin no-comments", "comment ratchet", "ratchet lint baseline" | comment-ratchet, comment-budget, Nitjsefnie comment-ratchet, shh, comment-lint; ESLint, ruff and betterer docs read |
| Experience | an issue search for agents leaving excessive comments; "comment ratchet"; "stale comments"; "workaround comments backlog" | Issue searches returned nothing; reported outcomes exist only inside READMEs (toller, comment-lens, slopguard) |
| Pass 1 | seed: comment-ratchet's pre-commit and baseline vocabulary | comment-budget |
| Pass 2 | seed: the alternatives hits' "slop" vocabulary | windbag, stop-ai-slop, eslint-plugin-comment-slop |
| Pass 3 | seed: stop-ai-slop's hook and tree-sitter terms | comment-checker, uncomment, comment-lens, slopguard, silent-code |
| Pass 4 | seed: comment-lens's git-blame and uncomment's issue-key lint | nothing |

- Stop: the pass ceiling, which is incomplete search, not convergence.
- Not searched: GitHub issue search beyond one query, and code search beyond two.

**Web** (`exa-cli` search, `firecrawl-cli` fetch):

| Cell or pass | Seed or scope | Admitted |
|---|---|---|
| Alternatives (name withheld) | 4 natural-language queries for comment-cleanup skills and rules | Avon comment-hygiene, samocode comment-hygiene, roohe cleanup-slop, lukeberrypi remove-dumb-comments, wrxck comment-cleaner, superset deslop |
| Implementation | 4 queries on ban rules, commented-out code, TODO tickets, ratchets; 12 official doc pages read | eslint-seatbelt, suppress-ratchet, alint, eslint-plugin-etc, todo-plz |
| Experience | 4 queries on reported results and complaints | OpenStation A/B summary, DoltHub, Deska, claude-code#85640 maintainer reply |
| Pass 1 | seed: eslint-seatbelt and bulk suppressions | human-first, ban-comments, eslint-plugin-no-comments, ur no-comments |
| Pass 2 | seed: comment-cleaner's comments-only verification | continue stale-comments check, commentlint |
| Pass 3 | seed: TODO and workaround comments to tracked issues | todo-to-issue-action |
| Pass 4 | seed: OpenStation A/B and human-first | nothing |

- Stop: the pass ceiling. Pass 3 admitted one hit, so the two-empty-passes stop did not fire.
- Not searched in depth: Biome and Semgrep comment rules.

**X** (the X API client):

- Read the six posts by id, then searched `conversation_id:` across their four threads. The
  API returned one page of 10 replies; a second page existed and was not fetched.
- One topic query in groups: `(comments OR comment) (agent OR claude OR codex OR llm) (delete
  OR prune OR remove OR ban) (skill OR prompt OR lint)`, from 2026-09-01, by relevance: 10
  posts, none linking a tool. It admitted nothing.
- A reply by tonanywhere in Pocock's thread linked `code-comments`, which was slated.
- Stop: the X spend budget ($0.66 of the $1.00 daily cap used at that point). This is
  incomplete search. The topic query names no candidate, so it was the name-withheld
  alternatives cell. Not searched: the X implementation and experience cells, any X pass, and
  later reply pages.

**Slate**, three deep-vetted contenders. Each is a substitute that covers the whole job:
cleanup, routing debt somewhere, and stopping regrowth.

| Contender | Pin | What it does | Where found |
|---|---|---|---|
| blessedmadukoma/comment-ratchet, `delete-comment` skill plus pre-commit CLI | `15bf5460` (v1.0.0) | Classify, delete clutter, route decisions and excuses out of code, and a pre-commit gate that ratchets a comment baseline | GitHub implementation lane |
| KloutDevs/comment-audit-skill, skill plus POSIX scanner | `86e2ebdf` | Detect and delete, turn TODOs into tracked files, re-run the scanner as an exit-code gate; no baseline | GitHub alternatives lane, name withheld |
| tonanywhere/my-favorite-prompts `skills/code-comments`, run with its `seek-and-destroy` argument | `a235d39d` | Bans comments in source and routes each fact to a name, test, issue, ADR or doc; leaves pragmas, licence headers and config files alone | X thread replies |

Their instructions and executables were read in full before their arms ran. The executables
are `comment_ratchet.py` (385 lines) and `scan-comments.sh` (204 lines), both local-only.

This is the best of the 49 upstreams examined for comment cleanup (3 slated, 41 triaged, 5
dropped). Not searched: GitHub issue
and code search beyond the queries above, and Biome and Semgrep rules in depth. Every other
hit is triaged, not deep-vetted, or dropped, with its reason:

| Hit | Source, lane/pass | Role | Disposition |
|---|---|---|---|
| comment-budget (`github.com/FarisHijazi/comment-budget`) | GitHub, alternatives pass 1 | complement | triaged: ratchet only (percent-of-code budgets); no classification or cleanup |
| trim-code-comments (`github.com/badmuriss/trim-code-comments`) | GitHub, alternatives | complement | triaged: cleanup pass only; no excuse routing, no ratchet; approval-gated |
| comment-tune (`github.com/myoungji-kim/comment-tune`) | GitHub, alternatives | complement | triaged: cleanup with a code-unchanged proof, but it also adds comments |
| no-comments (`github.com/DimwitLabs/no-comments`) | GitHub, alternatives | complement | triaged: cleanup plus write-time guidance; no routing or enforcement |
| toller (`github.com/NolanTrem/toller`) | GitHub, alternatives | complement | triaged: one clutter class (provenance and stale) |
| shh (`github.com/yzlaboratory/shh`) | GitHub, implementation | complement | triaged: TS ban gate with ignore globs only; no keep-list or baseline |
| windbag (`github.com/scale-venture-partners/windbag`) | GitHub, alternatives pass 2 | complement | triaged: lint of history and hedging comments; no baseline in the part read |
| stop-ai-slop (`github.com/WhiteBite/stop-ai-slop`) | GitHub, alternatives pass 2 | complement | triaged: write-time and commit-time style gate; no baseline for old debt |
| comment-checker (`github.com/systemfsoftware/comment-checker`) | GitHub, alternatives pass 3 | complement | triaged: write-time hook; does not clean existing code; Nix-only install |
| uncomment (`github.com/polylint/uncomment`) | GitHub, alternatives pass 3 | complement | triaged: mechanical removal plus tracked-TODO lint; no semantic judgment |
| comment-lens (`github.com/Builder106/comment-lens`) | GitHub, alternatives pass 3 | complement | triaged: stale detection with a baseline; no restatement or removal |
| slopguard (`github.com/mikluko/slopguard`) | GitHub, alternatives pass 3 | complement | triaged: advisory write-time judge |
| silent-code (`github.com/janoppix/silent-code`) | GitHub, alternatives pass 3 | complement | triaged: blunt ban on new comments; no keep-list seen |
| comment-lint (`github.com/gyulbit-tools/comment-lint`) | GitHub, implementation | complement | triaged: report-only lint of deferral and excuse comments |
| eslint-plugin-comment-slop (`github.com/lxmcgvrn/eslint-plugin-comment-slop`) | GitHub, implementation pass 2 | complement | triaged: comment-length limits, not a clutter detector |
| eslint-plugin-no-commented-code (`github.com/fernandotonon/eslint-plugin-no-commented-code`) | GitHub, implementation | complement | triaged: commented-out code in JS/TS (0 such units measured) |
| debt-ratchet (`github.com/Dodai0419/debt-ratchet`) | GitHub, implementation | complement | triaged: excuse ledger with a ratchet, needs a `shortcut:` convention |
| comment-ratchet (`github.com/Nitjsefnie-Actions/comment-ratchet`) | GitHub, implementation | n/a | dropped: enforces a minimum comment share, the opposite goal |
| lean-no-comments (`github.com/rbeauchamp/lean-no-comments`) | GitHub, implementation | n/a | dropped: Lean 4 only |
| flake8-todo-ticket (`github.com/tommilligan/flake8-todo-ticket`) | GitHub, alternatives pass 2 | n/a | dropped: same mechanism as ruff TD003, collapsed into it |
| make-it-lint (`github.com/L4pisLazuli/make-it-lint`) | GitHub, alternatives pass 4 | n/a | dropped: not about comments |
| Avon-Org/comment-hygiene-skill | web, alternatives | complement | triaged: classify-and-delete only |
| yuvasee/samocode comment-hygiene | web, alternatives | complement | triaged: near-duplicate of Avon's, separate upstream; AST check for Python |
| roohe/agentic-super-skills cleanup-slop | web, alternatives | complement | triaged: grep sweep and delete; no routing or ratchet |
| lukeberrypi/skills remove-dumb-comments | web, alternatives | complement | triaged: restatement pass only, human in the loop |
| wrxck/comment-cleaner | web, alternatives | complement | triaged: strongest comments-only safety check seen; no routing or ratchet |
| continuedev/continue stale-comments check | web, pass 2 | complement | triaged: review-time stale check |
| superset-sh/superset deslop command | web, alternatives | complement | triaged: thin prompt that also simplifies code |
| PaulRBerg/agent-skills audit-stale-comments | web, pass 2 | n/a | dropped: only an aggregator copy was readable; the upstream path was not found |
| olistic/eslint-plugin-human-first | web, pass 1 | complement | triaged: CI ban for TS/JS |
| ggofri/eslint-plugin-ban-comments | web, pass 1 | complement | triaged: ban rule with an allow list |
| eslint-plugin-no-comments (npm) | web, pass 1 | complement | triaged: ban rule with an allow list |
| ur no-comments rule | web, pass 1 | complement | triaged: needs the Ur tool |
| justjake/eslint-seatbelt | web, implementation | complement | triaged: per-file ratchet for any ESLint rule |
| motchalini-llc/suppress-ratchet | web, implementation | complement | triaged: ratchets suppression counts across ESLint, Biome, ruff and pylint |
| alint commented_out_code with baseline | web, implementation | complement | triaged: commented-out code (0 measured) |
| cartant/eslint-plugin-etc no-commented-out-code | web, implementation | complement | triaged: commented-out code (0 measured) |
| sawyerh/eslint-plugin-todo-plz ticket-ref | web, implementation | complement | triaged: TODO must carry a ticket |
| alstr/todo-to-issue-action | web, pass 3 | complement | triaged: TODO-to-issue in CI |
| ari-becker/commentlint | web, pass 2 | complement | triaged: sends every comment to a third-party API |
| OpenStation comments A/B (via a stackness.dev summary) | web, experience | n/a | triaged: secondary summary only; not verified |
| DoltHub, "Comments Kill the Vibe" | web, experience | n/a | triaged: anecdote, no measured outcome |
| Deska, "Comment Spam" | web, experience | n/a | triaged: generic, light on results |
| anthropics/claude-code#85640 | web, experience | n/a | triaged: a maintainer reply names agent-instruction text as the supported control |
| Tim Schipper, quality ratchets for AI code | web, implementation | n/a | triaged: background on ratchets |
| Bun's `CLAUDE.md` comment test (via davekiss) | X, concept post | complement | triaged: write-time rule; this fixture measures cleanup, not writing |

## 2. Measured, not inferred

### 2.1 Need: do the product repos add clutter? (pre-registered rule, met)

**Method.**

- Sample: the 25 most recent merged pull requests in each of 12 product repos.
- Units: every block of comment lines the PRs added to code files ("flow"). A stratified
  sample was classified into seven classes:

  | Code | Class |
  |---|---|
  | T | tautology |
  | H | history |
  | S | banner |
  | X | commented-out code |
  | E | excuse |
  | D | decision |
  | K | keep-list: tool-read, licence, API contract, outside constraint |

- A pull request is dirty if it adds at least one T, H, S or X unit.
- A repo shows need if it has more than 5 dirty pull requests and clutter is at least 15% of
  its added units.
- Dirty-PR counts are lower bounds, because units were sampled.

**Validity.**

| Check | Agreement | Kappa | Pre-registered bar |
|---|---|---|---|
| Blind second labeller, 99 units, binary clutter vs not | 85.9% | 0.652 | 80% and 0.6 |
| Same, seven classes | 82.8% | 0.737 | — |
| 20 units hand-labelled by this session | 84.2% against each labeller | — | — |

**Per repo.** Repo names are withheld here.

| Repo | Units labelled | Dirty PRs of 25 | Clutter share | Excuse share | D+K share | Shows need |
|---|---|---|---|---|---|---|
| R1 | 113 | 18 | 50% | 1% | 49% | yes |
| R2 | 94 | 16 | 44% | 3% | 53% | yes |
| R3 | 117 | 14 | 37% | 0% | 63% | yes |
| R4 | 58 | 8 | 34% | 9% | 57% | yes |
| R5 | 68 | 7 | 34% | 2% | 65% | yes |
| R6 | 101 | 11 | 25% | 0% | 75% | yes |
| R7 | 63 | 7 | 24% | 5% | 71% | yes |
| R8 | 68 | 7 | 22% | 3% | 75% | yes |
| R9 | 87 | 9 | 17% | 3% | 79% | yes |
| R10 | 4 | 1 | 100% | 0% | 0% | no |
| R11 | 29 | 4 | 34% | 0% | 66% | no |
| R12 | 29 | 4 | 28% | 3% | 69% | no |

**Result.**

- 9 of 12 repos show need, so fleet need is demonstrated (the bar is 3).
- Pooled flow labels, n=831:

  | D | T | K | H | S | E | X |
  |---|---|---|---|---|---|---|
  | 472 | 192 | 64 | 55 | 29 | 19 | 0 |

- A sample of existing comments ("stock", n=600) has the same shape, with more banners. The
  stock labels were not checked by a second labeller.
- Two consequences for the concept:
  - Decisions are the largest class, so a rule that deletes them fails on real code.
  - Commented-out code does not occur in new work.

### 2.2 Routing: do sessions run a comment pass? (10% to 11.5%)

**Window and scope.** Transcripts from 2026-11-01 to 2026-11-24 in the project folders of the
12 repos, plus one more product repo's folders.

**Count.**

- Sessions that ran `gh pr create`: 130.
- Of those, 11 invoked `ce-simplify-code` (8.5%), 7 dispatched its Comment Reviewer persona,
  and 4 ran hov-stack `code-slop`.
- The count was kept per repo, not per session. The two skills could only overlap in the two
  repos where both ran, so 13 to 15 sessions ran either one.

**Reading.** The pre-registered bar was 50%, so "covered" is asserted, not delivered.

### 2.3 Behavioural fixture: arms, isolation, validity

**Fixture and arms.** The fixture, the arm table and the item definitions are in the fixture
README:

- `tally` 0.9.2, built from `802397d6`.
- 13 clutter comments, 14 decisions (6 with mutants), 6 keep-list items.
- 3 suppressions hiding real bugs (P1 to P3) and 3 workaround comments with fixable causes (W1
  to W3).
- The same task text for every arm, which pre-approves code changes that replace a comment.

**Isolation.** The runner, `run_arm.sh`, does the following:

- Unsets every environment variable except `PATH` and the model-route variables
  (`ANTHROPIC_BASE_URL`, `ANTHROPIC_CUSTOM_HEADERS`, `ANTHROPIC_API_KEY`,
  `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
  `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`), passed by name.
- Then runs:

```
env -u <every other variable> HOME=<run>/home TMPDIR=<run>/tmp XDG_CONFIG_HOME=<run>/xdg-config \
  XDG_CACHE_HOME=<run>/xdg-cache CLAUDE_CONFIG_DIR=<run>/config DISABLE_AUTOUPDATER=1 \
  claude -p "$PROMPT" --model sonnet --max-turns 80 --max-budget-usd 4 --output-format json \
  --allowedTools "Bash,Read,Glob,Grep,Write,Edit,Skill,Agent,TodoWrite" \
  --permission-mode acceptEdits [--plugin-dir <arm plugin>]
```

This is the harness-vet line
`env -i PATH="$PATH" HOME=<scratch>/home TMPDIR=<scratch>/tmp XDG_CONFIG_HOME=<scratch>/xdg-config XDG_CACHE_HOME=<scratch>/xdg-cache <cmd>`,
with the route variables kept so `claude` can reach the model. Section 2.6 covers what those
variables exposed.

**Validity**, decided from each run's transcript before any score was read:

| Arm | Valid runs | Condition |
|---|---|---|
| bare | 3 of 3 | no slash command, no subagent |
| pstack | 3 of 3 | command resolved; `pstack:comment-sicko` spawned |
| `code-slop`, ratchet, audit, routing | 3 of 3 each | command resolved |
| a8 | 3 of 3 | — |
| CE | 0 of 3 | command resolved, but no subagent and no Comment Reviewer prompt; reported as not-run (Amendment A item 5) |

- The a8 runs' own reports echo its wording, which shows the line was loaded.
- **Leak check.** Searched every transcript, subagents included, for scratch paths. The only
  path referenced is the plugin directories, 89 hits. There were zero hits for the grader,
  probes, variants, arm map, grade files, need data and contender sources.

### 2.4 Results (Amendments A, B and C)

Grader fixes (Amendment B) came after the bare runs and before any other arm ran:

- Matching now tolerates a reflowed comment.
- Every separating item scores 0 when checks fail.

The base, a hand-built ideal cleanup and a strip-every-comment variant were re-graded under the
fixed grader:

| Variant | Separating | Lost | Clutter removed |
|---|---|---|---|
| base | 6 | 0 | 0 of 13 |
| ideal | 12 | 0 | 13 of 13 |
| strip every comment | 3 | 17 | 12 of 13 |

| Arm | Separating (max 12) | Median | Facts lost (of 20) | Decision comments gone from their file | Clutter removed (of 13) | Median cost |
|---|---|---|---|---|---|---|
| bare | 8, 8, 8 | 8 | 0, 0, 0 | 0, 0, 0 | 12, 12, 13 | $0.11 |
| pstack `no-comments` | 8, 12, 10 | 10 | 14, 14, 13 | 14, 14, 14 | 13, 13, 12 | $0.19 |
| `code-slop` (hov-stack) | 6, 6, 8 | 6 | 0, 0, 0 | 0, 0, 0 | 12, 12, 12 | $0.08 |
| comment-ratchet | 7, 7, 3 | 7 | 0, 0, 0 | 14, 14, 14 (all moved to ADRs) | 12, 12, 12 | $0.13 |
| comment-audit-skill | 8, 7, 7 | 7 | 0, 0, 0 | 0, 0, 0 | 13, 12, 12 | $0.09 |
| code-comments `seek-and-destroy` | 9, 7, 7 | 7 | 3, 10, 1 | 14, 14, 14 | 13, 12, 12 | $0.15 |
| a8-extract (one line, Amendment C) | 10, 10, 10 | 10 | 1, 0, 0 | 0, 0, 0 | 12, 11, 12 | $0.12 |
| CE `ce-simplify-code` | not-run | — | (observed 8, 9, 10) | (13, 13, 13) | (12, 12, 13) | ($0.15) |

Checks (ruff, mypy, unittest) passed in all 24 runs. Normalised gain over bare is 0.5 for
pstack and a8, -0.5 for `code-slop`, and -0.25 for the three contenders.

**The rule.**

- "Beats the incumbent" cannot be evaluated, because the incumbent is not-run. So no arm is
  SKIP-as-covered.
- Countermetric line (b) is a finding against any skill arm whose median lost exceeds bare's.
  It fires against pstack (14 against 0) and code-comments (3 against 0).

**What each arm did** (read from the diffs and reports):

- **pstack.**
  - It deleted 41 of the 42 decision facts across its runs, plus module docstrings and the
    `budget_for` contract docstring, with nothing in names or tests carrying them.
  - Run e6ba9969's own report: "Deleting the comments also removed two warnings… Nothing in
    the code or tests now enforces either."
  - It root-fixed 15 of the 18 suppression and workaround items (bare: 6 of 18).
  - Run 1bcc7be9 claims it fixed P1. It moved the mutable default into a module-level dict,
    which keeps the shared-state bug. By hand, that run's lost count is 12, not 13, because a
    rename to `RULES_BY_PRIORITY` carries one decision.
  - It lost no keep-list item (`K0` in every run). All three reports say the repo held no
    "do not remove" or constraint comment, so the step that encodes a constraint before
    deleting it never fired.
- **CE.**
  - No run dispatched a subagent. Run ae083cdb's report: "I read the five source files and the
    tests myself rather than dispatching the reviewer subagents, because the repo is only 345
    lines." Run 3f3a8f27: "I did the review inline instead of dispatching subagents, because
    the scope is only about 320 lines." Run 021a6281 gives no reason.
  - Its inline path enforced or dissolved 12 decision facts across its runs and lost 27 of 42.
  - In real sessions it did dispatch its reviewer: 7 of the 11 `ce-simplify-code` sessions in
    2.2 ran the Comment Reviewer. So the skip may be specific to this small fixture. Its
    reviewer is unmeasured here, which is why 4.2 proposes a plain routing line rather than
    "route to `ce-simplify-code`".
- **`code-slop`.** It kept every suppression and workaround as it was (mostly 1s), so it did
  not beat bare on root fixes (median 6 against 8). It lost nothing.
- **comment-ratchet.**
  - It moved every decision into ADR files: 42 relocations, 0 lost.
  - W3 scored 0 in all 3 runs because the date workaround's excuse moved into an ADR or task
    file. The grader scores a W item from Python files only.
  - A labelled post hoc re-reading counts a relocated W excuse as 1. That moves ratchet's runs
    to 8, 7 and 5, and code-comments' runs to 10, 8 and 8. Neither median passes bare's max.
- **code-comments.** 12 facts enforced or dissolved and 19 relocated across its runs, but 14
  lost. W3 went to a `tasks/*.md` file in 3 of 3.
- **a8-extract** (post hoc in origin; Amendment C was written before it ran).
  - Pass rule: median 10 is above bare's max of 8, which passes. Lost 1, 0, 0 fails "0 in every
    run". Checks passed. So the rule was **not met**.
  - The 10s are five items at 2 and one systematic regression. All three runs moved
    `remember`'s mutable default to a module-level dict and dropped `noqa: B006`, keeping the
    bug with its marker gone. That scores P1 = 0, where bare scored 1 in 3 of 3.
  - The lost fact is K2, the `noqa: E402` pair in `scripts/run_digest.py`. All three runs
    treated that legitimate suppression as a bug and removed the `sys.path` insert it exists
    for.
  - `tools/k2check.py` (post hoc, every run, `results/k2check.txt`) ran the documented command
    `python3 scripts/run_digest.py tests/data/export.csv 2026-03 <link>`:

    | Runs | Result |
    |---|---|
    | All other 21 runs, and the base | works |
    | a8, 3 of 3 | fails: once "No such file" (the script moved to `tally/__main__.py`), twice `ModuleNotFoundError: No module named 'tally'` |

  - The grader scored two of those three "kept", because ruff passes on the edited file.
  - `make check` has no test of the script, so nothing in the arm's own checks caught it.

### 2.5 Debt-mining pilot (one product repo, pre-registered rule met)

**Method.**

- A miner swept one repo's comments in three keyword passes and listed up to 30 excuse or
  workaround comments as debt items.
- Pass 1 matched 22,462 lines, mostly code. The comment-only passes matched 1,763 and 576
  lines.
- A refute-by-default verifier checked each item: real, on a live path, fixable by us, and not
  already in an open issue.

**Result.**

| Judged | Confirmed untracked debt | Outside constraint | Already tracked | Dead path |
|---|---|---|---|---|
| 26 | 20 (77%) | 2 | 1 | 3 |

The bar was 60% and at least 5, so the method qualifies as an extract. The items are listed in
the private copy of this note; none was filed.

### 2.6 Isolation caveat: candidate code saw the model key

- Two of the three comment-ratchet runs (f99d1c50, 1ad8252d) ran
  `uvx --from git+https://github.com/blessedmadukoma/comment-ratchet@v1.0.0 check-comments`
  (`--list`, `--init`, `--update`).
- That fetched and executed the contender's CLI inside the arm's environment, which held the
  model-route variables. The third run found no `uvx` entry point to run.
- `comment_ratchet.py` and `pyproject.toml` at that tag were read in full beforehand. The
  module makes no network call, reads no environment variable, and its only subprocess is
  `git ls-files`. The package declares no runtime dependencies.
- What was not read: uvx cloned the whole tag and built it with `setuptools>=69` fetched from
  PyPI. The build backend and the rest of the tag's tree also ran or were available in that
  environment.
- No leak is expected, but the exposure is real. Whether to rotate the key is the operator's
  call.
- Fix for later runs: Claude Code 2.1.331's `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`, which strips
  credentials from the environment of commands an agent runs. It needs `bwrap`, which this
  host has. Not attempted in this vet.

### 2.7 Limits of this evidence

- **One fixture, in Python, with 3 runs per arm, all on sonnet.** No Opus replication.
  - The separating items are 6.
  - A one-item difference is inside the spread for most arms. That is why no verdict here rests
    on a single item.
- **The incumbent's designed path never ran.** A larger fixture that triggers CE's dispatch
  would be needed to judge its Comment Reviewer.
- **The grader has two coverage gaps found by hand,** both reported, neither re-graded:
  - It scores W items from Python files only.
  - Its K2 check does not run the script.
- **Misrouting on tasks that are not about comments was not measured.** Every arm was
  explicitly asked to clean up comments.
- **Routing (2.2) counts invocations, not outcomes.** No arm measures whether a routing line
  would cut the clutter sessions add.
- **The OpenStation A/B claim** rests on a secondary summary and was not verified.

## 3. Verdicts

One row per component and target. Placement "none" means no installation.

| # | Component | Target | Verdict | Placement | Activation | Evidence | State |
|---|---|---|---|---|---|---|---|
| 1 | pstack `no-comments` + Comment Sicko, content | T1 product repos | SKIP: countermetric (b), 14 of 20 facts lost against bare's 0 | none | none | measured, 3 runs (2.4) | not adopted |
| 2 | pstack `no-comments` + Comment Sicko, content | T2 hov-stack skills | SKIP, same reason; nothing to wire | none | none | measured, 3 runs (2.4) | not adopted |
| 3 | pstack delivery: the Cursor plugin under `--plugin-dir` | T1, T2 | SKIP: loads in Claude Code 2.1.331 as is, but its content is SKIP | none | none | load smoke check | not installed |
| 4 | comment-ratchet `15bf5460` (v1.0.0), skill plus pre-commit CLI | T1 | SKIP: did not beat bare (median 7 against 8), 0 lost | none | none | measured, 3 runs; GitHub implementation lane | not adopted |
| 5 | comment-audit-skill `86e2ebdf` | T1 | SKIP: did not beat bare (7 against 8), 0 lost | none | none | measured, 3 runs; GitHub alternatives lane | not adopted |
| 6 | code-comments `a235d39d`, `seek-and-destroy` | T1 | SKIP: did not beat bare (7 against 8); median 3 facts lost, a countermetric finding | none | none | measured, 3 runs; X thread replies | not adopted |
| 7 | CE `ce-simplify-code`, the incumbent | T1 | PARTIAL, not-run. Deciding run: a fixture on which it dispatches its Comment Reviewer | CE 3.38.3 as installed, unchanged | on demand | observed, not scored | unchanged |
| 8 | hov-stack `code-slop`, the incumbent | T2 | keep as is: did not beat bare (6 against 8), 0 lost | `plugins/hov-stack/skills/code-slop/`, unchanged | on demand | measured, 3 runs | unchanged |
| 9 | Root-fix rule, the extracted line | T1, T2 | EXTRACT with an unverified-value marker: pre-registered rule not met | undecided (4.2) | undecided | measured, 3 runs (a8), plus hand-check | proposed |
| 10 | Pocock's taxonomy (T, H, S, X, E, D, K) | T1 | EXTRACT as a measurement instrument; kappa 0.652 binary, 0.737 on seven classes | this fixture's grader and section 2.1 | used by vets only | measured | landed in this PR |
| 11 | Debt mining (BowTiedDevil) | T1 | EXTRACT: 20 of 26 confirmed (77%) against a bar of 60% and at least 5 | an on-demand workflow, location undecided (4.2) | explicit invocation | measured, one repo (2.5) | proposed |
| 12 | Blanket "no new comments" lint or ratchet (poteto) | T1 | SKIP: D+K is 49% to 79% per need repo, against a 25% bar; commented-out code 0 of 831 | none | none | measured (2.1) | not adopted |
| 13 | harness-optimizer wiring | T2 | SKIP: its six lanes (friction, memory, instructions, context, permissions, tooling) include no product-code lane | none | none | read | not adopted |
| 14 | Routing line: ask for a comment pass before `gh pr create` | T1 | proposed with an unverified-value marker: need and coverage are measured, the lever is not | this repo's `CLAUDE.md` (4.2) | always on | inferred from 2.2 and 2.4 | proposed to the operator |
| 15 | The 41 triaged and 5 dropped hits, each with its lane and pass (1.1) | T1 | no verdict | none | none | triaged only | not adopted |

**Rollup.**

| Target | Measured, not adopted | EXTRACTs landed | EXTRACTs proposed | Proposed line | Not-run |
|---|---|---|---|---|---|
| T1, content | pstack, three contenders, blanket lint | taxonomy as instrument | root-fix rule, debt mining | routing | incumbent CE |
| T1, delivery | pstack plugin | — | — | — | — |
| T2 | pstack content, harness-optimizer wiring | — | root-fix rule into `code-slop` | — | — |

T2's `code-slop` stays as is.

### Do-not-retry unless

- **pstack `no-comments` and Comment Sicko:** retry only if a pinned revision keeps decision
  comments about our own code, or moves them into a name, test or doc, instead of deleting
  them. Test: a re-run of this fixture loses at most bare's median.
- **comment-ratchet, comment-audit-skill, code-comments:** retry only if a revision changes
  how it treats suppressions or workarounds. Test: its median on this fixture's separating
  items exceeds bare's max, with 0 lost.
- **CE incumbent:** re-run only on a fixture large enough that `ce-simplify-code` dispatches
  its Comment Reviewer, checked from the transcript before scoring.
- **Blanket lint:** retry only if a re-measure of added comment units shows D+K at or below 25%
  in a given repo, which applies to that repo only. Or if commented-out code shows up in new
  work.
- **harness-optimizer:** retry only if it gains a product-code lane.
- **Root-fix rule:** landed only after a reworded line passes the deciding measurement in 4.2.
- **Routing line:** only on the operator's go, with the measurement in 4.2 attached.

## 4. Changes

### 4.1 Landed by this PR

- This note.
- `harness/vet-fixtures/no-comments-2026-11/`: the fixture, the grader, the runners, the
  pre-registration, results for all 24 runs and the analysis tools. Contender texts are not
  committed; they are pinned in the README.
- A dated correction appended to `docs/vets/2026-09-18-pstack-harness-vet.md`, at C031 and the
  `no-comments` row.

### 4.2 Proposed, not landed

**Routing line (row 14), unmeasured.**

> Before `gh pr create`, reread the comments your diff adds: delete narration, history and
> banners; keep a comment only for a reason the code cannot show.

- File: this repo's `CLAUDE.md`, which is the operator's global `~/.claude/CLAUDE.md`.
- Why: bare models already do this well when asked (2.4), and at least 88.5% of
  pull-request sessions never ask (2.2).
- Provenance: this vet's bare arm. No upstream, no pin, no local adaptation.
- Update owner: the operator.
- Rollback: delete the line.
- Deciding measurement: a feature task on this fixture (not a cleanup task), run with and
  without the line, 3 runs each. Count the T, H and S units each arm adds and the facts it
  loses.
- Edits to `CLAUDE.md` need the operator's go, so this is left for the operator.

**Root-fix rule (row 9), reworded after the a8 hand-check, unmeasured.**

> When you clean up comments, a suppression that hides a correctness rule (an unused result, a
> mutable default, an ignored type error) is a bug report: fix the cause and remove the
> suppression with it, or leave both. Keep a suppression whose cause is layout or tooling.
> Keep comments that give a reason the code cannot show; delete narration, history and
> banners.

- Provenance: pstack `no-comments` step 4 and Comment Sicko's suppression rule at `ca782ed8`,
  and Pocock's "excuse" class.
- Local adaptation: the a8 wording (`arms/a8-extract/CLAUDE.md`), reworded as quoted above
  after it broke a documented command and dropped a marker.
- Files, if it passes: a comment rule under `plugins/hov-stack/skills/code-slop/rules/` with
  its `SKILL.md` index line, or this repo's `CLAUDE.md`.
- Update owner: hov-stack.
- Rollback: revert that PR.
- Deciding measurement: run it alone on a fixture with suppression and workaround items it
  was not written against. That fixture should include more legitimate suppressions and a test
  that runs any script entry point. Run 3 times.
  - Pass: median above bare's max, 0 lost in every run, and every documented command still
    works.

**Debt mining (row 11), an on-demand workflow.**

- Method: a miner lists excuse comments; a refute-by-default verifier keeps those that are
  real, live, fixable by us and untracked. This is the method that scored 77%.
- Provenance: BowTiedDevil's post of 2026-11-18. No upstream code, no pin.
- Files: undecided. It belongs with hov-stack's other explicitly invoked workflows, not in
  always-on text.
- Update owner: hov-stack.
- Rollback: delete the workflow.
- The 20 confirmed items from the pilot are in the private note. Filing them is the operator's
  call.

## 5. Shared versus target findings, prior notes, dropped hits

**Shared findings,** true of the artifact whatever the target:

- pstack loses decision facts.
- None of the three contenders beat bare on root fixes (medians 7 against 8).
- comment-ratchet's CLI is fetched at runtime.
- CE skips its persona on a small repo.

**Target-specific:**

- T1: need and routing (2.1, 2.2), the D+K share against a blanket lint, and the debt pilot.
- T2: the wiring rule.

**Prior notes:**

- 09-18 C031 ("code-slop and Comment Sicko produce different outcomes on the same diff",
  REFUTED on flagging): on full cleanup behaviour they differ. `code-slop` scores 6, 6, 8 with
  0 lost; pstack scores 8, 12, 10 with 13 to 14 lost.
- The 09-18 row's SKIP stands, for that reason, not "covered".

**Searched with no match:** dotfiles `docs/vets/`, this repo's `docs/vets/`, and the 2026-08
vetting index.

**Dropped hits** are in 1.1 with their reasons.

## 6. Audit dividend, triggers and spend

**Audit dividend.**

1. **Routing, not doctrine, is the clutter gap.**
   - The stack ships two comment-capable skills, and 10% to 11.5% of pull-request sessions
     use either.
   - Bare models clean up well when asked, so a line that asks may beat any skill. Section 4.2
     names its measurement.
2. **`ce-simplify-code` skipped its own reviewers on this small fixture.**
   - In real sessions it dispatched the Comment Reviewer in 7 of 11, so the skip is not shown
     to carry over.
   - Its inline path deleted 27 of 42 decision facts on this fixture.
   - Worth an issue upstream with compound-engineering. Not filed: an outbound write this vet
     was not asked for.
3. **`code-slop` points to `technical-debt`, a skill hov-stack does not ship.**
   - The pointers are `SKILL.md:18`, a link to `../technical-debt`, and
     `rules/comments-placeholder.md:126`.
   - `UPSTREAM.md:34` records that the sibling skill was deliberately not ported.
   - Both are dead pointers. Flagged, not fixed here.
4. **Vet runners pass the model key to every command an arm runs.** This runner does, and so
   do those of `pstack-2026-11`, `build-design-2026-11` and `learn-taste-2026-11`: each keeps
   `ANTHROPIC_API_KEY` and the other route variables. `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` (2.6) is the candidate fix for
   the shared runner. Proposed; it changes an isolation surface.
5. **Grader lessons for the next comment fixture.**
   - Score relocated excuses in `.md` files.
   - Test every documented entry point.
   - Keep more legitimate suppressions as controls.

**Triggers to re-audit:**

- a new pstack revision of `no-comments`;
- CE dispatching its Comment Reviewer on small diffs;
- hov-stack adding a comment rule to `code-slop`;
- a routing line landing in `CLAUDE.md`, which re-runs 2.2's count a month later.

**Spend.**

| Item | Cost |
|---|---|
| Arm runs, 24 | about $3.06 |
| — bare | $0.32 |
| — pstack | $0.58 |
| — CE | $0.44 |
| — `code-slop` | $0.25 |
| — ratchet | $0.41 |
| — audit | $0.26 |
| — code-comments | $0.44 |
| — a8 | $0.36 |
| Load smoke checks | about $0.01 |

The session's own model use (discovery, classification, the debt pilot and verification
workflows) is not itemised.
