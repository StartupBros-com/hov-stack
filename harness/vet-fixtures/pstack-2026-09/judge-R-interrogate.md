# Judge report: fixture R, `interrogate` vs incumbents on the invoice code bundle (2026-09-18)

Judge = a separate session-model agent holding `../anti-slop-list/invoice-answer-key.md` (18 planted
defects K1-K18, 8 honest controls H1-H8) and applying `../anti-slop-list/SCORING.md`'s code-fixture
conventions (hit 1.0, partial 0.5, false accusation = a control flagged or a defect invented).
Arms = Sonnet, `claude -p --bare --tools ""`, two trials each, prompts never shown to the judge.
All 8 files scored.

## Scores

| Arm | Trial | Hits /18 | Partials | FA | Missed IDs |
|---|---|---|---|---|---|
| bare | 1 | 12.5 | 1 (K12) | 2 (H3, H8) | K3 K4 K7 K8 K11 |
| bare | 2 | 13.5 | 1 (K12) | 2 (H3, H8) | K3 K4 K7 K8 |
| interrogate (pstack SKILL.md + 4 references) | 1 | 13.5 | 1 (K12) | 1 (H3) | K3 K4 K8 K11 |
| interrogate | 2 | 13.5 | 1 (K12) | 1 (H3) | K3 K4 K8 K11 |
| thermo-nuclear-code-quality-review (ours) | 1 | 13.0 | 0 | 1 (H3) | K2 K3 K4 K8 K11 |
| thermo-nuclear | 2 | 13.5 | 1 (K12) | 1 (H3) | K2 K3 K4 K8 |
| code-slop (ours, SKILL.md + 25 rule files) | 1 | 16.0 | 0 | 0 | K8 K17 |
| code-slop | 2 | 16.0 | 0 | 0 | K8 K17 |

| Arm | Mean hits /18 | Mean FA |
|---|---|---|
| bare | 13.0 | 2.0 |
| interrogate | 13.5 | 1.0 |
| thermo-nuclear | 13.25 | 1.0 |
| code-slop | 16.0 | 0.0 |

Prior run on the same fixture (2026-09-02, Sonnet subagents via the Agent tool): bare 10.75 / 0,
thermo-nuclear 13.0 / 0.5, code-slop 15.25 / 0. Same rank order.

## Coverage by class

- bare caught 12 classes in both trials; missed K3, K4, K7, K8 in both.
- interrogate caught 13 in both trials (identical set); missed K3, K4, K8, K11 in both.
- thermo-nuclear caught 12 in both; K11 and K12 inconsistent across trials; missed K2, K3, K4, K8 in both.
- code-slop caught 16 in both (identical set); missed K8, K17 in both.
- K8 (defensive try/catch around a pure in-memory loop) was missed by all 8 outputs, code-slop
  included, though code-slop's own rules name the class; every arm caught the adjacent K18 at the
  same location.
- K3 and K4 (generic names, type-in-name) were caught only by code-slop, whose rule granularity
  decomposes naming into per-identifier findings.

## Form and doctrine effects

- All 8 outputs stayed in the requested `<location> - problem` list form.
- interrogate uniquely pushed into test-adequacy scrutiny (an untested 30-day boundary, untested CSV
  escaping), both unplanned-true and neutral; that did not raise planted-defect recall over thermo.
- thermo framed K6 as an architecture problem and was the only family to name K17 in both trials.
- bare was the only family to flag H8 (correct CSV escaping) as a defect in both trials.

## Verdict

interrogate's doctrine text gave a modest precision gain over bare (FA 1.0 vs 2.0) and a small
recall bump (13.5 vs 13.0), is indistinguishable from our thermo-nuclear (13.25, FA 1.0; the two
share near-verbatim lineage, see C032 in the eval note), and underperforms our vendored code-slop on
both axes (16.0, FA 0). The rubric and lens text buy nothing over what the harness already owns.
Caveat: this measures the text under a single no-tools Sonnet pass; pstack's multi-model parallel
panel, the skill's actual mechanism, was not exercised and remains the only unmeasured candidate.
