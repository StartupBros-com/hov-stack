# Scoring — anti-slop list vet (2026-09-02)

Vet of the 23-URL anti-slop skill list (issue #892, PR #893; memory note
`anti-slop-skill-list-vet-2026-09`). Judge = session model (Fable 5.1) holding the answer
keys. Arms = Sonnet subagents via the Agent tool, identical task text, Read tool only, 2
trials per arm. Hit = right line + right problem class; partial = right line, wrong/vague
reason (0.5); FA = a control flagged or a defect invented. Unplanned-but-true observations
(e.g. the unused `formatCurrency` import, `TsvWriter.row` not escaping tabs, `summarize()`
never called) are neither credited nor penalized.

## Prose fixture (tally-prose-bundle.md v2, 21 planted, 11 controls)

| Arm | Trial | Hits /21 | FA | Missed |
|---|---|---|---|---|
| bare | 1 | 14.0 (D6, D12 partial) | 1 (L59 named quote read as "fabricated") | D1 D4 D7 D9 D11 D21 |
| bare | 2 | 16.5 (D12 partial) | 0 | D1 D9 D11 D21 |
| incumbent de-slopify (SKILL.md + PATTERNS.md, 27 KB) | 1 | 18.0 | 0 | D1 D11 D21 |
| incumbent de-slopify | 2 | 18.0 | 0 | D1 D11 D21 |
| candidate Aboudjem/humanizer-skill (SKILL.md + patterns.md, 65 KB) | 1 | 14.0 | 0 | D1 D2 D4 D6 D17 D20 D21 |
| candidate humanizer-skill | 2 | 9.5 (D9 partial) | 0 | D1 D2 D3 D4 D6 D7 D8 D11 D17 D20 D21 |

Means: bare 15.25 / FA 0.5; incumbent 18.0 / FA 0; humanizer-skill 11.75 / FA 0.

The 65 KB candidate doctrine lowered recall below bare: trial 2 missed bold-label bullets
(D7), negative parallelism (D2) and the vapid opener (D3), all three named in its own pattern
list. It was the only arm to catch false agency (D11), once. Consistent with the added-context-
degrades result the harness-vet skill cites; the verdict is SKIP the skill, EXTRACT the
deterministic artifact tokens (now p13-p15 in rules.prose.mjs) and the false-agency rule.

Mechanical pass on the same fixture (sandbox HOME, read-only):

