# Behavioral test scoring — ux-writing vs incumbents vs bare (2026-09-01)

Arms: Sonnet subagents (Agent tool), identical fixture, 2 trials each. Judge: session model
holding the answer key. Hit = right location + right problem. Partial = right location, wrong
or vague reason (0.5). FA = a control flagged, or a defect invented that is not in the bundle.
- A (bare): fixture only.
- B (candidate): upstream `skills/ux-writing/SKILL.md` @ 9ff8dddb (16.6KB) + fixture.
- C (incumbent): readme-writing + de-slopify + cli-agent-ergonomics + cli-doctor-mode
  SKILL.md (~42KB) + fixture.

## v2 — authoritative (fixture as committed here: 21 planted defects D1-D21, 8 controls)

| Arm | Hits /21 | Partial | FA | Missed |
|---|---|---|---|---|
| A1 bare | 5 | 0.5 (D14) | 0 | D1 D2 D3 D4 D5 D6 D7 D8 D11 D12 D15 D16 D18 D20 D21 |
| A2 bare | 7 | 0 | 0 | D1 D2 D3 D4 D5 D6 D7 D8 D11 D12 D15 D16 D18 D21 |
| B1 candidate | 17 | 0 | 0 | D3 D19 D20 D21 |
| B2 candidate | 17 | 0 | 0 | D3 D19 D20 D21 |
| C1 incumbent | 9 | 1.0 (D5, D13) | 1 (README:18 `lumen init` "not registered" — the parser is an excerpt) | D1 D2 D3 D6 D7 D11 D15 D18 D20 D21 |
| C2 incumbent | 9 | 0.5 (D13) | 1 (README:3 layer list read as a precedence contradiction) | D1 D2 D3 D6 D7 D11 D12 D15 D16 D18 D21 |

Means: bare 6.0 (+0.25 partial) / incumbent 9.0 (+0.75) / candidate 17.0. FA: bare 0.0,
incumbent 1.0, candidate 0.0. No trial of any arm overlaps another arm's range.

Defects no incumbent trial caught: D1 D2 D3 D6 D7 D11 D15 D18 D21 (9). The candidate caught 7 of
those 9 (all but D3 and D21).

Defects the candidate missed in BOTH trials that bare or incumbent arms caught: D19 (README
claims JSON support, config.md says JSON was rejected — caught by all four non-candidate arms)
and D20 (README ".env export" vs stdout-only export — caught by 3 of 4). The doctrine focuses
attention on the defect classes it names and, on this fixture, cost the model two cross-surface
fact contradictions it finds unaided. Recorded as a real cost of the port, not noise.

Controls: none of the eight v2 controls was flagged by any arm.

Unplanned observations credited to no one and penalized for no one: B2's note that
`cmd_doctor`'s docstring (cli.py:17) was not updated while its `--help` was; A1's note that
runbook:6 states one running container while the table shows staging on another build.

## v1 — retained for honesty, NOT evidence (contaminated)

The first fixture reused near-verbatim text from the candidate's own counter-examples in at
least 9 planted items (identical strings such as "Embedding dimensions: default (default)" and
"defined in the networking layer", the version number 2.3.1, the "show current configuration"
help string, the "(project)" annotation, the "see X for the full contract" phrasing, the
"This README demonstrates / we could also / implemented as" trio, the reviewer-asked-for-
no-cache comment, the negative-scope title template) and one control (C1's key-order comment).
An arm holding SKILL.md could pattern-match text it had just read. Found by the utility lens
before commit; every seeded item was rewritten for v2 and the reused version number changed.

v1 result (18 planted, 8 controls): bare 5/5, incumbent 7/7, candidate 18/18; candidate FA 0
after downgrading control C7 (three arms read it as a real mismatch). The v1 gap direction was
right; its size was inflated. v2 supersedes it.

## Construct caveats that still apply to v2

- The fixture was written by the vet from the candidate's rule list, so it measures "does the
  doctrine change behavior on what it names" and "do the incumbents name the same things", not
  how often those defects occur in real repos or what they cost.
- n = 1 fixture, 2 trials per arm, Sonnet subagents; no paired-comparison interval computed.
  If the harness banks more review-doctrine fixtures, add this bundle as one document of the
  set rather than treating it as a verdict on its own.
- Arms could read the doctrine and the fixture only; no repo, no tests, no runtime.
