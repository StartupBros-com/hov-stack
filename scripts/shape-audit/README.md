# shape-audit — measure whether an always-on CLAUDE.md rule actually does anything

Transcript-frequency tooling for the standing-rules-audit methodology (the bar that
killed the em-dash ban in PR #130). Built 2026-08-06 to audit the Response Shape
section added by PR #161.

The premise: a rule in `CLAUDE.md` is paid on every session and every subagent
stream. It earns that only if the behavior it targets (a) actually occurred before
the rule existed, and (b) measurably changed after. Both halves are testable against
`~/.claude/projects/**/*.jsonl`.

**Read the two traps below before trusting any number this produces.** The first
pass of this audit got two findings wrong, and both traps are why.

## Trap 1: model-match, or you will manufacture an effect

The naive pre/post comparison for PR #161 showed preamble dropping 3.21% → 1.84%,
non-overlapping 95% CIs. It looked like a clean win. It was not.

The POST window was **96.4% `claude-opus-5`**, while PRE was a mix (`opus-4-8`
36.5%, `opus-5` 29.8%, `gpt-5.6-sol` 18.3%, `fable-5` 13.3%). Restricted to
`opus-5` on both sides the effect is **−0.36pp, n.s.** The entire "win" was model
drift. The model mix on this machine turns over fast enough that a two-week window
can be a different model population.

## Trap 2: pick the denominator per rule

Only **12.9%** of main-thread assistant messages (7,614 of 59,101) are actually a
*response to the user*. The rest is mid-turn narration between tool calls. Scoring
"no preamble" over all messages diluted the rate ~7.8×.

Corrected, the preamble rate is **12.54%**, not 3.21% — a frequent behavior, and one
the rule did **not** move (11.73% post, −0.80pp, n.s., n_post=196).

Each rule needs its own denominator:

| rule class | correct denominator |
|---|---|
| lead-with-answer / no-preamble | response-**initial** (first assistant text after a real user turn) |
| no closers / no punting / error tone | response-**final** (last assistant text before the next user turn) |
| restate `Step N of M` | **all** messages — it applies to mid-turn narration too |

`validate_eval.py` computes all three. A "real user turn" excludes `tool_result`
carriers and `<system-reminder>` injections, which Claude Code also records as
`type=="user"`.

## Trap 3: validate detector precision before believing a zero

A 0.01% rate is indistinguishable from a broken regex. Sample the matches and read
them. Doing so here found that `punt` and `error_tone` are dominated by false
positives, and that the 3 pre-boundary `Step N of M` matches were incidental prose
("abandoned after step 1 of 5"), not the behavior.

## Scripts

| script | what it answers |
|---|---|
| `validate_eval.py` | **Start here.** Per-rule denominators, head-anchored regexes, precision samples. |
| `model_confound.py` | Model mix pre/post and the model-matched rate. Run before trusting any delta. |
| `check_step.py` | Focused precision check on a single detector, with session concentration. |
| `shape_audit.py` | First-pass sweep. **Has known defects** (all-messages denominator; `^`-anchored regex also applied to the message tail). Kept for provenance; prefer `validate_eval.py`. |
| `robust_cost.py` | Session concentration, plus real token cost of `CLAUDE.md` as a share of cache traffic. |
| `pkgmgr_probe.py` | Adherence probe for the CRITICAL package-manager rule — the high-n, high-precision counterexample to the response-shape metrics. |

```bash
python3 validate_eval.py && python3 model_confound.py && python3 check_step.py
python3 robust_cost.py && python3 pkgmgr_probe.py
```

`BOUNDARY` is hardcoded to PR #161's landing time (`2026-08-05T19:09:01-04:00`,
commit `41c5ef1`). Change it to audit a different rule; get the timestamp with
`git log -1 --format=%aI <commit>`.

## Findings, 2026-08-06 (1 day after the section landed)

Corpus 20,594 transcripts / 10.1 GB back to 2026-04-04. Model-matched to `opus-5`.

