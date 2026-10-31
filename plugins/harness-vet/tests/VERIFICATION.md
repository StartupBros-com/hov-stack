# v0.2.3 verification receipt

## Scope

v0.2.3 adds one sentence to phase 4's behavioral-test bullet. Until now the
isolation requirement sat on the neighbouring bullet, the one about running a
candidate's own test suite, so the arm-based comparison that actually decides
prompt-skill verdicts carried no isolation requirement at all. The 2026-09-05
SEO vet paid for that: its runner set no per-arm config directory, the host's
always-on skills loaded into the bare control, and every SKIP resting on "tied
with bare" rested on a contaminated comparison. The vet did not catch it.

The sentence names `CLAUDE_CONFIG_DIR`, points at the runner that already
implements the pattern, and states the check: diff the per-arm tool logs before
scoring, and drop any claim a confound touches to REFUTED or PARTIAL. It is
worth prose only because it points at a mechanism that exists; a sentence
saying "isolate your arms" would have earned the same deletion v0.2.2 gave the
licence handling.

## Actual checks

- Text audit: the addition lands inside the behavioral-test bullet. Phase 5's
  "config is not proof" wording is untouched, so the two checks stay distinct.
  A licence grep over the four files still returns exactly one line, the
  suppression line, unchanged from v0.2.2.
- Structural validation: 12 cases, unique ids. The suite is deliberately
  unchanged; no fixture was added.
- Release contract: VERSION and the plugin manifest both read 0.2.3.

## What did not run or finish

No decision smoke was rerun. No fixture scenario mentions arms, runners or
config isolation, so no case could move, and rerunning twelve cases to watch
them not move is the kind of ceremony this skill is supposed to refuse. That
is reduced coverage, stated rather than hidden: if this wording somehow shifts
a case, this round would not have caught it.

The claim that isolation would have changed the 2026-09-05 verdicts is NOT
made here. The defect count was saturated at 7 of 8 across all six arms, so
the contaminated control probably changed nothing about that run's outcome. It
changed what the run was entitled to claim.

The eval-note index-refresh idea reviewed alongside this one was deliberately
dropped. It was self-attestation that nothing checks, and the memory-dream
pass already covers description-versus-body staleness on demand.

# v0.2.2 verification receipt

## Scope

v0.2.2 removes licence and terms handling from the vet. Nothing in this
harness gated on it: no hook, no script, no CI check, only prose. The first
live run priced four candidates on licence status and changed the paperwork
without changing a decision, then left a licence ask with a 30-day check-back
behind. One line now states that licence and terms are not a vet input, so the
removed reasoning cannot return as spontaneous caution. The `unlicensed-verbatim-copy`
fixture was deleted with the rule it tested, taking the suite from 13 to 12.

## Actual checks

- Text audit: `grep -i` for licence and copyright across the four skill files
  returns one line, the suppression line in SKILL.md. The other three return
  zero. The repo's own LICENSE file is untouched.
- Structural validation: 12 cases, unique ids, valid targets and verdicts.
- Decision smoke, one round, three cases, each in a fresh session that read
  only the four skill files and one scenario, with expected verdicts and
  forbidden claims withheld, then graded by a separate reviewer against the
  key. The three are the cases whose scenarios stipulate licence facts and
  could therefore have shifted: `plugin-subset`, `skill-pack-named-subset`
  and `native-project-plugin`. Result: 3 of 3 exact, 3 semantic PASS, no
  forbidden claim asserted. The `native-project-plugin` answer states in its
  own words that licence and terms are not a vet input and did not move its
  verdict, which is the new line being applied rather than ignored.
- Release contract green on the pull request, with VERSION and the plugin
  manifest both reading 0.2.2.

## What did not run or finish

The other nine fixtures were not rerun. Their scenarios do not turn on licence
facts, and rerunning the full suite was judged disproportionate for a removal.
That is reduced coverage, stated rather than hidden: if a removal broke a case
outside the three, this round would not have caught it.

No paired comparison against v0.2.1 ran, so nothing here shows the vet decides
better without licence handling, only that it decides the same on the cases
that could have moved. No live scoped vet has run since v0.2.1.

## Sources and reproducibility

[The v0.2.1 rounds](scope-smoke-v0.2.1.json) remain as recorded, including the
`unlicensed-verbatim-copy` answers from the fixture this release deletes. They
are kept as history rather than rewritten. [The case instructions](README.md)
describe how to repeat the smoke with answers withheld.

---

# v0.2.1 verification receipt

The v0.2.0 receipt is preserved below this section. This one records only what
v0.2.1 changed and what was actually run for it on 2026-09-05.

## Scope

An adversarial review of the shipped v0.2.0 doctrine confirmed seven gaps on
the project-scope path and left five partials. v0.2.1 closes all twelve in the
four skill files: no license means no verbatim copy; the candidate's own copy
at another scope is a placement question, not automatic coverage; diverged
copies are diffed with an authoritative copy named; a target with no
instruction-loading surface at all gets its first one proposed, not landed;
the eval note lands where that target's future vets will search; a task must
name an artifact or outcome and how it is judged before the phase-4 fixture is
built; a component that adds tools is priced by measurement or marked PARTIAL,
and a required check left PARTIAL is SKIP, never ADOPT or ADAPT; a skill pack
under one manifest is a multi-component candidate, not a list; operator-named
components fill the deep-vet slate first; repo-level auto-run code is its own
read target and execution surfaces take reader slots before documentation;
coverage is judged per needed capability; a copied-out component runs
standalone before ADAPT; and a rollup covers only the targets the run was
asked about.

## Actual checks

