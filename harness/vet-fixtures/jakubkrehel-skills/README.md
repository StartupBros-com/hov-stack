# Behavioral fixture: jakubkrehel/skills vet (2026-09-01)

The planted-defect fixture behind the `jakubkrehel-skills-vet-2026-09` memory note.
Kept so the note's re-eval trigger ("a second keyed fixture … beats the incumbent
arm") has a first fixture to compare against.

- `fixture.html` — one self-contained page: sign-in card, icon toolbar, stats
  table, toast. 11 planted defects across accessibility, typography, colour,
  layout, UI and writing; 10 honest controls that look wrong but are correct.
- `answer-key.md` — judge-only key with IDs D1–D11 and C1–C10 and the scoring
  rule (TP of 11, false accusations of 10, extras classified valid/noise).
  Never paste it into an arm prompt.
- `run-arms.sh` — runs three arms `$RUNS` times each (default 2) on Sonnet in
  `claude -p --bare` with no tools: bare, candidate (better-interface + six
  domain SKILL.md from a clone at `$CAND`), incumbent (ux-audit +
  emil-design-eng from `$INC`, default `~/.claude/skills`). Writes prompts and
  JSON/markdown outputs to a fresh `$OUT`. Accepts the run only when every
  invocation exited 0 with `is_error` false and a non-empty result
  (`../check-arms.py`, dotfiles#1690); anything else exits 1 before the
  results summary.

Result on 2026-09-01 (Sonnet, 2 runs/arm, ~$0.25/run): bare 9.5 TP / 0 FA,
candidate 10.5 / 0, incumbent 10.0 / 0. Every arm made zero false accusations;
the candidate's 15-finding cap cut valid unkeyed extras to 2.0/run vs 6.5.

To rerun: shallow-clone the candidate to `/tmp/hv-jakubkrehel-skills/cand` (or
set `CAND`), then `bash run-arms.sh`, then judge each `*.md` in `$OUT` against
`answer-key.md` with a separate model that never saw the arm prompts.
