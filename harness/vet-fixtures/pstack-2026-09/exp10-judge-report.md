# Experiment 10 pre-test: lead-judgment synthesis over the six fixture-R reviews (2026-09-19)

Question: does a lead-judgment synthesis step (pstack `interrogate/references/lead-judgment.md`) over
several reviewers beat the best single reviewer on `../anti-slop-list/invoice-code-bundle.md`?
Pre-registered bound (from the /measure framing): the panel must beat code-slop's 16.0/18 with false
accusations at or below 0.0; otherwise keep one code-slop reviewer. Same-family pre-test: all six
inputs are the existing Sonnet arm outputs (R-interrogate-1/2, R-thermo-1/2, R-codeslop-1/2). Lead =
a Sonnet agent with the doctrine and the bundle, no answer key. Judge = a separate session-model
agent holding `../anti-slop-list/invoice-answer-key.md`.

## Score

| Arm | Hits /18 | FA |
|---|---|---|
| bare (mean of 2) | 13.0 | 2.0 |
| interrogate text (mean of 2) | 13.5 | 1.0 |
| thermo-nuclear (mean of 2) | 13.25 | 1.0 |
| code-slop (mean of 2) | 16.0 | 0.0 |
| lead-judgment synthesis over all six | 14.0 | 2.0 |

Hits: K1, K2, K4, K5, K6, K9, K10, K11, K12, K13, K14, K16, K17, K18. Misses: K3, K7, K15 (each
raised by a reviewer and dismissed by the lead as "nitpick gravity"), K8 (never raised). False
accusations: H3 (the SAFETY-commented cast, the same trap thermo-nuclear hits) and H2 (the
rethrow-with-context catch, attacked for not retrying). No invented defects.

## Verdict

Below the bound on both axes. The synthesis diluted the best single arm: the dismissal step threw
away three real planted defects and added one false accusation. The lead kept 11 findings past
pstack's Act-On cap of 5 and said so; enforcing the cap would have removed most of the 14 credited
hits. With same-family synthesis already under the bound, model diversity is unlikely to recover it
cheaply, so the $3 multi-model run was not spent. Decision: no panel step; one code-slop reviewer
stays the incumbent. Retry trigger: a review incident where a single code-slop pass demonstrably
missed a class that a second model family catches.

Lead output: `exp10-lead-output.md` beside this file.