- Review that found the gaps: six scenario readers and six refute-by-default
  verifiers over the v0.2.0 files, 29 claims scored 7 CONFIRMED, 10 PARTIAL,
  12 REFUTED. Scenarios were the real candidates queued for vetting, not
  abstractions.
- Inward review of the v0.2.1 diff: three lenses (fidelity to the findings,
  conflict with existing text, armor and utility of the wording), six findings,
  one of them a must-fix contradiction between the new SKIP carve-out and the
  closing checklist. All six were applied, including two the author disagreed
  with on first reading.
- Decision smoke, three rounds, one run per case per round, every case in a
  fresh session that saw only the four skill files and one scenario. Expected
  verdicts, forbidden claims, the case id and every other case were withheld.
  A separate reviewer then graded against the answer key.

| Round | Exact | Semantic PASS | PARTIAL | FAIL |
| ----- | ----- | ------------- | ------- | ---- |
| 1 | 10/13 | 10 | 0 | 3 |
| 2 | 12/13 | 10 | 2 | 1 |
| 3 | 13/13 | 11 | 2 | 0 |

Round 1's three failures returned the correct verdict for every requested
target and then added rollup rows for scopes nobody asked about. That is an
output-interface defect, so the interface was stated once in VERDICTS.md and
once in the fixture prompt rather than scored as a decision error. Round 2's
single failure was a real doctrine gap: a run priced a component PARTIAL and
rendered ADAPT anyway. Phase 5 now says a required check left PARTIAL is SKIP
pending its measurement. Round 3 ran against the files this release ships.

Round 3's two PARTIAL grades are answer completeness, not wrong decisions:
the unresolved-destination answer omitted its observable retry condition, and
the first-surface answer never said where the eval note lands. Both elements
are required by the doctrine the answer was applying.

- Fixture structure validated: 13 cases, unique ids, valid targets and
  verdicts. `tests/README.md` carries the validator and the count.
- Skill metadata tests in the canonical tree: 26 tests pass.
- Release contract green on the pull request: VERSION and the plugin manifest
  both read 0.2.1, the manifest names this repo, and the announce workflow pin
  matches marketplace content.

## What did not run or finish

No live scoped vet has run. The `for <project-path>` path still has zero real
candidates through it; the queued SEO and estate vets are separate work. No
paired comparison against v0.2.0 was attempted, so nothing here shows v0.2.1
produces better verdicts than v0.2.0, only that it decides the thirteen
authored cases as intended. One run per case per round is a smoke test, not a
statistical result, and every round used one model family.

No skill was relocated, installed or removed, no global settings changed, and
no release tag, marketplace card or announcement is implied by this receipt.

## Sources and reproducibility

[The recorded rounds](scope-smoke-v0.2.1.json) hold every answer, every
reviewer note and the SHA-256 of the four files as shipped. Rounds 1 and 2 ran
against earlier revisions of those files; only round 3 matches the recorded
hashes. [The case instructions](README.md) describe how to repeat the smoke
with answers withheld.

---

# v0.2.0 verification receipt

## Scope

Shared artifact evidence plus per-target fit; native scoped placement is ADOPT
when used as-is, packaging changes are ADAPT. A global clutter SKIP no longer
vetoes a useful project candidate, and narrowing scope never erases applicable
security findings. Explicit and inferred targets, multiple projects, prior
note search gaps, plugin source controls, update/rollback and no-install
unresolved assessments are covered by the four skill files.

## Actual checks

- Eight isolated final scope scenarios matched the exact expected verdicts.
  Expected fields and forbidden-claim keys were withheld from each evaluated
  session. Separate semantic review checked explanations as well as labels.
- Rejected unpublished draft failed the global-cost-to-project-fit control.
  This is not a comparison against v0.1.2 and is not a performance estimate.
- Initial exact scoring passed four cases and failed four. Semantic review
  found seven correct decisions and one incomplete unresolved row; arbitrary
  target strings and component rows conflicted with the scorer. We retained
  the failures, clarified the unresolved rule and output interface, and reran.
- Strict whole-plugin manifest validation passed. The bare skill-directory
  invocation failed to find a plugin manifest; metadata was separately tested
  using existing frontmatter/collision tests with the public payload as input.
- Existing Python skill tests passed: 26 tests. Localization-name regressions
  passed: 31 assertions. Version/manifest, fixture structure, links, host-path
  portability and git whitespace checks passed.
- Two final inward-review lenses returned the same inline-only completion
  defect. The digest gate is now conditional on delegation; unavailable
  independent review leaves a port unshipped rather than preventing assessment.
- Canonical and public four-file payloads were compared byte-for-byte.
  The pinned announcement workflow matched current marketplace workflow content.

## What did not run or finish

The separate estate-skill behavioral dry run failed twice with an inference
API 503. Its read-only install-state check confirmed duplicate placements and
divergent references, but not runtime precedence or domain quality. It is not
counted as a passed behavioral test. Native plugin evaluation tooling was
found in local CLI help, but the isolated command guard rejected its command
shape; the recorded smoke used fresh workflow sessions instead.

No live skills were relocated, no global settings changed, and no SEO/estate
candidate was installed by this change. No release tag, marketplace promotion,
announcement or deployment is implied by these test receipts. External study
findings are labeled by source and are not claimed as local improvements.

## Sources and reproducibility

The primary sources are linked in EVIDENCE.md. Fixture inputs and complete
responses live beside this receipt; local scratch paths are redacted only.
The final response file records requested model and exact policy file digests.
The case instructions describe how to repeat the smoke with answers withheld.
A single round does not establish statistical robustness across models.
