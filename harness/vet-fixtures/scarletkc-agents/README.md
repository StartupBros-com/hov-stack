# Vet fixture: scarletkc/agents `ux-writing` (2026-09-01)

Behavioral test used by the `/harness-vet` run that vendored `ux-writing` invoke-only
(issue #829, PR #830; memory note `scarletkc-agents-ux-writing-vet-2026-09`).

## Files

- `lumen-review-bundle.md` — the review target handed to every arm: a fictional Python CLI
  (`lumen`) after a PR that added per-layer source reporting. README, two docs pages, a
  `cli.py` excerpt, a messages module, a CHANGELOG excerpt, and the PR title/body. Contains
  21 planted copy/docs/CLI-output defects and 8 honest controls. This is fixture **v2**; v1 was
  withdrawn before commit because it reused phrasing from the candidate's own counter-examples
  (see SCORING.md).
- `answer-key.md` — judge-only: each planted defect (D1-D21) with the candidate rule it maps
  to and whether an incumbent skill also names it; each control (C1-C8) with why it is fine.
- `SCORING.md` — per-arm results for v2 (authoritative) and v1 (retained, not evidence), the
  judge's adjustments, and the construct caveats.

## Protocol

Three arms, two trials each, all Sonnet subagents launched via the Agent tool with identical
task text. Each arm read exactly the files named (Read tool only, no shell) and returned a bare
list of `FILE:LINE — problem` lines; the prompt warned that a wrong accusation counts against it.

- **Bare**: fixture only.
- **Candidate**: read upstream `skills/ux-writing/SKILL.md` @ 9ff8dddb6714eb8e0b2f19c5a311441df244ecf7
  first, then the fixture.
- **Incumbent**: read the harness's four closest model-invoked skills first
  (`readme-writing`, `de-slopify`, `cli-agent-ergonomics`, `cli-doctor-mode`, ~42KB total),
  then the fixture.

Judge = the session model holding the answer key. Hit = right location + right problem;
partial = right location, wrong reason (0.5); false accusation = a control flagged or a defect
invented. Unplanned observations were neither credited nor penalized.

## Result (v2)

| Arm | Hits /21 | False accusations |
|---|---|---|
| bare (2 trials) | 5, 7 | 0, 0 |
| incumbent (2 trials) | 9, 9 | 1, 1 |
| candidate (2 trials) | 17, 17 | 0, 0 |

Both candidate trials missed the same four: the feature-list positioning section (D3), two
cross-file fact contradictions (D19, D20) that the bare arms caught, and the porcelain branch
that prints human lines before the JSON (D21).

Construct caveat: the fixture was written from the candidate's rule list. It shows the doctrine
changes behavior on what it names and that the incumbents do not name those things; it does not
measure how often those defects occur in real work or what they cost.

## Re-running

Reuse the bundle and answer key as-is. To add an arm, give it the doctrine file(s) to read
first and the bundle second; keep the answer key out of every arm's prompt. Before trusting a
new fixture, grep it for phrases lifted from the doctrine under test — v1 failed that check.
If the harness gains a paired-comparison instrument for review doctrines, bank this bundle as
one document of the set rather than re-deriving a verdict from it alone.