| Tool | Em-dash (D1) caught? | Line-level hits mapped to planted defects | FA on controls |
|---|---|---|---|
| kill-ai-slop `scan.mjs` (as shipped) | no | D19 only (emoji, tell 15) | 0 |
| kill-ai-slop `scan.mjs --rules=rules.prose.mjs` (shipped in PR #893, tells p1-p12) | **yes** | D1 D2 D4 D5 D7* D10 D13 D14 D15 D16 D17 D19 = 12 classes (*D7 on the de-numbered copy; the `N. ` prefix defeats the bullet anchor) | 0 |
| soundshuman `sloplint analyze` | yes | D1 D10 D16 D19 (+ -ing tail on L46) | 2 (legit triad L20; en dash range L49) |
| slopkit `deslop_lint.py` | counts only (`dash_count: 2`), no locations | n/a | n/a |
| humanizer-skill `cli score` | no; scores the 21-tell bundle **4/100 "Pristine"** (1/100 with line prefixes) | none | n/a |
| humanizer-skill `cli compare --check-facts` | n/a (different job) | catches 4/4 facts dropped by a lossy rewrite; passes identical-text control | 0 |

Planted negative (acceptance check for #892): the fixture with the line-3 em-dash replaced
by a comma produces zero p1 hits; `facts-check.cjs` on a wording-only rewrite exits 0.

FP probe of the rule module on real harness prose (dotfiles README.md + HARNESS.md +
third-party-skill-vetting.md, 301 lines): 46 hits, all tell p1 (em-dash), zero from p2-p12.
The harness's own docs use em-dashes as house style, so p1 is a "confirm by reading" tell
exactly like the visual ones, not a fail gate (precedence question filed as #896).

Observations:
- **All four reading arms missed D1, the em-dash on line 3** — the tell de-slopify's own prompt
  names first. A 15-line regex module catches it with 0 FP. de-slopify's "you can't do this
  with regex or a script" doctrine is contradicted by its own miss; the right shape is
  mechanical pre-pass for deterministic tells, then the manual judgment pass. Landed.
- D11 (false agency, L28) missed by every incumbent and bare arm; a stop-slop /
  humanizer-skill P44 / soundshuman #14 rule de-slopify lacked. Landed as one table row.
- D21 (title formula) missed by every arm; weak plant, not pursued.
- Contamination note: incumbent T1 remarked L12 "mirrors canonical slop example almost
  verbatim" (de-slopify carries "you'll only ever click one"). Both bare arms also flagged L12
  (one partial), so D6 is not decisive. v1 of this fixture was withdrawn before any arm ran
  because it reused eight multi-word exemplars found verbatim in the incumbent and in five
  candidates; v2 plants the same classes with fresh instances. One incumbent-side overlap
  remains ("functions as", once in PATTERNS.md); both bare arms flagged L27 anyway.

## Code fixture (invoice-code-bundle.md, 18 planted K1-K18, 8 controls H1-H8)

| Arm | Trial | Hits /18 | FA | Missed |
|---|---|---|---|---|
| bare | 1 | 10.0 | 0 | K1 K3 K4 K7 K8 K11 K12 K17 |
| bare | 2 | 11.5 (K2 partial) | 0 | K3 K4 K7 K8 K12 K17 |
| incumbent thermo-nuclear-code-quality-review | 1 | 13.0 | 0 | K3 K4 K8 K11 K12 |
| incumbent thermo-nuclear | 2 | 13.0 | 1 (H3: SAFETY-commented cast called "double unsafe cast") | K3 K4 K8 K11 K12 |
| candidate AsyrafHussin code-slop (SKILL.md + rules/) | 1 | 15.0 (K8, K15 partial) | 0 | K3 K17 |
| candidate code-slop | 2 | 15.5 (K8 partial) | 0 | K3 K17 |
| candidate dietrichgebert ponytail-review (SKILL.md alone) | 1 | 7.0 | 1 (H5: dated HACK wrapper flagged "yagni, inline it") | K2 K3 K4 K5 K8 K9 K11 K12 K14 K17 K18 |
| candidate ponytail-review | 2 | 7.0 | 1 (H5, same) | same |

Means: bare 10.75 / FA 0; thermo-nuclear 13.0 / FA 0.5; code-slop 15.25 / FA 0;
ponytail-review 7.0 / FA 1.0.

Class-level pattern:
- K4 (type-in-name), K11 (mirror test), K12 (snapshot test) — code-slop's own classes —
  missed by thermo 2/2 and bare 2/2 (K11 bare 1/2), caught by code-slop 2/2.
- K17 (parallel if/else-if chains in two functions) — thermo's own class — caught by thermo
  2/2, missed by bare 2/2 and code-slop 2/2. The two lenses are complementary, not nested;
  code-slop is vendored beside thermo-nuclear, not instead of it.
- K3 (generic names `data`/`handler`) missed by every arm although the CE persona and
  code-slop both name it.
- ponytail-review caught only classes thermo also caught (K1 K6 K7 K10 K13 K15 K16) and
  false-accused the same control twice; its scope fence excludes K9/K14/K18 by design. SKIP.
- H3 (SAFETY-commented `as unknown as` cast) drew thermo's only FA; code-slop respected it
  2/2 — consistent with dmmulroy/anti-slop's `require-safety-comment-for-type-assertion`.

## Construct caveats

n = 1 fixture per side, 2 trials per arm, Sonnet arms, no paired-comparison interval. Both
fixtures were written by the vet after reading the candidates' rule lists; the code fixture
deliberately mixes thermo-only, code-slop-only, and neither-named classes so it is not a pure
candidate echo, and the prose fixture was scrubbed of doctrine exemplars (see above). They
measure "does the doctrine change behavior on what it names" and "does the incumbent already
name it", not real-world defect frequency or cost. Deciding measurement if contested:
`/skill-tuner` paired run at session tier.

## Re-running

Reuse the bundles and keys as-is. To add an arm, give it the doctrine file(s) to read first
and the bundle second; keep the answer key out of every arm's prompt. Prose arms cite
`LINE <n>`; code arms cite `<file><line>` (A12). Before trusting a new fixture revision, grep
it for multi-word phrases lifted from any doctrine under test, incumbent included.

## Prose fixture re-run (2026-09-20): current incumbent vs the no-ai-slop finalist (issue #894)

Same bundle (v2), same key, same rules, same task text shape (doctrine files first, bundle
second, Read only). Arms = Sonnet subagents via the Agent tool, 2 trials each; judge = session
model (Fable 5.1) via the Agent tool, scoring six outputs under neutral labels A-F in a shuffled
order with the labelled originals moved out of its directory. Incumbent = the live de-slopify
(`~/.claude/skills/de-slopify`, upstream v4 text plus the PR #893 overlay). Candidate =
petergyang/no-ai-slop `skills/no-ai-slop/SKILL.md` + `eval.md` at 000650b1 (2026-09-02, MIT).
Arms were told to use the candidate's detect mode. A first attempt through the Workflow tool was
discarded: three of its six arms executed the session's relayed user request instead of the
review (memory note `workflow-arms-execute-the-relayed-user-request`); every number below is
from the Agent-tool rerun. Raw outputs and the judge table: `runs/2026-09-20-no-ai-slop/`.

| Arm | Trial | Hits /21 | FA | Missed |
|---|---|---|---|---|
| bare | 1 | 13.5 (D9 partial) | 0 | D1 D4 D6 D7 D11 D20 D21 |
| bare | 2 | 15.5 (D9 partial) | 1 (C10, the named Marta Ruiz quote, called "fabricated-sounding") | D1 D4 D7 D11 D21 |
| incumbent de-slopify (live, with the #893 overlay) | 1 | 18.5 (D20 partial) | 0 | D1 D21 |
| incumbent de-slopify | 2 | 18.5 (D20 partial) | 0 | D1 D21 |
| candidate petergyang/no-ai-slop | 1 | 15.5 (D9 partial) | 0 | D1 D6 D7 D11 D21 |
| candidate no-ai-slop | 2 | 16.0 | 0 | D1 D6 D7 D11 D21 |

Means: bare 14.5 / FA 0.5; incumbent 18.5 / FA 0; no-ai-slop 15.75 / FA 0.

Observations:
- The incumbent moved from 18.0 to 18.5 since 2026-09-02 and now catches D11 (false agency)
  2/2, the rule PR #893 landed; its only misses are D1 (the em-dash, which the scan pre-pass
  catches and which no reading arm has ever caught) and D21 (the title formula, a weak plant).
- no-ai-slop sits between bare and the incumbent and caught nothing the incumbent missed.
  Both trials missed D6 (setup-reversal), D7 (bold-label bullets), and D11 (false agency),
  which the incumbent names and catches 2/2. Its "portable-sentence test" surfaced in the
  candidate's reasons ("fails portability test") on lines the incumbent also flags, so it added
  vocabulary, not recall.
- D9 (copula avoidance, "functions as / sports") is the discriminator: bare and the candidate
  quoted the phrase but named only the buzzwords; the incumbent named the verb substitution.
- Both bare arms mixed the fixture's embedded numbering with the Read tool's file numbering;
  the judge matched items by quoted words, which is why the key's line column is advisory.

Verdict for #894's first finalist: SKIP the skill (below the incumbent by 2.75 points, no
unique catch); no measured increment for its six deferred extracts (items 1-6). The remaining
items on #894 from stop-slop, soundshuman, and deslop stay deferred until a live-task defect
maps to one of them; the do-not-retry line in the memory note stands.
