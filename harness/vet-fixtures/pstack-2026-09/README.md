# Vet fixtures: pstack harness-vet (2026-09-18)

Behavioral tests and candidate test log behind `docs/vets/2026-09-18-pstack-harness-vet.md`
(work-spec #1197, PR #1198, follow-ups #1201 and #1202). Candidates: cursor/plugins `pstack` at
`1f84288b` (0.15.2) and ScriptedAlchemy/pstack-codex at `594accc7`.

## Files

- `run-arms.sh` builds ten arm prompts across three fixtures reused from sibling directories and
  runs them on Sonnet in `claude -p --bare --tools ""` (no tool, skill, hook, or CLAUDE.md can reach
  an arm; the doctrine under test is inlined). Env: `CAND` (pstack scratch clone `skills/` dir),
  `OUT` (fresh dir), `RUNS` (default 2), `ARMS` (subset). Accepts the run only when every
  invocation exited 0 with `is_error` false and a non-empty result (`../check-arms.py`,
  dotfiles#1690); anything else exits 1 before the results summary.
  - R = code review on `../anti-slop-list/invoice-code-bundle.md` (K1-K18 planted, H1-H8 controls).
    Arms: `R-bare`, `R-interrogate` (pstack interrogate SKILL.md + reviewer-prompt, rubric,
    code-quality-review, lead-judgment), `R-thermo` (thermo-nuclear-code-quality-review),
    `R-codeslop` (code-slop SKILL.md + `rules/`).
  - H = code explanation on `../explainer-toolbox-2026-09/fixtureB-code.ts` (12 edges, 2 quirks,
    3 traps). Arms: `H-bare`, `H-how` (pstack how + explorer and explainer prompts), `H-showme`
    (this repo's adapted show-me), `H-ceexplain` (compound-engineering ce-explain).
  - B = blast radius on the same module plus a proposed `fingerprint()` change. Arms: `B-bare`,
    `B-blast` (pstack blast-radius). No pre-written key; the judge derived one from the code first.
- `arms-run1/` holds the 20 unwrapped outputs and `summary.txt` (cost, served model, output size
  per run). Total about $3.
- `judge-R-interrogate.md`, `judge-H-how.md`, `judge-B-blast-radius.md` are the judge reports.
  Each judge was a separate session-model agent holding the answer key and never shown the prompts.
- `candidate-tests.log` is the sandbox-HOME run of both candidates' own suites and validators.

Answer keys stay in the sibling fixture directories, judge-only. Never paste one into an arm prompt.

## Results

| Fixture | bare | pstack arm | incumbent arms |
|---|---|---|---|
| R hits /18 (FA) | 13.0 (2.0) | interrogate 13.5 (1.0) | thermo 13.25 (1.0), code-slop 16.0 (0.0) |
| H facts /14 | 9.5 | how 11.5 | show-me 8.5, ce-explain 11.5 |
| B consumers /5, no-tools disclosure | 4.5, 0/2 | blast-radius 5.0, 2/2 | none |

Construct caveat: every arm measures doctrine text under one no-tools model. pstack's multi-model
panel (interrogate), explorer fan-out (how), and run-the-code step (blast-radius) were not exercised.

## Follow-up experiments (2026-09-19, issue #1202)

- `exp10-lead-output.md`, `exp10-judge-report.md`: the panel-review pre-test. A lead-judgment
  synthesis over the six existing fixture-R reviews scored 14.0/18 with 2.0 false accusations
  against the single code-slop reviewer's 16.0/0.0, dismissing K3, K7, K15 as nitpicks. Below the
  pre-registered bound; no panel is built.
- `exp20-report.md`, `exp20-generated-skill/`: the create-verification-skill live pass. The
  generated `verify-better-ccflare` skill (SKILL.md plus a three-feature map in the four-section
  shape) drove the real app under headless Playwright with an artifact per claim; a private site project was
  environment-blocked (needs production access). Evidence lived under
  `/tmp/hv-pstack/exp20/evidence/` (30 files) and is not committed; the report names each file.

## Re-running

Clone pstack to scratch, point `CAND` at its `skills/` directory, pick a fresh `OUT`, and run the
script. Add an arm by appending a `prompt_*` call and an `ARMS` name. Before trusting a new fixture,
grep it for phrases lifted from the doctrine under test.
