# Judge report: fixture B, `how` vs incumbents (2026-09-18)

Judge = a separate session-model agent holding `../explainer-toolbox-2026-09/answer-key.md` (Fixture B:
12 call edges E1-E12, 2 quirks Q1-Q2, 3 traps T1-T3) and applying the standard stated in
`../explainer-toolbox-2026-09/judge-fixtureB.md` (an edge is PRESENT only when the output states the
behavior or annotates it in the diagram; a bare function name in a tree does not count). Arms = Sonnet,
`claude -p --bare --tools ""`, two trials each, prompts never shown to the judge.

## Scores

| Arm | Trial | Edges /12 | Quirks /2 | Traps sprung /3 | Invented | Prose words | Diagram |
|---|---|---|---|---|---|---|---|
| bare | 1 | 8 | 2 | 0 | none | 318 | no |
| bare | 2 | 7 | 2 | 0 | none | 346 | no |
| how (pstack) | 1 | 9 | 2 | 0 | none | 416 | mermaid |
| how (pstack) | 2 | 11 | 1 | 0 | none | 430 | mermaid |
| show-me (adapted, skills-local) | 1 | 6 | 2 | 0 | none | 104 | call tree + diff |
| show-me (adapted) | 2 | 7 | 2 | 0 | none | 95 | call tree + diff |
| ce-explain (compound-engineering) | 1 | 9 | 2 | 0 | none | 572 | no |
| ce-explain | 2 | 11 | 1 | 0 | none | 557 | no |

Means /14: bare 9.5, how 11.5, show-me 8.5, ce-explain 11.5.

## Misses

- E2 (await registerAsset) was missed by all 8 outputs.
- bare missed E2, E4, E9, E12 in both trials.
- how missed E2 both trials; E1 and E12 in trial 1 only; Q2 in trial 2 only.
- show-me missed E1, E2, E8, E9, E12 in both trials: a bare function name in a call tree cannot carry
  "what it does" or "how many", the same structural finding as the prior round.
- ce-explain missed E2 both trials; E4 and E12 in trial 1 only; Q2 in trial 2 only.

## Form

- how: fixed Overview / How It Works / Gotchas template plus a mermaid flowchart with inline branch
  conditions, then a prose paragraph per scenario. The diagram's branch labels carried E3, E6, E7,
  E10, E11. Trial 2 was the only non-ce-explain output to state the literal label rewrite (E1) and the
  full onmessage + onerror pair (E12).
- ce-explain: longest outputs, numbered walkthrough with a closing "Open questions" or "Not shown"
  section that flags what the pasted source cannot settle (hash algorithm, retry backoff, router
  semantics). That caution cost it E4 and Q2 credit in trial 1 under a must-state rubric.
- No output claimed to run, open, or save anything.

## Verdict

pstack's `how` doctrine text raised completeness over bare (11.5 vs 9.5) and over the adapted show-me
(8.5), and tied the strongest incumbent, ce-explain (11.5). Fabrication was flat at zero for every
arm, so the gain is a structure and length effect (diagram plus Gotchas, or explicit-unknowns
walkthrough), not fabrication suppression. This measures the skill text steering one no-tools model;
pstack's explorer-subagent mechanism was not exercised.
