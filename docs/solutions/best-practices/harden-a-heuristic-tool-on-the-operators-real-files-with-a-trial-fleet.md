---
title: "Harden a heuristic tool on the operator's real files with a trial fleet, not only on its own fixtures"
date: "2026-09-12"
category: best-practices
module: sign-it-real-document-trials
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - "A skill or CLI decides where to act from heuristics over the operator's own files (PDF layout, form fields, document text) and its test fixtures were written by the same person who wrote the heuristics"
  - "The tool's suite is green but its first run on a real file returns nothing, acts in the wrong place, or acts over something that was already there"
  - "Deciding how much evidence a 'works on my fixtures' skill needs before it is published to other people"
related_components:
  - "skills-local/sign-it/tests/run.sh"
  - "skills-local/sign-it/tests/make-fixture.mjs"
  - "docs/vets/2026-09-11-documenso-harness-vet.md"
tags: [trial-fleet, real-files, heuristics, fixtures, workflow, adversarial-verify, sign-it, pdf]
---

# Harden a heuristic tool on the operator's real files with a trial fleet, not only on its own fixtures

## Context

sign-it (agent-native PDF signing) shipped with an 87-check suite over synthetic agreements and failed its first real document: a tax form whose signature line is a drawn rule, invisible to text extraction, so the finder returned no candidate. A sweep of all 1,676 PDFs in the operator's Downloads and four rounds of trial agents over real files then found failure families the fixtures could not have contained, because the fixture author only draws what the heuristic already expects: captions printed under a drawn rule (government form layouts), underscores glued to their label (Word exports), owner-password PDFs the library refuses (86 of the sweep's 112 errors), executed signatures the tool stamped over, generic identity and loan fields scoring as signature lines because a role word matched, side-by-side party blocks sharing one date, and a `--near` column anchor that matched the page's running header instead of the table header. Each became a fixture and a test only after a real file exposed it (dotfiles #1129, #1130, #1131, #1133).

## Guidance

Treat the operator's real corpus as the test set the fixtures approximate, and run it before publishing.

1. **Sweep the corpus mechanically first.** Run the tool's own read-only probe (`find`) over every candidate file with a per-file timeout and no OCR, into one TSV: exit code, candidate count, sources, first labels, error text. Tally two things: error classes (the encrypted-PDF family was one line in the tally) and label frequencies across low-confidence hits (the "`<verb> by`" footer family and the "Sign your" fragment family fell straight out of a top-45 label count). The sweep costs minutes and names families before any agent reads a page.

2. **Trial one document per agent, judged from the render.** For a selected set spanning every source the tool claims, run one agent per document: probe, act into a scratch path (never beside the source), render the page and a zoom of the result, and judge from the pixels: on the line, not over printed text, the operator's line rather than the counterparty's, date readable, sensible size. Ask each agent for the false positives and the missed lines it can see in the render, not only for its own outcome. Return a fixed schema so rounds are comparable.

3. **Verify every claimed defect with a skeptic, refute-by-default.** The trial agents were wrong in both directions on first read: one "no candidate" was a mistyped path, one "inked" flag was a filled table cell, and several "good" placements were on the counterparty's column. A second agent per flagged trial, given only the artifacts and told to refute, turns the list into confirmed families with evidence.

4. **Fix at the source, add the family as a fixture, re-run the same fleet.** Every confirmed family becomes a synthetic fixture and a test in the suite; the fix goes into the shared rule, not a special case; the identical fleet re-runs on the new build with corrected paths. Score each round as correct placements over trials and carry the per-family verdicts into the PR's evidence comment.

5. **Keep the scratch honest and then destroy it.** Outputs go to a per-session scratch directory only; the tool refuses to overwrite its input; the fleet is told never to force past a refusal. At the end, delete every scratch copy: they are the operator's real contracts and forms, some now carrying the operator's signature.

A workflow shape that did this in one call per round, with the trial and the verification pipelined per document:

```js
const results = await pipeline(
  items,
  (it) => agent(trialPrompt(it), { label: `trial:${it.id}`, schema: TRIAL_SCHEMA }),
  (t) => flagged(t) ? agent(verifyPrompt(t), { label: `verify:${t.id}`, schema: VERDICT_SCHEMA, effort: 'high' }).then(v => ({ trial: t, verdict: v })) : { trial: t, verdict: null },
)
```

## Why This Matters

Fixtures encode the author's model of the input; a heuristic tested only against them is tested against its own assumptions. The measured cost of skipping the trial was a published skill that could not sign the first form the operator handed it. The measured value of running it: correct placements went from 9 of 20 documents on the first build to 13 of 22 and then 11 of 15 plus one correct refusal, and the first real end-to-end use (a two-party agreement from Word: convert, sign, date, fill the block) succeeded only because the `--near` anchor bug was caught in the trial render before the file reached the operator's Downloads.

## When to Apply

- Before publishing any skill whose placement or selection logic runs over documents the operator did not author (contracts, government forms, statements, scans).
- After a suite is green but a real-file report says "nothing found" or "wrong place": suspect a missing family, not a wrong threshold.
- When a fix lands for one family: re-run the whole fleet, not the one document, because rules interact (a stricter label rule removed real captions until the "contains signature" exemption was added).

## Examples

- **Drawn rules.** Fixture rows used `Signature: ______`; the IRS form draws the rule. The fix was a new candidate source (a short label with a wide gap beside it) and a fixture that draws its rule with `drawLine`, never with underscores.
- **Running-header anchors.** `--near "STARTUPBROS"` picked the left column because the party name also sits in the page header; the trial render showed the name under the wrong column. The fix measures against the anchor nearest above each blank and refuses anchors that do not separate the columns; the fixture gained a running header naming both parties.
- **Executed signatures.** An e-signed agreement was re-stamped over its signature because nothing looked at pixels. The fix renders each candidate's stamp area and measures its dark share, ignoring rows that span the crop (rules and borders); the fixture draws a scrawl over one blank and leaves another clean.

## Related

- `docs/vets/2026-09-11-documenso-harness-vet.md`: the vet whose T1 verdict became sign-it, with the outcome section listing the PR chain.
- `skills-local/sign-it/tests/run.sh` and `skills-local/sign-it/tests/make-fixture.mjs`: every family above is a named fixture kind there.
- `docs/solutions/best-practices/make-test-assertions-falsifiable-by-the-defect-they-guard.md`: the same discipline for a single assertion; this doc is the corpus-level version.
