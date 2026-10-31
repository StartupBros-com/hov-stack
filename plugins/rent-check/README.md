# rent-check

**Every always-loaded line pays rent or gets cut.**

Your CLAUDE.md bills you on every single turn. So does your AGENTS.md, your
rules dir, your memory index, and every skill description in the roster. Most
of those files carry lines that earn nothing — rules the model already
follows, commands that no longer exist, "NEVER do X" prose with no
enforcement behind it, and advice the research has since tested and killed.

`/rent-check` audits that surface and returns a verdict per line:
**KEEP / FIX / PROMOTE / DEMOTE / MERGE / CUT / MEASURE** — every check
cited to its evidence tier, every proposal shipped as a verified draft diff,
nothing auto-applied.

## What it checks

- **Load class before line count** — always-loaded vs on-invocation vs
  on-read, because a medium always-loaded rule outweighs a huge on-demand
  reference. Deferred material is counted at trigger cost, not body size.
- **Reality drift** — every path, command, script, version, and required-CI
  check the files claim, verified against the live repo and config. Stale
  guidance beats missing guidance at misleading agents.
- **Enforcement backing** — for every always/never/must rule: is there a
  hook, linter, or CI gate behind it, or is it just words? Redundant prose
  gets pruned; unbacked invariants get a proposed gate.
- **Monorepo layering** — per-agent resolution semantics (Claude Code
  concatenates additively; Codex concatenates root-down and truncates the
  most specific file first at its 32 KiB cap), parent-child coherence, and
  child-file admission.
- **Portfolio** — skill-description budgets, overlap clustering (with
  mandatory consumer tracing before any cut), memory-index ceilings with
  routing to your consolidation tool.
- **Folklore stays labeled** — the 200-line cap, put-critical-rules-first,
  and split-your-files all tested null in controlled studies. The report
  applies them as load-cost conventions and says so, with citations.

## What a report looks like

Verdict table → mandatory counter-finding (at least one line that earns its
keep — the audit can't become a deletion machine) → considered-but-rejected
with reasons → verified draft diffs in one run directory → ops actions →
coverage matrix → evidence appendix. Contested verdicts route to a
pre-registered experiment design (dev/holdout split, Fisher's exact,
pre-spend trial floor) that runs only with your approval.

## Install

From the [House of Vibe marketplace](https://github.com/StartupBros-com/hov-stack):

```
/plugin marketplace add StartupBros-com/hov-stack
/plugin install rent-check@hov
```

Then run `/rent-check` in your busiest repo.

## Receipts

Built from a verified recon of the 2026 ecosystem (~25 audited artifacts,
six controlled studies, first-party loading-mechanics docs) and hardened
through four adversarial dogfood cycles. Real finds from those runs: a
memory index over its load ceiling whose newest entries silently never
loaded; a context file ordering the model to invoke skills that were
configured model-uninvocable; a required CI check missing from the docs of
the repo that enforced it; a rules file triplicating a rule its hook
already re-injects at point of use.

Sources, licenses, and the folklore-vs-measured contradiction map:
[`skills/rent-check/CREDITS.md`](skills/rent-check/CREDITS.md) and
[`skills/rent-check/EVIDENCE.md`](skills/rent-check/EVIDENCE.md).

MIT · StartupBros / House of Vibe
