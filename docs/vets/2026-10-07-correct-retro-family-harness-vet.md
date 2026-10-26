# Harness vet: pstack `/correct` and the correction-loop family

**Date:** 2026-10-07
**Ask (operator):** "we don't have anything like [/correct, /retro, poteto's correction
hierarchy, aihero skills-retro, doodlestein agent-ergonomics] in our harness yet or our
stack ... /harness-vet and figure out if we want to cherry-pick into our own bespoke
uberskill or depend on one of these ... We do have /papercut which maybe this gets added to."
**Tracking:** issue #1677, branch `correct-retro-family-vet`.

**Candidates (one deep vet, five triaged):**

1. **DEEP** `/correct` — cursor/plugins `pstack/skills/correct/SKILL.md` @ `9511e60321f7`
   (PR #494, merged 2026-10-03, pstack 0.15.7; pstack is 0.15.15 today). 2,445 B, prose only,
   `disable-model-invocation: true`, MIT (Lauren Tan; licence verified from the vendored
   `create-verification-skill/LICENSE`). sha256 `bf482bac…c904`.
2. `/retro` — mattpocock/skills `skills/engineering/retro/SKILL.md` @ `a7d038f6bf7f`
   (2026-09-24 "Graduate pr and retro to engineering"). **Byte-identical** to the revision
   SKIP'd on 2026-09-20 (`c55ee46`, `docs/vets/2026-09-20-retro-harness-vet.md`).
3. poteto correction hierarchy — x.com/poteto/status/2089067865098113024 (2026-08-16),
   quote-tweeted 2026-10-04 (2106542593656111276) announcing `/correct`.
4. pstack `principle-encode-lessons-in-structure`, `reflect`, `architect` — siblings of
   `/correct`; all SKIP'd or EXTRACT-parked in `docs/vets/2026-09-18-pstack-harness-vet.md`.
5. aihero.dev/skills-retro — Pocock's documentation page for `/retro` (fetched 2026-10-07,
   paraphrased), plus the andrestaltz endorsement (2106708022676389916).
6. doodlestein `agent-ergonomics-and-intuitiveness-maximization-for-cli-tools` — jsm id
   `8def1827-be6e-4e1f-be53-f0330afde2b3`, v18 (2026-09-26, sha256 `318d8967…e2eb`),
   proprietary. Already **distilled** into `skills-local/cli-agent-ergonomics/` on
   2026-07-04 from v11 (`retired-skills.txt:28`).

**Targets vetted:** two — **H**, this harness (`~/.claude` + `~/.codex` via skills-local;
sections 2.2 and 2.3 speak to it) and **P**, the product repos agents work in (`~/SITES/*`;
the fixture in 2.1 is shaped like one).
**Concrete task:** *given a repo (or this harness) where agents keep being corrected for the
same mistakes, find the repeated classes from history and corrections, and fix each at the
highest structural level that works, proving each new check fails on a real past instance.*
**Landing depth:** report, fixture artifacts, one provenance line. Nothing installed; no skill
added, removed or re-pinned; no behaviour-shaping text landed in any always-loaded file.
**Run choices:** ultracode on, so the Read / Sweep / Fixture / Verify phases ran as one
Workflow (`wf_ac8e5a6c-e25`, 21 agents: 5 readers, 3 sweep readers + 1 cluster judge + 3
enforcer verifiers, 1 fixture builder + 1 arm runner + 2 blind graders, 5 claim verifiers).
Readers and verifiers on `sonnet`; cluster judge, fixture builder and graders on the session
model (Fable 5.1). Default verdict for every claim was REFUTED.

---

## 1. Headline

**SKIP the family as a dependency and as a bespoke uberskill. EXTRACT two mechanisms as
proposals. papercut stays friction-only.**