- **`Step N of M` restatement is the one real effect.** 0.018% → 0.610%
  (3/16,855 → 16/2,622), non-overlapping CIs, and precision-checked: all 10 sampled
  POST matches are genuine, all 3 PRE matches are incidental prose. But it rests on
  **16 events in 4 sessions** out of 50 — 92% of post-boundary sessions never
  emitted one, and a quarter of the events came from the session running the audit.
- **Preamble is unmoved.** 12.54% → 11.73%, n.s. Note the detector partly conflates
  violation with *mandated* narration: background jobs are told to narrate before
  acting, and CLAUDE.md override #1 explicitly exempts them.
- **Three "don't" bullets police behavior that does not occur.** On the correct
  response-final denominator: closer **0/1,407**, punt **0/1,407**, error-tone
  **1/1,407** before the rule existed. Precision sampling suggests even those are
  over-counts. This is the em-dash-ban shape.
- **Subagents show zero effect on every signal.** PR #161 chose `CLAUDE.md` over an
  output style because "CLAUDE.md reaches subagents." It reaches them and does nothing.
- Cost: `CLAUDE.md` ≈ 5,944 tok = **2.9% of all cache-read**, 1.0% of cache-creation
  over 7d across 2,346 streams (139 main + 2,207 subagent, mean 69.7 requests/stream).
  Response Shape section alone ≈ 776 tok.
- Re-measured 2026-09-19 (same script, 7d window): 27,868 bytes ≈ 7,741 tok at 3.6 ch/tok,
  **3.9% of all cache-read** (2.37B of 61.2B), 1.7% of cache-creation, over 122 main sessions
  and 3,483 subagent streams; the Response Shape section is 776 tok (10% of the file). The
  same-day /rent-check audit found no cut and one demotion (issue #1209); the remaining lever is
  structural (whether subagent streams receive the file at all), not line-level.

## Verdict: change nothing yet

The section was one day old when this ran, and the response-level treatment sample
is ~200 messages. Cutting on that would be the overreach this tooling exists to
prevent. **Re-run 2026-08-26** (21 days), then apply the armor-outweighs-rule bar.

## Coverage is ~2% of the file, and the untested rules are the better targets

`CLAUDE.md` holds ~68 directives. This tooling attempts ~6 of them and validly
measures ~1. The gap is not evenly valuable — the operational/tooling rules are
*easier* to measure and better powered, because they match on executed commands
rather than on prose:

```
NODE package-manager rule   99.3% adherence   n=3,872   (pnpm 3,843 / npm 28 / yarn 1)
Response-shape preamble     12.54% rate       n=196 post
```

Same corpus, 20× the events, and no semantic judgment in the detector. Ranked next
targets: package managers (done, above), `ast-grep`-before-grep, `gsc --page`
(guards a silently-wrong answer), conventional-commit prefixes, worktree/main-checkout
discipline, subagent model pinning, draft-PR-per-task.

**The single highest-value design is hook-enforced vs prose-only.** Rules backed by
`git-guard`/`settings.json` should show ~0 violations; prose-only rules show the true
adherence rate. The gap between them is what the prose is actually worth — which is
the question the whole context-file literature is circling.

**Adherence is not attribution** — 99.3% `pnpm` use does not prove the rule caused
it, since a `pnpm-lock.yaml` would too. That gap is now closed: see
[`ablation/`](ablation/), a controlled 3-arm experiment (no CLAUDE.md / full file /
the 85-word rule alone) in a lockfile-free sandbox with PATH shims.

Headline: with no context file both Sonnet and Opus reach for `npm` **0/9**
compliant; with one, `pnpm` **9/9**. **+100pp, Fisher p=0.0079 / 0.0286.** The Python
`uv` rule is near-redundant (baseline already 4/5) — a real asymmetry inside a single
CRITICAL rule.

On these two rules the full file and the 85-word section perform identically
(p=1.0) — but **both arms sat at ceiling, and a ceiling cannot show dilution.**
Later sweeps, on a rule with partial baseline adherence, measured a real dilution
effect on Sonnet (p=0.0079) that did not replicate on Opus. See `ablation/README.md`.

That is a 100pp effect at n=5, against the paper's >30pp MDE and null over 288
runs. The difference is entirely the dependent variable.

Related: `memory/` → `context-files-paper-evaluation-2026-08`.
