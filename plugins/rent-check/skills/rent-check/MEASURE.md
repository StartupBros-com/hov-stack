# Measuring a contested rule

Design for settling a MEASURE verdict: does this specific rule change agent
behavior enough to earn its load? Composite of the strongest published
harness designs (sources in CREDITS.md); each element closes a failure mode
observed in the wild.

**Before running anything:** state the planned cell count
(conditions × tasks × reps), the estimated cost, and the minimum trials at
which a KEEP could even be statistically possible. If the operator's harness
has its own transcript-analysis or A/B tooling, prefer it — this design is
the portable fallback.

## Design

1. **Conditions** — minimum two: file-with-rule vs file-without-rule
  (everything else byte-identical). Add a no-file baseline when the question
  is the file's existence, not one rule.
2. **Tasks** — prefer real history over synthetic prompts: mine commits whose
  own test changes provide an unfakeable pass/fail oracle; run from a
  snapshot at the parent commit with no later history reachable. Screen every
  task for *baseline hardness*: a task the baseline already saturates (always
  passes or always fails) measures the model, not the rule — drop it.
3. **Dev/holdout split** — tune the rule text only against dev tasks; freeze
  a holdout set authored once. A gain that appears on dev and dies on holdout
  is overfitting, and the report must say which happened.
4. **Isolation** — fresh temp workspace per cell; the file under test written
  last so it wins over fixtures; no shared state between parallel cells.
  For ablating *harness layers* (skills, memory, rules dirs) rather than one
  file: build a shadow config dir — symlink every config entry except the
  layer under ablation into a throwaway dir and point the agent's config-dir
  env var at it (`CLAUDE_CONFIG_DIR` in Claude Code). Cells cost symlinks,
  not full config copies, and the real config is never touched.

## Grading

- **Deterministic first**: exit codes, file contents, and a transcript built
  from *assistant text and tool-call inputs only* — never tool results, and
  never the echoed rule text, so "never say X" cannot be false-flagged by the
  agent reading its own rule.
- **LLM judge second, only where determinism can't reach**: blind to
  condition labels and to the deterministic channel's numbers; grades only
  observable behavior against a rubric frozen before the run; every non-
  default score requires a verbatim, string-matchable quote from the
  transcript — an unquotable score reverts to the default. Never blend the
  two channels into one number.
- Two-sided criteria where side effects matter: required actions occurred
  AND prohibited actions did not.

## Statistics

- Wilson intervals per rate; **Fisher's exact** for condition comparisons
  (these experiments routinely produce 0/N boundary cells where z-tests
  overstate significance); Holm-Bonferroni across a family of rules/traps.
- Compute the pre-spend trial floor: the smallest n at which even a perfect
  flip would clear your decision threshold — running fewer trials than that
  cannot produce a KEEP and the report must refuse to claim one.
- Infrastructure failures (quota, timeouts, unparseable output) are NOT-RUN,
  excluded from rates — never scored as failures.

## Report

Required sections: (1) verdict per rule with effect size and CI; (2) an
**honesty section** naming which tasks actually differentiated conditions
versus which tied at baseline; (3) NOT-RUN counts; (4) a fingerprint of the
exact condition files (hashes) so the report stays tied to what ran; (5) at
least one finding *against* the report's overall direction if one exists.
Small n is normal in this space — publish the n and the interval, and let
the verdict carry the uncertainty rather than hiding it.