- **The skill does not change the core outcome.** Given one sentence of task ("the operator
  keeps correcting the agents ... for the same mistakes ... change the repository so that it
  stops happening"), a bare sonnet found all three planted classes, asserted no false class,
  left the already-enforced control alone and fixed each class at the same level the
  `/correct` arm did: 9 of 9 arms identical on every one of those columns, two blind graders
  in full agreement.
- **What `/correct` adds is procedural, at about 37% more per run (median).** Only its arms
  wrote a rule-to-enforcer table (3/3 vs 0/6), cited evidence SHAs (3/3 vs 0/6, two with a
  citation error), proved a check against the real historical instance rather than a
  throwaway file (2/3 vs 0/6), and landed a status-list check keyed on content rather than
  variable name, so the re-planted literal list was caught (3/3, vs 1/3 house doctrine and
  0/3 bare). Two of the three also built exception machinery nobody asked for. At n=3 the
  re-plant effect is suggestive, not established.
- **The premise holds in this harness, but not where `/correct` could act on it.** Of 20
  clusters of repeated operator corrections, 1 has a confirmed blocking enforcer, 10 are
  partial, 9 are prose. The five largest (51 of 141 notes, carrying 66 of the 142 corrections) are verification-discipline
  behaviours with no blocking enforcer. `/correct`'s own ladder routes judgement behaviours
  to prose, which is where they already sit. Two notes cite enforcer scripts that exist
  nowhere in the repo and two cite stale values; that is the one mechanical gap the data
  supports.
- **`/retro` SKIP stands** (byte-identical to the vetted revision; the author's own FAQ names
  the failure modes the 2026-09-20 fixture measured). poteto's tweet, the aihero page and the
  pstack siblings add no mechanism beyond `/correct`. The doodlestein skill is a remediation
  playbook, already distilled here; only its provenance line needed updating.
- **Cherry-picks, as proposals (section 3):** (a) a repo-scoped "cited enforcer exists" check
  in `memory-audit.py`, consumer `harness-doctor`; (b) one sentence making the planted-negative
  requirement name a real past instance. Neither is landed by this PR.

---

## 2. Measured, not inferred

Runtime: Claude Code 2.1.293, WSL2, session model Fable 5.1. Arm runs used `--model sonnet`,
`--max-turns 60` (raised from the prior fixture's 35 because this task commits code, not
only a report), `--permission-mode acceptEdits`, each under its own `CLAUDE_CONFIG_DIR` so
no arm inherited the operator's live skills, plugins or settings. Isolation was that fresh
config dir, not the `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` switch, because a3's treatment is
itself a `config/CLAUDE.md`; no `CLAUDE.md` exists in any ancestor directory of the arm paths
(checked after the run, not probed during it). Fixture, sealed key,
runner, all nine graded trees' reports and both grader reports:
`harness/vet-fixtures/correct-2026-10/`.

### 2.1 Behavioural comparison (3 arms x 3 trials)

Fixture `ledgerline`: a 24-commit Python 3 stdlib invoicing repo with real git history (three
authors, fixed dates 2026-08-03..09-29, review-style fix messages such as "third time this
month the lists drifted"). Planted: **three repeated classes** — C1 hand-synced status list
(introduced 3x, fixed 3x), C2 money as float (2x/2x), C3 importing `storage._db` past the
`repo` boundary (2x/2x) — plus **one one-off decoy** (D1 pagination off-by-one, once), **one
already-enforced control** (E1 "no print() in src/", rule + `scripts/check.py` lint + CI, never
recurred) and **one judgement-call control** (J1 test naming, no history). `AGENTS.md` states
a prose rule for C1/C2/C3 that nothing enforces. `make check` passes at HEAD. Blinding scan
over fixture content, paths and commit messages: 0 hits for eval/judge/rubric/score/compare/
benchmark/candidate/arena and 0 for the five skill-vocabulary phrases.

Arms differ only in what the per-arm config dir holds and a leading slash token:

| arm | loads | prompt |
|---|---|---|
| a1 bare | nothing | task body |
| a2 `/correct` | `config/skills/correct/SKILL.md` (candidate, verbatim) | `/correct` + blank line + task body |
| a3 house doctrine | `config/CLAUDE.md` with the two global-rules lines on full scope and root causes | task body |

Task body (identical): *"You are working in the repository at ./repo. It is a small Python
service. The operator keeps correcting the agents who work in this repository for the same
mistakes. Look through the repository and its history, work out what keeps going wrong, and
change the repository so that it stops happening. Make your changes as commits in ./repo.
Finish by telling me what you found, what you changed, and why."*

Unblinded results (mapping `arm-outputs/mapping.tsv`; L1 architecture, L2 lint/type check,
L3 test, L4 docs; "real" prove-it = the check was shown failing on a historical commit or
replayed pre-fix source, not on a throwaway file; turns, wall s and USD are each arm's
`result.json` fields `num_turns`, `duration_ms` rounded to seconds and `total_cost_usd`,
copied by script to `arm-outputs/timing.json`):

| arm | run | classes | false | fix levels landed | rule table | SHAs cited | real prove-it | P4 re-plant | collateral | turns | wall s | USD |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| a1-1 bare | r06 | 3/3 | 0 | C1 L1 (no backstop); C2 L2; C3 L2 | no | no | no | PASSES | check green | 7 | 35 | 0.129 |
| a1-2 bare | r04 | 3/3 | 0 | C1 L1+L2 (name suffix); C2 L2; C3 L2 | no | no | no | PASSES | check green; stale comment left in export.py | 5 | 20 | 0.100 |
| a1-3 bare | r08 | 3/3 | 0 | C1 L1+L2 (exact name); C2 L2; C3 L2 | no | no | no; no verification step described | PASSES | check green | 6 | 33 | 0.123 |
| a2-1 `/correct` | r05 | 3/3 | 0 | C1 L1+L2+L3; C2 L2; C3 L2 | yes | yes (one SHA misattributed) | **yes** (replayed pre-fix src) | CAUGHT, names fix | check green; AGENTS.md describes an exception format `check.py` does not parse | 7 | 37 | 0.246* |
| a2-2 `/correct` | r02 | 3/3 | 0 | C1 L1+L2+L3; C2 L2; C3 L2 | yes | yes (one count wrong) | no | CAUGHT, names fix | check green; stale rule removed | 7 | 35 | 0.135 |
| a2-3 `/correct` | r09 | 3/3 | 0 | C1 L1+L2+L3; C2 L2+L3 (replay tests); C3 L2+L3 | yes | yes | **yes** (replay tests of past mistakes) | CAUGHT, names fix | check green; unrequested allow-comment exception mechanism with expiry, tested; 2 commits | 7 | 44 | 0.168 |
| a3-1 house | r01 | 3/3 | 0 | C1 L1+L2 (literal list); C2 L2 (3 files); C3 L2 | no | no | no | CAUGHT, names fix | check green | 7 | 37 | 0.238* |
| a3-2 house | r03 | 3/3 | 0 | C1 L1+L2 (name); C2 L2 (2 files, also bans Decimal); C3 L2 | no | no | no | PASSES | check green | 8 | 37 | 0.152 |
| a3-3 house | r07 | 3/3 | 0 | C1 L1+L2 (name); C2 L2; C3 L2 | no | no | no | PASSES | check green | 6 | 28 | 0.128 |

\* First trial under a fresh config dir wrote 42-45k cache-creation tokens (the other seven
14-20k), so means overstate a2 and a3. Means: a1 $0.117, a2 $0.183, a3 $0.172. **Medians:
a1 $0.123, a2 $0.168 (+37%), a3 $0.152 (+23%).** Every arm: model `claude-sonnet-5-5`
(`modelUsage`), Bash the only tool, P1 IMPOSSIBLE, P2/P3/P5 CAUGHT, E1 left alone, 0 extra
real findings.

Per arm:

| | bare a1 | `/correct` a2 | house a3 |
|---|---|---|---|
| classes found | 9/9 | 9/9 | 9/9 |
| false classes (D1, J1, E1-as-unenforced, other) | 0 | 0 | 0 |
| C1 at L1, C2 at L2, C3 at L2 | 3/3 each | 3/3 each | 3/3 each |
| rule-to-enforcer table written | 0/3 | **3/3** | 0/3 |
| evidence SHAs cited in the report | 0/3 | **3/3** (2 with an error) | 0/3 |
| check proven on a real past instance | 0/3 | **2/3** | 0/3 |
| P4 literal status-list re-plant caught | 0/3 | **3/3** | 1/3 |
| unrequested exception machinery or format | 0/3 | 2/3 | 0/3 |
| median cost / turns | $0.123 / 6 | $0.168 / 7 | $0.152 / 7 |

Scored blind by two independent graders against the sealed key, outputs relabelled
`r01..r09` in shuffled order with the mapping withheld. Each grader re-ran `make check` on
every tree and then **re-planted five past mistakes** (P1 add a status in one place only;
P2 float late fee in pricing; P3 import `storage._db` from api; P4 second status-list copy in
export; P5 float formatting in export), classifying each as IMPOSSIBLE / CAUGHT (and whether
the error names the fix) / PASSES.

**Grader agreement.** Identical on classes found, false classes, E1 handling, extra
findings, `make check` at head, rule-table presence, fix level per class and all 45
arm-by-plant outcomes. They differ on one column only: whether the P2/P5 float-check error
"names the fix". Grader two marks all nine as naming it (the message says integer cents);
grader one marks only the four whose message names `pricing.tax_cents` (r02, r04, r05, r09).
Nothing in section 3 rests on that column. Grader one additionally noted r05's SHA
misattribution and r02's miscount; grader two noted r05's unparsed exception format.

Validity checks, run before scoring (`arm-outputs/runner-validity.json`):

- All nine arms exited 0 in 5-8 turns with one commit each (a2-3 two), far under the 60-turn
  cap.
- Prompt diff a1 vs a2 is the `/correct` line plus a blank line. a3's config holds the two
  CLAUDE.md lines verbatim and nothing else.
- Skill phrase "highest level that works" appears in a2 transcripts only (3/3); house phrase
  "one guard in the shared function" in a3 only (3/3); neither crossed arms.
- Identity strings in the graded reports: `/correct` and `CLAUDE.md` occur 0 times in all
  nine `report.md` files (`skill` and `pstack` also 0). Graders saw reports and trees only.
- Blinding did **not** hold on report content for a2. Over the eval word list
  (`tools/scan-words.txt`) the three `/correct` reports carry the skill's own vocabulary
  (r02 two lines, "the highest level" and "a table pairing each rule with what enforces it";
  r05 one; r09 two, one of them the substring `score` in `underscore`); the other six carry
  none. A grader who knew the candidate could place those three. The tell is the measured
  delta itself (the rule table is a scored column), so it is disclosed, not scrubbed; both
  graders' notes record "Rule table" as a scored axis.
- Blinding word scan over prompts, arm paths and run paths: 0 hits.
- `--max-turns 35 -> 60` is the only runner change (grep: one match).
- Both graders ran `make check` at every graded head (9/9 green) and re-planted on copies.
- Not isolated: the global git identity, so arm commits carry the operator's name and a
  `Co-Authored-By` trailer. Cosmetic; no arm read it.

### 2.2 Need measurement: does this harness have repeated, unenforced corrections?

The candidate's premise is that operators correct agents for the same thing more than once
and that the fix should move up to an enforcer. Measured here against the only place this
harness records operator corrections of agent behaviour: the 141 `feedback`-type memory notes
in `memory/-home-user-hov-stack/` (`rg -l '^  type: feedback'`; the digest's 144 was a
count of a different listing).

Three readers extracted every note (topic, correction, verbatim repeat signal, enforcer the
note itself names). A cluster judge grouped notes correcting the same behaviour in substance.
Three verifiers then checked, default REFUTED, whether each cluster's behaviour is **enforced**
(a blocking hook, a failing test, a deny/ask permission rule, a CI step, a refusing script)
or lives only in prose.

| measure | value |
|---|---|
| feedback notes | 141 |
| notes carrying an explicit repeat signal ("again", "third time", "hit again 2026-09-03", "why do you keep making me…") | 38 |
| notes that themselves name an enforcer | 34 |
| clusters of >=2 notes correcting the same behaviour | 20 (110 notes carrying 142 corrections; a note can carry more than one); 31 singletons |
| clusters whose notes claim an enforcer exists | 15 of 20 |
| clusters where a verifier CONFIRMED a blocking enforcer | **1** (cluster 16, `launchpad-freshen.sh:105-138`) |
| PARTIAL (advisory, warn-only, partial coverage, or the automation exists but nothing stops the behaviour) | **10** |
| REFUTED (prose only) | **9** (5 whose own notes said prose-only; 4 that claimed an enforcer) |
| claimed enforcers that exist nowhere in this repo | **2 verified gone + 1 unresolved**; plus 2 stale values and 1 unrelated citation (below) |

Citations I re-checked myself at the cited lines after the verifiers reported them:

- `merge-semantics-check.sh` (cited in `pr-scope-check-needs-three-dot-diff.md`, which itself
  says it lived in a 2026-08-29 job tmp dir) and `cr-compact.py` (cited in
  `derive-compact-review-returns-from-artifacts-not-by-retyping.md`): `fd -H` finds neither
  outside `memory/`. **Gone.**
- `check-migration-code-coupling.mjs` (cited in `a-gate-that-cannot-compare-must-fail.md` and
  a second product-repo vet note, both about product repos): not in this repo; the
  verifier did not search those repos. **Unresolved, not phantom.**
- `CLAUDE_LOOP_MAX=300` (`loop-guard-hard-stop-stranded-near-complete-work.md`):
  `loop-guard.js:76` defaults to 300 but `claude-loop.sh:1193` exports 1000, so loop runs get
  1000. **Stale.**
- `index_over_cap` (`feedback_memory_dream_index_budget_discipline.md`): the key is
  `index_over_budget` (`memory-audit.py:832,891,923`). **Stale.**
- `sync-install-smoke.test.sh:534-543` as the enforcer of "label measured vs inferred": lines
  525-543 test the push bypass-policy refusal, not `rent-check inventory --strict`.
  **Unrelated.**

| # | cluster (corrections) | kind | claimed | verifier | what exists |
|---|---|---|---|---|---|
| 1 | Prove tests and guards are not vacuous (15) | behaviour | enforced | REFUTED | cited `.mjs` is for product repos; none of the 16 PreToolUse hooks checks vacuous tests |
| 2 | Validate probe and report scope before trusting absence or counts (15) | behaviour | enforced | PARTIAL | `proc_liveness.py` excludes own PID, exits 2 on unreadable procfs, tested; one probe, not the reporting behaviour |
| 3 | Verify PR/CI/merge status against live gate output before reporting green (13) | behaviour | enforced | REFUTED | cited script gone; nothing checks the report |
| 4 | Label measured vs inferred; report only observed state (12) | behaviour | enforced | REFUTED | cited test range unrelated; rent-check not referenced in tests or bin |
| 5 | Workflow/subagent orchestration pitfalls (11) | behaviour | enforced | PARTIAL | `cr-compact.py` gone; `fanout-admission.js` warn-only; structured-output guard covers one facet |
| 6 | Never hand the operator commands or the merge (10) | behaviour | enforced | PARTIAL | `wt-done.sh`, `wt-sweep.sh` exist as mechanics (`wt-sweep` defaults `DRY_RUN=1`); nothing stops handing back |
| 7 | Guard/hook/dcg false positives and workarounds (9) | friction | enforced | PARTIAL | `git-guard.js:517-537`, dcg contract `expect-blocked.txt:51`, worktree-shapes tests; the guards fire, the workarounds are prose |
| 8 | Merge is not deploy: verify live checkout target (7) | behaviour | enforced | PARTIAL | `sync.sh:686-697` refuses a missing hook target (blocks); SessionStart heal and doctor 8c advisory |
| 9 | Shell-parsing guard authoring fails closed (6) | behaviour | enforced | PARTIAL | each named guard exists with CI tests (`harness-tests.yml:2110`); nothing enforces fail-closed on a *new* guard |
| 10 | Stop over-investing in advisory review; ship capability (6) | behaviour | enforced | REFUTED | ESLint bulk suppressions are a product-repo tool, not here |
| 11 | Bash scripting pitfalls (5) | friction | prose | REFUTED | shellcheck test for bin scripts only (`test_harness_test_registration.py:162`); none of the named traps |
| 12 | Inspect before deleting or replacing (5) | behaviour | prose | REFUTED | no hook requires inspection first |
| 13 | Memory-dream consolidation lessons (5) | fact | enforced | PARTIAL | `memory-audit.py` WARNs at >=70% of the index cap; advisory |
| 14 | Slash-skill mention expands only in first position (4) | behaviour | enforced | PARTIAL | `skill-mention-resolver.js` registered (`settings.json:871`), tested in CI; injects a note, blocks nothing |
| 15 | claude-loop ceiling and silent-failure detection (4) | fact | enforced | PARTIAL | `loop-guard.js:618` hard-stops; the claimed 300 is stale |
| 16 | Check git status before pulling in a launchpad (3) | behaviour | enforced | **CONFIRMED** | `launchpad-freshen.sh:105-138` refuses in-progress, modified or unpushed launchpads |
| 17 | gh CLI pitfalls (3) | friction | prose | REFUTED | `git-guard.js:135,164` *recommends* `--delete-branch`, the opposite of guarding it |
| 18 | Prod daemon restart needs separate merge and deploy confirmations (3) | behaviour | prose | REFUTED | `runner-guard.js:6-17` covers CI runner units only |
| 19 | Vet skills one by one; retire vs demote (3) | behaviour | prose | REFUTED | judgement guidance only |
| 20 | Register new test suites and manifest entries explicitly (3) | behaviour | enforced | PARTIAL | `test_harness_test_registration.py:182,203,220` fail on unregistered or duplicate suites (CI :2072); the manifest half is not checked |

Reading of the table: `/correct`'s premise, "a rule with no enforcer repeats", is true in this
harness. The five largest clusters, 51 of 141 notes carrying 66 of the 142 corrections, all correct verification discipline
(don't call a vacuous test proof, don't trust a probe you haven't scoped, don't report green
without live gate output, label measured vs inferred), and none has a blocking enforcer
covering the corrected behaviour: three REFUTED, two PARTIAL on a side facet. Fourteen of the
fifteen "enforced" claims are partial or wrong, and five of the 34 enforcer citations point at
files, lines or values that are not what the note says. **But the clusters at the top are
judgement behaviours.** `/correct`'s own ladder (`SKILL.md:19-22`) sends those to its lowest
rung, prose rules, which is where they already live; the rungs it would climb to
(architecture, types, lint) have no purchase on "report only what you observed". The one thing
the table supports mechanically is a check that a note's cited enforcer exists (section 3).
Clusters 1-3 are also consolidation candidates for memory-dream, which is a memory job, not
a new tool.

Two cross-checks on the other correction stores:

- **papercut** has 12 families on this box (4 adopted, 6 disposed, 1 escalated, 1 active) and
  its 90-day top signatures are all guard blocks (git-guard, worktree-isolation refusals,
  structured-output schema mismatch, read ceiling, grep-cost-guard). Every one is a tool or
  environment failure; **none is an operator correction of agent behaviour**. That matches
  its charter (`skills-local/papercut/SKILL.md:16-24` limits the voluntary class to
  friction with no error signature) and the verifier's REFUTED on "papercut captures operator
  corrections".
- **memory doctrine** on duplicates says "Update that file rather than creating a duplicate".
  No script or doctrine escalates a second correction to an enforcer (REFUTED, verifier
  searched CLAUDE.md, HARNESS.md, `harness/*.md`, skills-local SKILL.md files,
  `memory-audit.py`, `memory-mine`, `memory-dream`). `memory-audit.py` scores structure only
  (`score_note` :660-686); its "duplicate" checks are frontmatter names and descriptions.
  memory-dream's "demotion" is index tiering, not enforcement.

### 2.3 Incumbent coverage, mechanism by mechanism

Per `/correct` mechanism, the covering mechanism on this harness and its control surface, or
NONE. Each row was read at the cited line by the incumbent reader or a verifier.

| `/correct` mechanism | coverage | covering mechanism and control surface |
|---|---|---|
| Mine commits, reverts, review comments and instruction files for repeated mistake classes | **NONE** | papercut ranks by distinct sessions (`papercut.py:15-21`; `papercut list/rollup/triage`) but ingests tool failures and voluntary friction only. No git-history, revert or commit-message miner exists under `bin` or `scripts`. |
| Class threshold "happened twice" | NONE for corrections | papercut's `>=3 sessions AND >=3 occurrences` (`papercut.py:1533-1536`, defaults :4158) is the analogue, for friction. Memory has no counter. |
| Fix at the highest level that works (architecture > types/lint > tests > docs) | PARTIAL, pointed at a different object | rent-check RUBRIC E2 (`RUBRIC.md:185-191`, via `/rent-check`) routes **context-file rules** to the *cheapest* deterministic layer and has no architecture rung. papercut's `## Cheapest remedy` (`papercut.py:366`, template :854) is an unordered prose slot checked for non-emptiness only (:786). CLAUDE.md's root-cause rule is prose. |
| Prove each new check fails on a real past mistake | PARTIAL, never as one step | papercut `## Planted negative` is required non-empty only (`papercut.py:369`; `work-spec-check.sh`). HARNESS.md:49's git-guard replay-against-60-days doctrine is the real precedent, for git-guard rules only. |
| Same command locally and in CI | repo property | `harness-tests.yml` names every suite explicitly; comment :1100 "A suite on disk is not a suite in CI" is documentation of the hazard, not a failing step (verifier PARTIAL). |
| Exceptions carry reason, expiry, approver | **NONE** | git-guard escapes (`ALLOW_MAIN_COMMIT=1` etc.) are a boolean check (`git-guard.js:225-231`); no reason, expiry or approver is recorded (REFUTED). papercut `family dispose` has a verdict but no expiry or approver. |
| Rule-to-enforcer table in the agent instruction file | PARTIAL | rent-check E1 (`RUBRIC.md:179-184`) classifies rules per audit run, not persisted. HARNESS.md:44-49 is a prose-to-enforcer map for one section by design (:46 "Do not transcribe entries into prose"). No table anywhere (REFUTED (d)). harness-doctor has no rule-without-enforcer check (REFUTED (e), 34 sections read). |
| "Rule exists with no enforcer = repeat, escalate in the same change" | **NONE** | Memory doctrine does the opposite (update in place). rent-check PROMOTE exists (`SKILL.md:202`) but has no repeat trigger and never reads feedback notes. |
| Drop rules once impossible | PARTIAL | rent-check CUT/DEMOTE and E1 "redundant: prune the prose", proposal-only, periodic. |
| Re-run on every operator correction | **NONE** | No SessionEnd hook (`jq` of settings.json); the one UserPromptSubmit hook is `skill-mention-resolver.js`, not a correction detector. papercut SKILL.md:378-384 says session mining runs "only when asked". |

Under the standing rule, this is **not** a SKIP-as-covered case: no equivalent capability for
the concrete task is callable on this harness. Whether it is a demonstrated *need* is what
2.1 and 2.2 measure.

### 2.4 Claim ledger (refute-by-default verifiers, sonnet)

Candidate claims:

- **REFUTED** — PR #494 shows `/correct` beats a bare model. Its two arms were "raw prompt"
  vs "skill" (same doctrine, n=1 each, Opus 5.5, author-built 17-commit repo); there was no
  no-doctrine arm. Outcome was parity. The PR body is itself agent-written.
- **CONFIRMED** — no execution surface in `/correct` (no command, URL, script, fetch or
  self-update; :26 "run the same command locally and in CI" names no command). It is still a
  repo-writing procedure: it tells the agent to make architecture changes and commits.
- **CONFIRMED** — `disable-model-invocation: true` (`SKILL.md:4`); class threshold "A class
  counts once it has happened twice" (`:15`).
- **REFUTED** — poteto's four levels and `/correct`'s ladder are "the same ordering".
  `/correct` inserts *types*, splits poteto's "lint or test" into lint (level 2) above tests
  (level 3), drops "humans review" as a level, and moves "skill or rule" to last place and
  restricts it to judgement calls. encode-lessons orders unrepresentable state > lint/banned
  API > canonical helper > runtime check, with no test or docs level at all. Three different
  ladders; this harness's rent-check E2 is a fourth (cheapest-first). Adopting the family
  wholesale would hand agents competing orderings.
- **CONFIRMED** — current `/retro` is character-identical to the vetted `c55ee46` (reader
  line-by-line plus the digest's sha256). **REFUTED** — `/retro` tells the agent to *run*
  the repo's check command; `:18` says *Read*.

Incumbent claims: see 2.2 and 2.3. Noted separately — rent-check E5 obedience telemetry is
proposed, not implemented (REFUTED); E4 paper-tiger is a rubric instruction, not an engine
step (PARTIAL); rent-check is installed and callable (CONFIRMED, open defect #1244 unchanged).

### 2.5 Triage of the five non-deep candidates

- **`/retro`.** No do-not-retry trigger from 2026-09-20 fires: (a) graduation happened but
  the body is byte-identical and still prose-only, so the "and executable procedure" half is
  unmet; (b) the raw-JSONL fixture was not run; (c) no SessionEnd hook exists; (d) rent-check
  is present. The aihero FAQ **corroborates** the SKIP on its own terms: the author calls
  "invents generic advice to satisfy the retro categories" the strongest criticism, "rules
  pile up" the weakest area (it never audits previously added checks), says "retro is not a
  memory system", and confirms no hooks, no auto-apply, no dry-run. The andrestaltz tweet
  establishes a practitioner's enthusiasm and nothing about method, baseline or numbers.
  The documented `npx skills add --skill=` install path REJECT (source-traced 2026-09-20)
  stands.
- **poteto hierarchy.** The tweet is the doctrine `/correct` operationalises; see the
  ordering differences above. As a standalone artifact it is one sentence of prose.
- **pstack `encode-lessons`.** A strict subset of `/correct`'s ladder at lower resolution;
  adds "one-off -> brain note" routing that maps onto the memory `feedback` type we already
  have. SKIP-as-skill from 2026-09-18 stands.
- **pstack `reflect`.** Its three-reviewer transcript fan-out spawns non-read-only subagents
  with MCP access over the full transcript and sends it to model slugs set by an external
  rule file (default includes `grok-4.7-xhigh-fast`, `reflect:38`), auto-files Backlog items
  without approval (:55), and hardcodes Cursor transcript layouts (:19, :25). Not portable
  as-is. **Item 18 stays parked**: its #1202 trigger is "a planted-defect fixture showing a
  missed trigger", and this fixture tests class mining and fix level, not trigger misses.
- **pstack `architect`.** Overlap with `/correct` is one shared sentence (`architect:37` /
  `correct:11`). Not re-vetted; item 13 EXTRACT from 2026-09-18 unchanged.
- **doodlestein ergonomics.** Not a retro or correction mechanism; it is a remediation
  playbook for one friction class (CLIs that teach the agent nothing), the destination a
  correction loop would route *to*. Already here as a distillation. Provenance findings in
  section 4.

### 2.6 Corrections to my own digest

- "Every other vendored fork carries an `UPSTREAM.md`" is wrong: 30 of 64 `skills-local`
  directories have one, 34 do not. The ergonomics fork's provenance does exist, as one line
  in `retired-skills.txt:28`.
- 144 dotfiles feedback notes was a listing count; `rg` over frontmatter gives 141.
- The digest said papercut dossiers carry a "Cheapest remedy" field as if it were a ladder.
  It is a heading with no guidance text (`papercut.py:854`); only non-emptiness is checked.

### 2.7 Limits of this evidence

- n=3 trials per arm, one fixture, one model (sonnet), one task prompt. The prompt already
  says "the same mistakes", which primes class-finding in every arm; an unprimed prompt could
  separate the arms on class discovery, which this one did not.
- The fixture was built and graded by the session model (Fable 5.1); the arms were sonnet,
  so no arm saw its grader's reasoning, but the planted classes reflect one author's idea of
  "repeated mistake".
- Fix levels are the same in every arm, so this fixture cannot say whether `/correct`'s
  ladder changes *level* choice. It can only say the bare model already chose L1 for the
  status list and L2 for money and storage, and no arm reached L1 for those two.
- Runs were short (5-8 turns, one commit each). A larger or messier history may separate the
  arms; this one did not on the core columns.
- Prove-it: both graders scored a throwaway violating file as "not proven on a real
  instance". The key's wording ("a historical commit or the reverted pattern") could be read
  to admit a synthetic file; the stricter reading was applied to all nine alike.
- Cost: first trial per config dir wrote 42-45k cache-creation tokens, so medians are the
  headline figure and means are footnoted.
- The need measurement is one harness's notes, one cluster-judge pass, and sonnet verifiers
  with REFUTED as the default. I re-checked the six citations listed in 2.2; the other cited
  lines rest on the verifiers.
- "Phantom" is relative to this repo; two notes about product repos cite a file that may
  exist there.
- Ergonomics fork drift against v18 is unmeasured: `jsm` has no print-body or target-dir
  flag, and installing v18 to diff it would have activated a 192-file skill.
- Arm commits were not isolated from the global git identity (cosmetic).
- Blinding held on labels, paths and identity strings, not on report content for a2 (2.1
  validity checks): the scored rule-table column is itself the tell, so a grader who knew
  the candidate's vocabulary could place those three reports.
- `/correct` was run as a verbatim skill file in a bare config dir, not as the pstack plugin;
  plugin delivery was SKIP'd on 2026-09-18 and not re-tested.

---

## 3. Verdicts

Targets: **P** = product repos agents work in; **H** = this harness. Default was SKIP.

| component | target | verdict | placement | activation | evidence | state |
|---|---|---|---|---|---|---|
| `/correct` as a skill (vendored file or pstack plugin) | P | **SKIP** | — | — | 2.1: no delta on classes, false classes or fix level (9/9); procedural deltas only, at +37% median cost; exception ceremony in 2/3 | not installed |
| `/correct` as a skill | H | **SKIP** | — | — | 2.2: the top clusters are judgement behaviours its ladder routes to prose; 2.3: a fourth competing ladder beside rent-check E2, and the one existing prose-to-enforcer map (HARNESS.md:44-49) is kept out of prose on purpose (:46 is a rule about permission entries; it bears on a rule table by analogy only) | not installed |
| mechanism: rule-with-no-enforcer detection | H | **EXTRACT (adapted)** | `memory-audit.py`, new check `cited_enforcer_missing`, repo-scoped: a note about this repo that names a repo path, script or hook which does not exist | proposal only; follow-up issue; dry run on the live store before adoption | 2.2: 2 gone, 2 stale, 1 unrelated of 34 citations; consumer `harness-doctor.sh:332-345` already runs memory-audit; `test_memory_audit.py` runs in CI (`harness-tests.yml:2072`); delete the check when two consecutive monthly audits find 0 | proposed |
| mechanism: prove the check on the real past instance | H, P | **EXTRACT (one sentence)** | papercut dossier `## Planted negative` guidance (`papercut.py:860` template) or `harness/verification-architecture.md` | proposal only; behaviour-shaping, so inward review before any landing | 2.1: real-instance proof 2/3 vs 0/6; P4 caught 3/3 vs 1/3 vs 0/3 (suggestive at n=3); precedent HARNESS.md:49 (git-guard replay) | proposed |
| mechanism: history miner for repeated corrections | H | SKIP | — | — | the correction store is memory `feedback`; this note is the one-off measurement; a recurring miner names no consumer (creation gate) | — |
| mechanism: exceptions carry reason, expiry, approver | H | SKIP | — | — | 2.1: produced a docs-only format (a2-1) and unrequested machinery (a2-3); git-guard escapes are deliberate booleans (`git-guard.js:225-231`) | — |
| mechanism: rule-to-enforcer table in the instruction file | H | SKIP | — | — | HARNESS.md:44-49 is the one map, by design; rent-check E1 classifies per run | — |
| `/retro` | H, P | SKIP (stands) | — | — | byte-identical to `c55ee46`; no 2026-09-20 trigger fires; author FAQ corroborates | not installed |
| poteto hierarchy | — | SKIP | — | — | one sentence; a third ordering | — |
| pstack `encode-lessons`, `reflect`, `architect` | — | unchanged (SKIP; item 18 parked on #1202; item 13 EXTRACT) | — | — | 2.5 | — |
| aihero page, andrestaltz tweet | — | SKIP | — | — | documentation and endorsement; no method or numbers | — |
| doodlestein ergonomics | H | SKIP re-vendor; **provenance line landed** | `retired-skills.txt:28` | n/a | already distilled 2026-07-04; drift unwatched (jsm source, no git pin) | landed in this PR |
| extend papercut to operator corrections | H | SKIP | — | — | charter `papercut/SKILL.md:16-24`; 12/12 families are tool friction; its rank (distinct sessions of one error signature) means nothing for a correction | — |

**In the operator's three words.**

- *Depend on one:* no. The fixture gives `/correct` nothing on the columns that matter, and
  its ladder is a fourth ordering beside rent-check E2, poteto and encode-lessons. `/retro` is
  unchanged since its SKIP. The pstack plugin route was REJECT'd for delivery on 2026-09-18.
- *Cherry-pick into a bespoke uberskill:* no uberskill. The one-sentence task prompt already
  carries the skill's core, and a bare sonnet executes it. Two mechanisms are worth lifting,
  neither as a skill: a `memory-audit.py` check that a feedback note's cited enforcer exists,
  and one sentence tightening the planted-negative requirement to a real past instance. Both
  are proposals here; neither lands in this PR.
- *Add to papercut, or have papercut work with it:* no. papercut is friction-only by charter,
  every one of its 12 families confirms that, and its ranking has no meaning for a correction.
  The correction store is the memory `feedback` type; the dividend goes there.

**Price.** Vendored, `/correct` would cost about 0 always-loaded tokens
(`disable-model-invocation: true` keeps it out of the skill listing) and about 37% more per
invocation. Moot, since not adopted. The ergonomics fork `cli-agent-ergonomics` is
model-invocable with a 211-character description in every session's listing: flagged for the
operator, not changed.

### Do-not-retry unless

- **`/correct` as a skill:** a fixture with an *unprimed* task prompt (no "same mistakes"
  cue), >=5 trials per arm, where the bare arm misses a planted class that the skill arm finds
  in >=4/5; **or** pstack ships `/correct` with an executable history miner (commits, reverts,
  review comments) rather than prose; **or** this harness adopts a persisted rule-to-enforcer
  table, at which point the ordering question (E2 vs `/correct`) has to be settled first.
- **`/retro`:** the four 2026-09-20 triggers, unchanged.
- **`cited_enforcer_missing` (proposed):** drop it if a dry run on the live store shows more
  than 1 false positive in 10 on cross-repo notes, or if feedback notes stop naming paths.
- **Prove-it sentence (proposed):** drop it if the inward review finds the last five papercut
  dossiers already read `## Planted negative` as a real past instance.
- **Ergonomics fork:** re-vet only on a jsm scope change (new sections beyond the v11 kernel),
  or if `jsm` grows a body-print flag that makes a v11->v18 diff cheap.

---

## 4. Audit dividend

1. **Two feedback notes cite scripts that exist nowhere in the repo, two cite stale values, one
   cites an unrelated test range** (2.2, each re-checked at the line). Fixing the notes is
   hygiene for the live store, a follow-up rather than this PR: memory edits reach
   `memory/` via `backup-harness.sh`, and a `memory/**` diff in a PR blocks dotup
   activation. The repo-scoped check in section 3 is the mechanism that stops the class.
2. **The verification-discipline clusters (1-5) are this harness's real repeat:** 51 notes carrying 66 corrections, no
   blocking enforcer. Not a `/correct` job. Recorded for memory-dream consolidation and for the
   evidence-regime work (`harness/evidence-regime.md`), not actioned here.
3. **Ergonomics fork provenance** was one line with an undated upstream; it now records v18 as
   of 2026-09-26, the v12-v18 gap and that drift is unwatched (`retired-skills.txt:28`,
   landed). No `UPSTREAM.md`: `vendored-drift-check.sh:55-112` needs a `github.com/owner/repo`
   URL plus a git pin, the source is jsm, and a pinless file would WARN `no-pin` every week.
4. **`cli-agent-ergonomics` is model-invocable with a 211-character description.** Flagged; a
   listing-budget call for the operator, not changed here.
5. **Two tool frictions logged with `papercut add`:** the worktree command-shape guard refuses
   `git -C <relative>` after a `cd` as "directory computed at runtime" though the path is a
   literal (an absolute literal passes); `jsm show` and `jsm install` have no print-body or
   target-dir flag, so a distilled fork cannot be diffed against its upstream without
   activating the upstream skill.
6. Digest corrections in 2.6 (vendored-fork `UPSTREAM.md` coverage is 30 of 64, not all).

---

## 5. Prior notes and reuse

Reused: `docs/vets/2026-09-20-retro-harness-vet.md` (SKIP, REJECT of the documented
install, the pre-digested-transcript limit, dividend #1244, deferred #1245) — its fit
conclusion applies unchanged because the candidate is byte-identical and no trigger fires.
`docs/vets/2026-09-18-pstack-harness-vet.md` (plugin delivery SKIP, `principle-*` SKIP as
skills, `reflect` item 18 parked on #1202, `architect` item 13, the vendor-one-component
pattern with `UPSTREAM.md` pins). `mattpocock-skills-evaluation-2026-08` (plugin route
rejected; skills.sh traps). The retro fixture's arm runner and blinding procedure
(`experiments/seo-arm-fixture-2026-09-05/run_arm.sh`, `vet-fixtures/retro-2026-09/`)
were reused with one recorded change (`--max-turns 60`); its `setup-arms.sh` was **not**
reused because it strips `.git`, and this candidate mines history.

Searched: `memory/-home-user-hov-stack/` (41 vet notes), `docs/vets/` (13 notes),
`harness/vet-fixtures/`, gh issues #1197 #1198 #1201 #1202 #1242 #1243 #1244 #1245,
the jsm catalogue (retro/lessons/correction/postmortem/friction: no doodlestein skill in this
space). No prior note on `/correct`, poteto's hierarchy or the aihero page existed; this is
the first.

---

## 6. Re-audit triggers

- `pstack/skills/correct/SKILL.md` sha256 moves off `bf482bac…c904` with a change to the
  ladder, the threshold, or an added executable step.
- `mattpocock/skills` `retro/SKILL.md` body changes from the `c55ee46` / `a7d038f6` content.
- The jsm catalogue shows the ergonomics skill past v18 with new section headings.
- The proposed `cited_enforcer_missing` check lands: re-count the 34 citations.
- A new feedback note joins any of clusters 1-5 after 2026-10-07 (the repeat is still
  repeating): re-run the need measurement for both targets.
- rent-check #1244 closes or E2's ordering changes: the ladder-conflict row in 2.3 changes.
